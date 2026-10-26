import AppKit
import VideoToolbox
import ScreenProtocol

struct ProbeError: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeError(message: message) }
}

final class Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    var image: CVPixelBuffer?
    init(_ message: ScreenWire.VideoFormat) throws {
        var result: OSStatus = -1
        let sets = message.parameterSets.map { [UInt8]($0) }
        func pointers(_ index: Int, _ collected: [UnsafePointer<UInt8>]) {
            if index < sets.count {
                sets[index].withUnsafeBufferPointer { pointers(index + 1, collected + [$0.baseAddress!]) }
            } else {
                let sizes = sets.map(\.count)
                if message.codec == .hevc {
                    result = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                        parameterSetPointers: collected, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                } else {
                    result = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                        parameterSetPointers: collected, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
        }
        pointers(0, [])
        try require(result == noErr && format != nil, "Cannot parse video format: \(result)")
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
            guard status == noErr, let context else { return }
            Unmanaged<Decoder>.fromOpaque(context).takeUnretainedValue().image = image
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        result = VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        try require(result == noErr, "Cannot start decoder: \(result)")
    }

    func decode(_ message: ScreenWire.VideoFrame) throws {
        var block: CMBlockBuffer?
        let length = message.sample.count
        var result = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        try require(result == noErr, "Cannot allocate decoder block")
        result = message.sample.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        try require(result == noErr, "Cannot fill decoder block")
        var sample: CMSampleBuffer?
        var size = length
        result = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        try require(result == noErr, "Cannot create compressed sample")
        result = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        try require(result == noErr, "Cannot decode video frame: \(result)")
    }

    func save(_ path: String) throws {
        guard let image else { throw ProbeError(message: "Decoder produced no image") }
        let context = CIContext()
        let ci = CIImage(cvPixelBuffer: image)
        let bitmap = NSBitmapImageRep(cgImage: context.createCGImage(ci, from: ci.extent)!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}

final class Connection {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var reader = ScreenWire.FrameReader()
    private var buffer = [UInt8](repeating: 0, count: 262144)
    var welcome: ScreenWire.Welcome?
    var failure: String?
    var clipboards: [ScreenWire.Clipboard] = []
    var formats: [UInt32: ScreenWire.VideoFormat] = [:]
    var decoders: [UInt32: Decoder] = [:]
    var counts: [UInt32: Int] = [:]
    var bytes: [UInt32: Int] = [:]
    var firstKeyMillis: [UInt32: Double] = [:]
    var watchTime: UInt64 = 0
    var cursorCount = 0
    var pointerCount = 0
    var decodeFrames = true
    var recordTimeline = false
    var timeline: [UInt32: [(micros: UInt64, key: Bool, bytes: Int, received: UInt64)]] = [:]

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let descriptor = self.descriptor
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try require(path.utf8.count < 104, "Forwarded socket path is too long")
        withUnsafeMutableBytes(of: &address.sun_path) { destination in path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try require(result == 0, "Cannot connect to the host: \(errno)")
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 256 * 1024
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        try send(.hello, ScreenWire.Hello())
    }

    func send<T: Encodable>(_ kind: ScreenWire.Kind, _ message: T) throws {
        let bytes = try ScreenWire.frame(kind, json: message)
        var at = 0
        while at < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: at), bytes.count - at) }
            try require(count > 0, "Cannot send to the host")
            at += count
        }
    }

    private func readAvailable() {
        while true {
        let count = Darwin.recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
        guard count > 0 else { failure = "Host disconnected"; source.cancel(); return }
        reader.append(Data(buffer.prefix(count)))
        do {
            while let (kind, payload) = try reader.next() {
                switch kind {
                case .welcome: welcome = try ScreenWire.decode(ScreenWire.Welcome.self, from: payload)
                case .failure: failure = try ScreenWire.decode(ScreenWire.Failure.self, from: payload).message
                case .clipboard: clipboards.append(try ScreenWire.decode(ScreenWire.Clipboard.self, from: payload))
                case .cursor: cursorCount += 1
                case .pointerMoved: pointerCount += 1
                case .videoFormat:
                    let format = try ScreenWire.decodeVideoFormat(payload)
                    if formats[format.display] != format {
                        formats[format.display] = format
                        decoders[format.display] = try Decoder(format)
                    }
                case .videoFrame:
                    let frame = try ScreenWire.decodeVideoFrame(payload)
                    if recordTimeline { timeline[frame.display, default: []].append((frame.captureMicros, frame.isKeyframe, frame.sample.count, DispatchTime.now().uptimeNanoseconds / 1000)) }
                    if frame.isKeyframe && firstKeyMillis[frame.display] == nil {
                        firstKeyMillis[frame.display] = Double(DispatchTime.now().uptimeNanoseconds - watchTime) / 1_000_000
                    }
                    try require(decoders[frame.display] != nil, "Frame arrived before its format")
                    if decodeFrames { try decoders[frame.display]?.decode(frame) }
                    counts[frame.display, default: 0] += 1
                    bytes[frame.display, default: 0] += payload.count + 5
                default: break
                }
            }
        } catch { failure = String(describing: error) }
        }
    }

    func pump(_ seconds: Double) throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.005)))
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            if let failure { throw ProbeError(message: failure) }
        } while Date() < deadline
    }

    func wait(_ seconds: Double, until condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try pump(0.01) }
        try require(condition(), "Timed out waiting for host response")
    }

    func checkDirectPeerRefused() throws {
        let direct = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(direct) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = NSString(string: ScreenWire.socketPath).expandingTildeInPath
        withUnsafeMutableBytes(of: &address.sun_path) { destination in path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(direct, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try require(result == 0, "Cannot open direct socket for rejection check")
        try pump(0.2)
        var byte: UInt8 = 0
        let count = Darwin.recv(direct, &byte, 1, MSG_DONTWAIT)
        try require(count == 0, "Non-sshd peer was not refused")
        let previous = counts.values.reduce(0, +)
        for display in welcome!.displays { try send(.keyframe, ScreenWire.KeyframeRequest(display: display.id)) }
        try wait(5) { counts.values.reduce(0, +) > previous }
        print("direct_peer_refused=true current_client_survived=true")
    }
    deinit { source.cancel(); Darwin.close(descriptor) }
}
