import AppKit
import ScreenProtocol

final class ProofTextView: NSTextView {
    var commandClick = false
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { commandClick = true }
        super.mouseDown(with: event)
    }
}

final class ProofDragView: NSView {
    var optionDrag = false
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { optionDrag = true }
    }
}

final class ProofStillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(deviceRed: 0.08, green: 0.12, blue: 0.18, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

final class ProofWindow {
    let window: NSWindow
    let scroll: NSScrollView
    let text: ProofTextView
    let dragView = ProofDragView(frame: NSRect(x: 600, y: 30, width: 200, height: 100))
    init(screen: NSScreen) {
        let size = NSSize(width: min(900, screen.frame.width - 100), height: min(700, screen.frame.height - 100))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: screen.frame.minX + 50, y: screen.frame.minY + 50), size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Term Screen Host Proof"
        window.setFrameOrigin(NSPoint(x: screen.frame.minX + 50, y: screen.frame.minY + 50))
        print("proof_window_display=\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]!) frame=\(window.frame)")
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        text = ProofTextView(frame: NSRect(x: 0, y: 0, width: size.width - 20, height: 30000))
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 20, height: 20)
        scroll.documentView = text
        window.contentView = scroll
        dragView.wantsLayer = true
        dragView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        scroll.addSubview(dragView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
    }

    func fill() {
        text.string = (0..<500).map { "remote selection phrase — line \($0): é 日本 text, crisp edges and moving content." }.joined(separator: "\n")
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.scrollToBeginningOfDocument(nil)
    }

    func point(character: Int) -> CGPoint {
        let layout = text.layoutManager!
        let glyph = layout.glyphIndexForCharacter(at: character)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: text.textContainer!)
        let local = NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y)
        let screen = window.convertPoint(toScreen: text.convert(local, to: nil))
        return CGPoint(x: screen.x, y: NSScreen.screens.first!.frame.height - screen.y)
    }
}

func exercise(_ connection: Connection, seconds: Double) throws {
    connection.decodeFrames = false
    let pointer = CGEvent(source: nil)!.location
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { original -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in original.types { if let data = original.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    }
    let windows = NSScreen.screens.map { ProofWindow(screen: $0) }
    defer {
        try? connection.send(.modifiers, ScreenWire.ModifierState(held: []))
        try? connection.send(.button, ScreenWire.ButtonEvent(button: .left, down: false, x: pointer.x, y: pointer.y, clicks: 1))
        try? connection.send(.pointer, ScreenWire.Point(x: pointer.x, y: pointer.y))
        try? connection.pump(0.1)
        pasteboard.clearContents()
        pasteboard.writeObjects(saved)
        for window in windows { window.window.close() }
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    try connection.pump(0.3)
    let proof = windows[0]
    proof.window.makeKeyAndOrderFront(nil)
    proof.window.makeFirstResponder(proof.text)
    try connection.pump(1)
    try require(NSApplication.shared.isActive && proof.window.isKeyWindow && proof.window.firstResponder === proof.text,
                "Proof focus failed: active=\(NSApplication.shared.isActive) key=\(proof.window.isKeyWindow) responder=\(proof.window.firstResponder === proof.text). No input was sent.")
    let unicode = "é 日本 😀"
    try connection.send(.text, ScreenWire.TextInput(text: unicode))
    try connection.pump(1)
    try require(proof.text.string == unicode, "Unicode delivery differed: \(String(reflecting: proof.text.string))")
    print("unicode_exact=true")
    for window in windows { window.fill() }
    try connection.pump(0.2)
    let start = proof.point(character: 2)
    try connection.send(.pointer, ScreenWire.Point(x: start.x + 100, y: start.y + 100))
    try connection.pump(0.1)
    try require(hypot(CGEvent(source: nil)!.location.x - start.x, CGEvent(source: nil)!.location.y - start.y) > 50,
                "Pointer timing must begin away from its destination")
    let sent = DispatchTime.now().uptimeNanoseconds
    try connection.send(.pointer, ScreenWire.Point(x: start.x, y: start.y))
    try connection.wait(1) { hypot(CGEvent(source: nil)!.location.x - start.x, CGEvent(source: nil)!.location.y - start.y) < 0.6 }
    print(String(format: "point_to_pointer_ms=%.3f", Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000))
    func button(_ down: Bool, _ count: Int, _ point: CGPoint) throws {
        try connection.send(.button, ScreenWire.ButtonEvent(button: .left, down: down, x: point.x, y: point.y, clicks: count))
    }
    func drag(from origin: CGPoint, to destination: CGPoint) throws {
        try button(true, 1, origin)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? connection.send(.pointer, ScreenWire.Point(x: destination.x, y: destination.y))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
            try? connection.send(.button, ScreenWire.ButtonEvent(button: .left, down: false, x: destination.x, y: destination.y, clicks: 1))
        }
        try connection.pump(0.3)
    }
    try button(true, 1, start); try button(false, 1, start)
    try button(true, 2, start); try button(false, 2, start)
    try connection.pump(0.2)
    let selection = (proof.text.string as NSString).substring(with: proof.text.selectedRange())
    try require(selection == "remote", "Double-click did not select the word: \(selection)")
    print("double_click_selects_word=true")
    try connection.send(.modifiers, ScreenWire.ModifierState(held: [.command]))
    try button(true, 1, start); try button(false, 1, start)
    try connection.send(.modifiers, ScreenWire.ModifierState(held: []))
    try connection.pump(0.1)
    try require(proof.text.commandClick, "Command-click lost its modifier")
    let end = proof.point(character: 17)
    try drag(from: start, to: end)
    try require(proof.text.selectedRange().length > 5, "Held drag did not extend selection")
    try connection.send(.modifiers, ScreenWire.ModifierState(held: [.option]))
    let dragScreen = proof.window.convertPoint(toScreen: proof.dragView.convert(CGPoint(x: 40, y: 40), to: nil))
    let dragStart = CGPoint(x: dragScreen.x, y: NSScreen.screens.first!.frame.height - dragScreen.y)
    try drag(from: dragStart, to: CGPoint(x: dragStart.x + 80, y: dragStart.y + 20))
    try connection.send(.modifiers, ScreenWire.ModifierState(held: []))
    try connection.pump(0.1)
    try require(proof.dragView.optionDrag, "Option-drag lost its modifier")
    print("command_click=true option_drag=true held_drag_selection=true")
    proof.scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000))
    proof.scroll.reflectScrolledClipView(proof.scroll.contentView)
    try connection.pump(0.1)
    let before = proof.scroll.contentView.bounds.minY
    try connection.send(.pointer, ScreenWire.Point(x: start.x, y: start.y + 100))
    try connection.send(.scroll, ScreenWire.ScrollEvent(dx: 0, dy: 0, phase: .began, momentum: .none))
    for _ in 0..<8 {
        try connection.send(.scroll, ScreenWire.ScrollEvent(dx: 0, dy: 15, phase: .changed, momentum: .none))
        try connection.pump(0.02)
    }
    try connection.send(.scroll, ScreenWire.ScrollEvent(dx: 0, dy: 0, phase: .ended, momentum: .none))
    try connection.send(.scroll, ScreenWire.ScrollEvent(dx: 0, dy: 10, phase: .none, momentum: .began))
    try connection.send(.scroll, ScreenWire.ScrollEvent(dx: 0, dy: 5, phase: .none, momentum: .changed))
    try connection.send(.scroll, ScreenWire.ScrollEvent(dx: 0, dy: 0, phase: .none, momentum: .ended))
    try connection.pump(0.3)
    let after = proof.scroll.contentView.bounds.minY
    try require(after < before, "Positive dy did not move content down: \(before) -> \(after)")
    print("scroll_positive_dy_content_down=true origin_before=\(before) origin_after=\(after)")

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    for y in 0..<8 { for x in 0..<8 { bitmap.setColor(NSColor(deviceRed: x % 2 == 0 ? 0 : 1, green: 0.5, blue: 1, alpha: 1), atX: x, y: y) } }
    let png = bitmap.representation(using: .png, properties: [:])!
    try connection.pump(0.3)
    connection.clipboards.removeAll()
    let incoming = ScreenWire.Clipboard(items: [.init(type: "public.utf8-plain-text", data: Data(unicode.utf8)), .init(type: "public.png", data: png)])
    try connection.send(.setClipboard, incoming)
    try connection.pump(0.6)
    try require(pasteboard.string(forType: .string) == unicode && pasteboard.data(forType: .png) == png, "Incoming clipboard lost text or image")
    try require(connection.clipboards.isEmpty, "Incoming clipboard echoed")
    let item = NSPasteboardItem()
    item.setString("Mac → phone 日本 é", forType: .string)
    item.setData(png, forType: .png)
    pasteboard.clearContents(); pasteboard.writeObjects([item])
    try connection.wait(2) { !connection.clipboards.isEmpty }
    let received = connection.clipboards.last!
    try require(received.items.contains(.init(type: "public.png", data: png)), "Outgoing clipboard lost the image")
    try require(received.items.contains(.init(type: "public.utf8-plain-text", data: Data("Mac → phone 日本 é".utf8))), "Outgoing clipboard lost Unicode")
    print("clipboard_both_directions_text_image=true clipboard_echo=false")

    connection.counts.removeAll(); connection.bytes.removeAll()
    let begin = Date()
    var tick = 0
    while Date().timeIntervalSince(begin) < seconds {
        for window in windows {
            window.scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000 + (tick * 8) % 4000))
            window.scroll.reflectScrolledClipView(window.scroll.contentView)
            window.window.displayIfNeeded()
        }
        NSApplication.shared.updateWindows()
        tick += 1
        try connection.pump(1.0 / 60)
    }
    let elapsed = Date().timeIntervalSince(begin)
    print(String(format: "content_update_fps=%.2f", Double(tick) / elapsed))
    for id in connection.counts.keys.sorted() {
        print(String(format: "display=%u received_fps=%.2f received_Mbit_s=%.2f frames=%d elapsed_s=%.2f", id,
                     Double(connection.counts[id]!) / elapsed, Double(connection.bytes[id]!) * 8 / elapsed / 1_000_000,
                     connection.counts[id]!, elapsed))
    }
    connection.decodeFrames = true
    for display in connection.welcome!.displays { try connection.send(.keyframe, ScreenWire.KeyframeRequest(display: display.id)) }
    try connection.pump(0.5)
    let stillWindows = NSScreen.screens.map { screen -> NSWindow in
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.contentView = ProofStillView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.backgroundColor = NSColor(deviceRed: 0.08, green: 0.12, blue: 0.18, alpha: 1)
        let label = NSTextField(labelWithString: "Term Screen text refresh — é 日本")
        label.font = .monospacedSystemFont(ofSize: 28, weight: .regular)
        label.textColor = .white
        label.frame = NSRect(x: 100, y: 100, width: 1000, height: 50)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        return window
    }
    defer { for window in stillWindows { window.close() } }
    connection.timeline.removeAll()
    connection.recordTimeline = true
    try connection.pump(2)
    connection.recordTimeline = false
    for display in connection.welcome!.displays {
        let frames = connection.timeline[display.id] ?? []
        let refreshes = zip(frames, frames.dropFirst()).filter { before, after in
            (250_000...700_000).contains(after.micros - before.micros)
        }
        try require(!refreshes.isEmpty, "Static text did not receive a sharp refresh on display \(display.id)")
        for (before, after) in refreshes {
            print("display=\(display.id) static_refresh_ms=\(Double(after.received - before.received) / 1000) sharp_bytes=\(after.bytes) sharp_key=\(after.key)")
            if CommandLine.arguments.contains("--expect-refinement") {
                try require(!after.key, "Sharp refresh must refine the current picture, not force a key frame")
            }
        }
        let screenIndex = NSScreen.screens.firstIndex { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.id }!
        let view = stillWindows[screenIndex].contentView!
        let source = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: source)
        let image = connection.decoders[display.id]!.image!
        let ci = CIImage(cvPixelBuffer: image)
        let decoded = NSBitmapImageRep(cgImage: CIContext().createCGImage(ci, from: ci.extent)!)
        try require(source.pixelsWide == decoded.pixelsWide && source.pixelsHigh == decoded.pixelsHigh, "Source and decoded still dimensions differ")
        let scale = Double(source.pixelsWide) / view.bounds.width
        var squaredError = 0.0
        var samples = 0
        for y in Int((view.bounds.height - 150) * scale)..<Int((view.bounds.height - 100) * scale) {
            for x in Int(100 * scale)..<min(source.pixelsWide, Int(1100 * scale)) {
                let a = source.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let b = decoded.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                for difference in [a.redComponent - b.redComponent, a.greenComponent - b.greenComponent, a.blueComponent - b.blueComponent] {
                    squaredError += difference * difference
                    samples += 1
                }
            }
        }
        let rmse = sqrt(squaredError / Double(samples)) * 255
        print(String(format: "display=%u still_text_rmse_255=%.3f", display.id, rmse))
        try require(rmse < 12, "Decoded still text differs from source window: RMSE \(rmse)")
        if let directory = option("--output") {
            try source.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/source-still-\(display.id).png"))
            try connection.decoders[display.id]!.save(directory + "/decoded-still-\(display.id).png")
        }
    }
}
