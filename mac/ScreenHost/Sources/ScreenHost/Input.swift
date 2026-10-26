import ApplicationServices
import ScreenProtocol

final class Input {
    private let source = CGEventSource(stateID: .privateState)
    private let post: (CGEvent) -> Void
    private(set) var modifiers: ScreenWire.Modifiers = []
    private var buttons: [ScreenWire.MouseButton] = []
    private var keys = Set<UInt16>()
    private(set) var lastPoint: CGPoint?
    private(set) var lastMoveTime = -Double.infinity

    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
        source?.localEventsSuppressionInterval = 0
    }

    static let modifierKeys: [(ScreenWire.Modifiers, CGKeyCode, CGEventFlags)] = [
        (.shift, 56, .maskShift), (.control, 59, .maskControl),
        (.option, 58, .maskAlternate), (.command, 55, .maskCommand),
        (.function, 63, .maskSecondaryFn),
    ]

    var flags: CGEventFlags {
        Self.modifierKeys.reduce(into: CGEventFlags()) { result, entry in
            if modifiers.contains(entry.0) { result.insert(entry.2) }
        }
    }

    func setModifiers(_ next: ScreenWire.Modifiers) {
        for (bit, code, _) in Self.modifierKeys where modifiers.contains(bit) != next.contains(bit) {
            let down = next.contains(bit)
            if down { modifiers.insert(bit) } else { modifiers.remove(bit) }
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
                event.type = .flagsChanged
                event.flags = flags
                post(event)
            }
        }
    }

    func move(_ point: ScreenWire.Point) {
        guard point.x.isFinite, point.y.isFinite else { return }
        lastMoveTime = ProcessInfo.processInfo.systemUptime
        let button = buttons.last
        let type: CGEventType = button == .left ? .leftMouseDragged :
            button == .right ? .rightMouseDragged : button == .middle ? .otherMouseDragged : .mouseMoved
        mouse(type, button ?? .left, CGPoint(x: point.x, y: point.y), clicks: 0)
    }

    func button(_ message: ScreenWire.ButtonEvent) {
        guard message.x.isFinite, message.y.isFinite else { return }
        let type: CGEventType
        switch message.button {
        case .left: type = message.down ? .leftMouseDown : .leftMouseUp
        case .right: type = message.down ? .rightMouseDown : .rightMouseUp
        case .middle: type = message.down ? .otherMouseDown : .otherMouseUp
        }
        buttons.removeAll { $0 == message.button }
        if message.down { buttons.append(message.button) }
        mouse(type, message.button, CGPoint(x: message.x, y: message.y), clicks: message.clicks)
    }

    private func mouse(_ type: CGEventType, _ button: ScreenWire.MouseButton, _ point: CGPoint, clicks: Int) {
        let cgButton: CGMouseButton = button == .left ? .left : button == .right ? .right : .center
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        lastPoint = point
        post(event)
    }

    func scroll(_ message: ScreenWire.ScrollEvent) {
        guard message.dx.isFinite, message.dy.isFinite,
              abs(message.dx) < Double(Int32.max), abs(message.dy) < Double(Int32.max),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(message.dy), wheel2: Int32(message.dx), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: message.dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: message.dx)
        let phase: Int64
        switch message.phase {
        case .none: phase = 0
        case .began: phase = 1
        case .changed: phase = 2
        case .ended: phase = 4
        case .cancelled: phase = 8
        }
        let momentum: Int64
        switch message.momentum {
        case .none: momentum = 0
        case .began: momentum = 1
        case .changed: momentum = 2
        case .ended: momentum = 3
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.flags = flags
        event.location = lastPoint ?? CGEvent(source: nil)?.location ?? .zero
        post(event)
    }

    func key(_ message: ScreenWire.KeyEvent) {
        if message.down { keys.insert(message.code) } else { keys.remove(message.code) }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: message.code, keyDown: message.down) else { return }
        event.flags = (123...126).contains(message.code) ? flags.union(.maskSecondaryFn) : flags
        post(event)
    }

    static func unicodeChunks(_ text: String, consume: (UnsafeBufferPointer<UInt16>) -> Void) {
        withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 20) { buffer in
            var count = 0
            for unit in text.utf16 {
                if count == 20 || (count == 19 && (0xD800...0xDBFF).contains(unit)) {
                    consume(UnsafeBufferPointer(start: buffer.baseAddress, count: count))
                    count = 0
                }
                buffer[count] = unit
                count += 1
            }
            if count > 0 { consume(UnsafeBufferPointer(start: buffer.baseAddress, count: count)) }
        }
    }

    func text(_ text: String) {
        Self.unicodeChunks(text) { buffer in
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                event.flags = flags
                post(event)
            }
        }
    }

    func release() {
        for code in keys { key(.init(code: code, down: false)) }
        let point = CGEvent(source: nil)?.location ?? lastPoint ?? .zero
        for held in buttons { button(.init(button: held, down: false, x: point.x, y: point.y, clicks: 1)) }
        setModifiers([])
    }
}
