import Darwin
import Foundation
import ScreenProtocol

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class SocketListener {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let path: String

    init(accept: @escaping (SocketClient) -> Void) throws {
        path = NSString(string: ScreenWire.socketPath).expandingTildeInPath
        guard path.utf8.count < 104 else { throw HostError("The screen socket path exceeds the Unix socket path limit.") }
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw HostError("Cannot create the socket directory: \(errno)") }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw HostError("The screen socket path is occupied by a non-socket file.") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = Self.address(path)
            let active = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
            }
            Darwin.close(probe)
            guard !active else { throw HostError("Term Screen Host is already running.") }
            unlink(path)
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HostError("Cannot create the screen socket: \(errno)") }
        let descriptor = self.descriptor
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw HostError("Cannot listen on the screen socket: \(errno)")
        }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [descriptor] in
            while true {
                let fd = Darwin.accept(descriptor, nil, nil)
                if fd < 0 { break }
                guard Self.isSSHPeer(fd) else { Darwin.close(fd); continue }
                accept(SocketClient(fd))
            }
        }
        source.resume()
    }

    static func isSSHPeer(_ descriptor: Int32) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size, pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        // These system executables are protected by SIP; same-user permission alone is insufficient.
        let executable = String(cString: path)
        return executable == "/usr/libexec/sshd-session" || executable == "/usr/sbin/sshd"
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return address
    }

    deinit { source.cancel(); Darwin.close(descriptor); unlink(path) }
}

/// Main-queue owned, including write admission. No blocking writes on the capture path.
final class SocketClient {
    private struct Packet { let data: Data; let video: Bool }
    private let descriptor: Int32
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    private var writeActive = false
    private var closed = false
    private var closing = false
    private var frames = ScreenWire.FrameReader()
    private var buffer = [UInt8](repeating: 0, count: 65536)
    private var packets: [Packet] = []
    private var offset = 0
    private(set) var pendingVideos = 0
    var receive: ((ScreenWire.Kind, Data) throws -> Void)?
    var disconnected: (() -> Void)?
    var drained: (() -> Void)?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // macOS defaults Unix streams to 8 KiB, which fragments a key frame into hundreds of wakeups.
        var sendBuffer: Int32 = 256 * 1024
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        writer.setEventHandler { [weak self] in self?.flush() }
        reader.resume()
    }

    func send<T: Encodable>(_ kind: ScreenWire.Kind, _ value: T) {
        do { enqueue(try ScreenWire.frame(kind, json: value), video: false) }
        catch { close() }
    }

    func video(format: ScreenWire.VideoFormat?, frame: ScreenWire.VideoFrame) -> Bool {
        guard !closed, !closing, pendingVideos < 2 else { return false }
        if let format { enqueue(ScreenWire.frame(.videoFormat, ScreenWire.encode(format)), video: false) }
        enqueue(ScreenWire.frame(.videoFrame, ScreenWire.encode(frame)), video: true)
        return true
    }

    private func enqueue(_ data: Data, video: Bool) {
        guard !closed, !closing else { return }
        guard data.count <= ScreenWire.maxFrame + 4 else {
            send(.failure, ScreenWire.Failure(message: "Clipboard exceeds the 64 MiB message limit."))
            return
        }
        packets.append(Packet(data: data, video: video))
        if video { pendingVideos += 1 }
        flush()
    }

    private func readAvailable() {
        while !closed && !closing {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count <= 0 { close(); return }
            frames.append(Data(buffer.prefix(count)))
            do {
                while let (kind, payload) = try frames.next(), !closed && !closing { try receive?(kind, payload) }
            } catch {
                send(.failure, ScreenWire.Failure(message: "Invalid Screen message: \(error)"))
                finish()
            }
        }
    }

    private func flush() {
        guard !closed else { return }
        let wasFull = pendingVideos >= 2
        while let packet = packets.first {
            let sent = packet.data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            if sent <= 0 { close(); return }
            offset += sent
            if offset == packet.data.count {
                if packet.video { pendingVideos -= 1 }
                packets.removeFirst()
                offset = 0
            }
        }
        if packets.isEmpty {
            if writeActive { writer.suspend(); writeActive = false }
            if closing { close(); return }
        } else if !writeActive { writer.resume(); writeActive = true }
        if wasFull && pendingVideos < 2 { drained?() }
    }

    func finish() { closing = true; if packets.isEmpty { close() } }

    func close() {
        guard !closed else { return }
        closed = true
        reader.cancel()
        writer.cancel()
        if !writeActive { writer.resume() }
        Darwin.close(descriptor)
        packets.removeAll()
        pendingVideos = 0
        disconnected?()
        disconnected = nil
    }

    deinit { close() }
}
