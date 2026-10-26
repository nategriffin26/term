import AppKit
import ScreenCaptureKit
import ScreenProtocol

final class Host {
    private var listener: SocketListener?
    private var client: SocketClient?
    private var welcomed = false
    private let input = Input()
    private let clipboard: Clipboard
    private let clipboardQueue = DispatchQueue(label: "screen.clipboard", qos: .userInitiated)
    private var clipboardReadPending = false
    private let cursor = Cursor()
    private let power = DisplayPower()
    private var streams: [UInt32: DisplayStream] = [:]
    private var watched = Set<UInt32>()
    private var generation = 0
    private var locked = Desktop.locked()
    private var access = Desktop.access()
    private var displays = Desktop.displays()
    private var pointer = Desktop.pointer
    private var timers: [DispatchSourceTimer] = []
    private var observers: [NSObjectProtocol] = []
    private var quality = QualityController()
    private var transportSkips = 0

    init(clipboard: Clipboard = Clipboard()) { self.clipboard = clipboard }

    func start() throws {
        access = Desktop.access(request: true)
        listener = try SocketListener { [weak self] in self?.connect($0) }
        let center = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in self?.setLocked(value) })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconfigure()
        })
        print("Term Screen Host listening")
    }

    func connect(_ next: SocketClient) {
        client?.close()
        client = next
        welcomed = false
        next.receive = { [weak self, weak next] kind, data in
            guard let self, let next, self.client === next else { return }
            try self.receive(kind, data)
        }
        next.disconnected = { [weak self, weak next] in
            guard let self, self.client === next else { return }
            self.disconnect()
        }
        next.drained = { [weak self] in
            guard let self else { return }
            for stream in self.streams.values { stream.drained() }
        }
        Desktop.wake()
    }

    private func disconnect() {
        input.release()
        watched.removeAll()
        stopStreams()
        for timer in timers { timer.cancel() }
        timers.removeAll()
        welcomed = false
        quality = QualityController()
        transportSkips = 0
        client = nil
    }

    private func receive(_ kind: ScreenWire.Kind, _ data: Data) throws {
        if !welcomed {
            guard kind == .hello else { throw HostError("Hello must be the first message.") }
            let hello = try ScreenWire.decode(ScreenWire.Hello.self, from: data)
            guard hello.version == ScreenWire.version else {
                client?.send(.failure, ScreenWire.Failure(message: "Screen protocol mismatch: client version \(hello.version), host version \(ScreenWire.version)."))
                client?.finish()
                return
            }
            welcomed = true
            access = Desktop.access()
            locked = Desktop.locked()
            displays = Desktop.displays()
            pointer = Desktop.pointer
            client?.send(.welcome, ScreenWire.Welcome(name: hostName(), displays: displays, locked: locked, access: access, pointer: pointer))
            client?.send(.qualityState, quality.state)
            clipboardQueue.async { [clipboard] in clipboard.reset() }
            cursor.reset()
            if let image = cursor.changed() { client?.send(.cursor, image) }
            timer(every: 1.0 / 60) { [weak self] in self?.pollPointer() }
            timer(every: 0.25) { [weak self] in
                guard let self else { return }
                self.pollClipboard()
                self.setLocked(Desktop.locked())
            }
            timer(every: 2) { [weak self] in self?.pollAccess() }
            timer(every: 1) { [weak self] in self?.sampleQuality() }
            return
        }
        switch kind {
        case .watch:
            let request = try ScreenWire.decode(ScreenWire.Watch.self, from: data)
            watched = Set(request.displays)
            synchronizeStreams()
        case .keyframe:
            let request = try ScreenWire.decode(ScreenWire.KeyframeRequest.self, from: data)
            streams[request.display]?.keyframe()
        case .quality:
            let request = try ScreenWire.decode(ScreenWire.QualityRequest.self, from: data)
            let previous = quality.level
            if quality.select(request.mode, at: ProcessInfo.processInfo.systemUptime) {
                applyQuality(previous: previous)
            }
        case .setClipboard:
            // On this queue, so a ⌘V right behind it pastes the new content.
            clipboard.set(try ScreenWire.decode(ScreenWire.Clipboard.self, from: data))
        case .pointer, .button, .scroll, .key, .modifiers, .text:
            guard access.input else { client?.send(.failure, ScreenWire.Failure(message: "Allow Term Screen Host in System Settings > Privacy & Security > Accessibility.")); return }
            switch kind {
            case .pointer: input.move(try ScreenWire.decode(ScreenWire.Point.self, from: data))
            case .button: input.button(try ScreenWire.decode(ScreenWire.ButtonEvent.self, from: data))
            case .scroll: input.scroll(try ScreenWire.decode(ScreenWire.ScrollEvent.self, from: data))
            case .key: input.key(try ScreenWire.decode(ScreenWire.KeyEvent.self, from: data))
            case .modifiers: input.setModifiers(try ScreenWire.decode(ScreenWire.ModifierState.self, from: data).held)
            case .text: input.text(try ScreenWire.decode(ScreenWire.TextInput.self, from: data).text)
            default: break
            }
        default: throw HostError("Unexpected client message.")
        }
    }

    private func hostName() -> String { Foundation.Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    private func timer(every interval: Double, body: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler(handler: body)
        timers.append(timer)
        timer.resume()
    }

    private func pollClipboard() {
        guard !clipboardReadPending, let connection = client else { return }
        clipboardReadPending = true
        clipboardQueue.async { [weak self, clipboard] in
            var failure: String?
            let content = clipboard.changed { failure = $0 }
            DispatchQueue.main.async {
                guard let self else { return }
                self.clipboardReadPending = false
                guard self.client === connection else { return }
                if let failure { connection.send(.failure, ScreenWire.Failure(message: failure)) }
                if let content { connection.send(.clipboard, content) }
            }
        }
    }

    private func pollPointer() {
        if let image = cursor.changed() { client?.send(.cursor, image) }
        let actual = Desktop.pointer
        let reference = input.lastPoint ?? CGPoint(x: pointer.x, y: pointer.y)
        // CGEvent can still report the previous position just after a posted move.
        if ProcessInfo.processInfo.systemUptime - input.lastMoveTime >= 0.25,
           hypot(actual.x - reference.x, actual.y - reference.y) > 0.5,
           hypot(actual.x - pointer.x, actual.y - pointer.y) > 0.5 {
            client?.send(.pointerMoved, actual)
        }
        pointer = actual
    }

    private func pollAccess() {
        let value = Desktop.access()
        guard value != access else { return }
        access = value
        client?.send(.access, value)
        if !value.input { input.release() }
        synchronizeStreams()
    }

    private func setLocked(_ value: Bool) {
        guard locked != value else { return }
        locked = value
        if welcomed { client?.send(.lock, ScreenWire.LockState(locked: value)) }
        if value { input.release() }
        synchronizeStreams()
    }

    private func reconfigure() {
        displays = Desktop.displays()
        if welcomed { client?.send(.displays, ScreenWire.DisplayList(displays: displays)) }
        stopStreams()
        synchronizeStreams()
    }

    private func sampleQuality() {
        let skipped = transportSkips
        transportSkips = 0
        guard !streams.isEmpty else { return }
        let previous = quality.level
        if quality.sample(skipped: skipped, blocked: (client?.pendingVideos ?? 0) >= 2,
                          at: ProcessInfo.processInfo.systemUptime) {
            applyQuality(previous: previous)
        }
    }

    private func applyQuality(previous: ScreenWire.QualityLevel) {
        client?.send(.qualityState, quality.state)
        if ProcessInfo.processInfo.environment["TERM_SCREEN_METRICS"] == "1" {
            print("quality_mode=\(quality.mode.rawValue) quality_level=\(quality.level.rawValue) uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
        if quality.level != previous {
            stopStreams()
            synchronizeStreams()
        }
    }

    private func stopStreams() {
        generation += 1
        for stream in streams.values { stream.stop() }
        streams.removeAll()
        power.hold(false)
    }

    private func synchronizeStreams() {
        generation += 1
        let current = generation
        let desired = locked || !access.screen || !welcomed ? Set<UInt32>() : watched
        for id in Array(streams.keys) where !desired.contains(id) { streams.removeValue(forKey: id)?.stop() }
        power.hold(!streams.isEmpty)
        for id in desired { streams[id]?.keyframe() }
        let missing = desired.subtracting(streams.keys)
        guard !missing.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == current else { return }
                for id in missing {
                    guard let source = content.displays.first(where: { $0.displayID == id }),
                          let display = self.displays.first(where: { $0.id == id }) else {
                        self.client?.send(.failure, ScreenWire.Failure(message: "Display \(id) is no longer connected."))
                        continue
                    }
                    let pipeline = try DisplayStream(display: display, source: source, level: self.quality.level,
                        congested: { [weak self] in
                            guard let self else { return true }
                            return (self.client?.pendingVideos ?? 2) + self.streams.values.reduce(0) { $0 + $1.inFlight } >= 2
                        },
                        transportSkipped: { [weak self] in
                            guard let self, (self.client?.pendingVideos ?? 0) > 0 else { return }
                            self.transportSkips += 1
                        },
                        output: { [weak self] format, frame in
                            guard let self, !self.locked, self.streams[id] != nil else { return false }
                            DispatchQueue.main.async { [weak self] in
                                for stream in self?.streams.values ?? [:].values { stream.drained() }
                            }
                            return self.client?.video(format: format, frame: frame) ?? false
                        }, failure: { [weak self] message in
                            self?.client?.send(.failure, ScreenWire.Failure(message: message))
                            self?.streams.removeValue(forKey: id)?.stop()
                            self?.power.hold(!(self?.streams.isEmpty ?? true))
                        })
                    self.streams[id] = pipeline
                    do { try await pipeline.start() }
                    catch {
                        guard self.generation == current else { return }
                        self.streams.removeValue(forKey: id)?.stop()
                        throw error
                    }
                    guard self.generation == current else { return }
                    self.power.hold(!self.streams.isEmpty)
                }
            } catch {
                guard self.generation == current else { return }
                self.client?.send(.failure, ScreenWire.Failure(message: "Cannot capture the display: \(error.localizedDescription)"))
            }
        }
    }
}
