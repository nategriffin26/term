import AppKit
import ScreenCaptureKit
import VideoToolbox
import ScreenProtocol

private final class EncodeStamp {
    let started = DispatchTime.now().uptimeNanoseconds
    var completed: UInt64 = 0
    let capture: UInt64
    init(capture: UInt64) { self.capture = capture }
}

/// Capture, encoder admission, and delivery state all live on the main queue.
final class DisplayStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let display: ScreenWire.Display
    private var capture: SCStream?
    private var encoder: VTCompressionSession?
    private var codec = ScreenWire.Codec.hevc
    private var format: ScreenWire.VideoFormat?
    private var needsKeyframe = true
    private var waitingForDrain = false
    private var awaitingKeyframe = true
    private var stopped = false
    private(set) var inFlight = 0
    private var sharpEncoding = false
    private var lastImage: CVPixelBuffer?
    private var lastChange: UInt64 = 0
    private var refresh: DispatchWorkItem?
    private var nextPTS: Int64 = 0
    private let bitrate: Int
    private let output: (ScreenWire.VideoFormat?, ScreenWire.VideoFrame) -> Bool
    private let failure: (String) -> Void
    private let congested: () -> Bool
    private var encodeTimes: [Double] = []
    private var sentBytes = 0
    private var sentFrames = 0
    private var capturedFrames = 0
    private var encoderDrops = 0
    private var transportDrops = 0
    private var codecDrops = 0
    private var statisticsStart = DispatchTime.now().uptimeNanoseconds
    private let statistics = ProcessInfo.processInfo.environment["TERM_SCREEN_METRICS"] == "1"

    init(display: ScreenWire.Display, source: SCDisplay,
         congested: @escaping () -> Bool,
         output: @escaping (ScreenWire.VideoFormat?, ScreenWire.VideoFrame) -> Bool,
         failure: @escaping (String) -> Void) throws {
        self.display = display
        self.congested = congested
        self.output = output
        self.failure = failure
        bitrate = max(4_000_000, display.pixelWidth * display.pixelHeight * 3)
        super.init()
        do { try createEncoder(.hevc) }
        catch { try createEncoder(.h264) }
        let configuration = SCStreamConfiguration()
        configuration.width = display.pixelWidth
        configuration.height = display.pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        capture = SCStream(filter: SCContentFilter(display: source, excludingWindows: []), configuration: configuration, delegate: self)
        try capture?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
    }

    func start() async throws { try await capture?.startCapture() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        refresh?.cancel()
        refresh = nil
        lastImage = nil
        let stream = capture
        capture = nil
        Task { try? await stream?.stopCapture() }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
    }

    func keyframe() {
        needsKeyframe = true
        if let lastImage { encode(lastImage, captureMicros: DispatchTime.now().uptimeNanoseconds / 1000, sharp: true) }
    }

    func drained() {
        guard waitingForDrain else { return }
        waitingForDrain = false
        if let lastImage {
            let now = DispatchTime.now().uptimeNanoseconds
            encode(lastImage, captureMicros: now / 1000, sharp: now - lastChange >= 350_000_000)
        }
    }

    private func createEncoder(_ requested: ScreenWire.Codec) throws {
        codec = requested
        var session: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(display.pixelWidth), height: Int32(display.pixelHeight),
            codecType: requested == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { context, stamp, status, _, sample in
                guard let context, let stamp else { return }
                let pipeline = Unmanaged<DisplayStream>.fromOpaque(context).takeUnretainedValue()
                let timing = Unmanaged<EncodeStamp>.fromOpaque(stamp).takeRetainedValue()
                timing.completed = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { pipeline.encoded(sample, status: status, timing: timing) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw HostError("Cannot start the video encoder (\(status)).") }
        encoder = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: 51 as CFNumber)
        if requested == .h264 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepared != noErr {
            VTCompressionSessionInvalidate(session)
            encoder = nil
            throw HostError("Cannot prepare the video encoder (\(prepared)).")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = sampleBuffer.imageBuffer else { return }
        if lastImage != nil, let dirty = attachments.first?[.dirtyRects] as? [NSValue], dirty.allSatisfy({ $0.rectValue.isEmpty }) { return }
        capturedFrames += 1
        lastImage = image
        lastChange = DispatchTime.now().uptimeNanoseconds
        encode(image, captureMicros: lastChange / 1000, sharp: false)
        refresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let image = self.lastImage, !self.stopped else { return }
            self.encode(image, captureMicros: DispatchTime.now().uptimeNanoseconds / 1000, sharp: true)
        }
        refresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350), execute: item)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.failure("Screen capture stopped: \(error.localizedDescription)")
        }
    }

    private func encode(_ image: CVPixelBuffer, captureMicros: UInt64, sharp: Bool) {
        guard !stopped, let encoder else { return }
        guard !congested() else {
            waitingForDrain = true
            return
        }
        guard inFlight < 2 else {
            encoderDrops += 1
            if sharp { waitingForDrain = true }
            return
        }
        // Refine the retained picture without sending a full intra frame.
        if sharpEncoding != sharp {
            sharpEncoding = sharp
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: (sharp ? 16 : 51) as CFNumber)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: (sharp ? bitrate * 3 : bitrate) as CFNumber)
        }
        let properties: CFDictionary? = needsKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        needsKeyframe = false
        nextPTS += 1
        let stamp = Unmanaged.passRetained(EncodeStamp(capture: captureMicros))
        inFlight += 1
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: CMTime(value: nextPTS, timescale: 60),
            duration: CMTime(value: 1, timescale: 60), frameProperties: properties, sourceFrameRefcon: stamp.toOpaque(), infoFlagsOut: nil)
        if status != noErr {
            stamp.release()
            inFlight -= 1
            needsKeyframe = true
            failure("Video encoding failed (\(status)).")
        }
    }

    private func encoded(_ sample: CMSampleBuffer?, status: OSStatus, timing: EncodeStamp) {
        inFlight -= 1
        guard !stopped else { return }
        guard status == noErr, let sample, let description = sample.formatDescription, let block = sample.dataBuffer else {
            codecDrops += 1
            if status != noErr { needsKeyframe = true; failure("Video encoding failed (\(status)).") }
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var parameterSets: [Data] = []
        if key || format == nil {
            var count = 0
            for index in 0..<(codec == .hevc ? 3 : 2) {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let result = codec == .hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                guard result == noErr, let pointer else { failure("The video encoder returned an invalid format."); return }
                parameterSets.append(Data(bytes: pointer, count: size))
            }
        }
        let newFormat = parameterSets.isEmpty ? nil : ScreenWire.VideoFormat(display: display.id, codec: codec,
            width: UInt32(display.pixelWidth), height: UInt32(display.pixelHeight), parameterSets: parameterSets)
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { return }
        let frame = ScreenWire.VideoFrame(display: display.id, isKeyframe: key, captureMicros: timing.capture, sample: bytes)
        if (!awaitingKeyframe || key) && output(newFormat, frame) {
            awaitingKeyframe = false
            if let newFormat { format = newFormat }
            sentFrames += 1
            sentBytes += length
        } else {
            transportDrops += 1
            awaitingKeyframe = true
            needsKeyframe = true
            waitingForDrain = true
        }
        if statistics {
            let now = DispatchTime.now().uptimeNanoseconds
            encodeTimes.append(Double(timing.completed - timing.started) / 1_000_000)
            let seconds = Double(now - statisticsStart) / 1_000_000_000
            if seconds >= 5 {
                encodeTimes.sort()
                print(String(format: "display=%u encode_ms_p50=%.2f encode_ms_p95=%.2f fps=%.2f Mbit_s=%.2f frames=%d captured=%d encoder_drops=%d transport_drops=%d codec_drops=%d",
                    display.id, encodeTimes[encodeTimes.count / 2], encodeTimes[min(encodeTimes.count - 1, Int(Double(encodeTimes.count) * 0.95))],
                    Double(sentFrames) / seconds, Double(sentBytes) * 8 / seconds / 1_000_000, sentFrames, capturedFrames, encoderDrops, transportDrops, codecDrops))
                encodeTimes.removeAll(keepingCapacity: true)
                sentFrames = 0; sentBytes = 0; capturedFrames = 0; encoderDrops = 0; transportDrops = 0; codecDrops = 0; statisticsStart = now
            }
        }
        if waitingForDrain && inFlight == 0 && !congested() { drained() }
    }

    deinit { if let encoder { VTCompressionSessionInvalidate(encoder) } }
}
