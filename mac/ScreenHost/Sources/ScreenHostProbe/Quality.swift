import AppKit
import ScreenProtocol

private final class QualityWindow {
    let window: NSWindow
    private let view: NSView
    private let pictures: [CGImage]

    init(screen: NSScreen, pictures: [CGImage]) {
        self.pictures = pictures
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        window.contentView = view
        window.orderFrontRegardless()
    }

    func draw(_ frame: Int) { view.layer?.contents = pictures[frame % pictures.count] }
    func still() {
        view.layer?.contents = nil
        view.layer?.backgroundColor = NSColor(deviceRed: 0.08, green: 0.12, blue: 0.18, alpha: 1).cgColor
    }
}

func exerciseQuality(_ connection: Connection) throws {
    let welcome = connection.welcome!
    try require(welcome.access.screen && welcome.access.input && !welcome.locked, "Quality proof needs an unlocked Mac and capture/input grants")
    try connection.wait(2) { !connection.qualityStates.isEmpty && connection.cursorCount > 0 }
    try require(connection.qualityStates.first?.state == .init(mode: .adaptive, level: .high), "New connection must start adaptive/high")
    print("initial_cursor_before_watch=true")
    let pointer = CGEvent(source: nil)!.location
    var seed: UInt32 = 12345
    let pictures: [CGImage] = (0..<8).map { _ in
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4096, bitsPerPixel: 32)!
        let bytes = bitmap.bitmapData!
        for pixel in 0..<(1024 * 1024) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            bytes[pixel * 4] = UInt8(truncatingIfNeeded: seed)
            bytes[pixel * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            bytes[pixel * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 16)
            bytes[pixel * 4 + 3] = 255
        }
        return bitmap.cgImage!
    }
    let windows = NSScreen.screens.map { QualityWindow(screen: $0, pictures: pictures) }
    defer {
        connection.limitReads(every: 0)
        try? connection.send(.watch, ScreenWire.Watch(displays: []))
        try? connection.send(.pointer, ScreenWire.Point(x: pointer.x, y: pointer.y))
        try? connection.pump(0.1)
        windows.forEach { $0.window.close() }
    }
    var tick = 0
    func animate(_ seconds: Double) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            windows.forEach { $0.draw(tick) }
            tick += 1
            try connection.pump(1.0 / 30)
        }
    }
    connection.decodeFrames = false
    connection.watchTime = DispatchTime.now().uptimeNanoseconds
    try connection.send(.watch, ScreenWire.Watch(displays: welcome.displays.map(\.id)))
    for (mode, numerator, denominator): (ScreenWire.QualityMode, Int, Int) in [(.high, 1, 1), (.medium, 3, 4), (.low, 1, 2)] {
        connection.decodeFrames = true
        try connection.send(.quality, ScreenWire.QualityRequest(mode: mode))
        windows.forEach { $0.draw(tick) }
        try connection.wait(15) {
            welcome.displays.allSatisfy {
                guard let image = connection.decoders[$0.id]?.image else { return false }
                return CVPixelBufferGetWidth(image) == $0.pixelWidth * numerator / denominator / 2 * 2
                    && CVPixelBufferGetHeight(image) == $0.pixelHeight * numerator / denominator / 2 * 2
                    && !connection.formatsAwaitingKeyframe.contains($0.id)
            }
        }
        try animate(2)
        connection.decodeFrames = false
        for display in welcome.displays {
            let format = try requireFormat(connection, display: display.id)
            try require(Int(format.width) == display.pixelWidth * numerator / denominator / 2 * 2 && Int(format.height) == display.pixelHeight * numerator / denominator / 2 * 2,
                        "Fixed \(mode.rawValue) pixel size does not match contract")
            print("fixed=\(mode.rawValue) display=\(display.id) pixels=\(format.width)x\(format.height)")
        }
        try require(connection.qualityStates.last?.state.mode == mode, "Fixed mode was not acknowledged")
        connection.bytes.removeAll(); connection.counts.removeAll()
        let start = ProcessInfo.processInfo.systemUptime
        try animate(10)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        for display in welcome.displays {
            print(String(format: "fixed=%@ display=%u received_Mbit_s=%.3f received_fps=%.2f elapsed_s=%.2f", mode.rawValue, display.id,
                         Double(connection.bytes[display.id, default: 0]) * 8 / elapsed / 1_000_000,
                         Double(connection.counts[display.id, default: 0]) / elapsed, elapsed))
        }
    }
    try connection.send(.quality, ScreenWire.QualityRequest(mode: .high))
    try animate(2)
    try connection.send(.quality, ScreenWire.QualityRequest(mode: .adaptive))
    try animate(1)
    connection.qualityStates.removeAll()
    let slowed = ProcessInfo.processInfo.systemUptime
    print("slow_reader_start=\(slowed) limit_Mbit_s=4.194")
    connection.limitReads(every: 0.5)
    try animate(22)
    connection.limitReads(every: 0)
    let cleared = ProcessInfo.processInfo.systemUptime
    print("slow_reader_end=\(cleared)")
    try animate(3)
    let down = connection.qualityStates.map { $0.state.level }
    try require(down.contains(.medium) && down.contains(.low), "Real socket congestion did not reach medium and low")
    // Keep the picture still while the unrestricted socket drains. A blocked
    // still screen must not count as quiet, but a drained one must recover.
    windows.forEach { $0.still() }
    try connection.wait(45) { connection.qualityStates.last?.state.level == .high }
    print("adaptive_recovered_seconds=\(ProcessInfo.processInfo.systemUptime - cleared)")
    connection.decodeFrames = true
    for display in welcome.displays { try connection.send(.keyframe, ScreenWire.KeyframeRequest(display: display.id)) }
    try connection.wait(5) { welcome.displays.allSatisfy { connection.decoders[$0.id]?.image != nil } }
    for display in welcome.displays {
        let destination = ScreenWire.Point(x: display.frame.x + display.frame.width / 2, y: display.frame.y + display.frame.height / 2)
        let feedbackBefore = connection.pointerCount
        for step in 0..<100 {
            try connection.send(.pointer, ScreenWire.Point(x: destination.x - 100 + Double(step), y: destination.y))
            try connection.pump(1.0 / 120)
        }
        try connection.pump(0.3)
        try require(connection.pointerCount == feedbackBefore, "Phone pointer moves were echoed back as external movement")
        print("display=\(display.id) pointer_messages=100 stale_pointer_feedback=0")
        let start = ProcessInfo.processInfo.systemUptime
        try connection.send(.pointer, destination)
        try connection.wait(1) {
            let actual = CGEvent(source: nil)!.location
            return hypot(actual.x - destination.x, actual.y - destination.y) < 0.6
        }
        print("display=\(display.id) pointer_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        try connection.send(.keyframe, ScreenWire.KeyframeRequest(display: display.id))
        try connection.pump(0.6)
        let image = connection.decoders[display.id]!.image!
        let ci = CIImage(cvPixelBuffer: image)
        let bitmap = NSBitmapImageRep(cgImage: CIContext().createCGImage(ci, from: ci.extent)!)
        var largestDifference = 0.0
        // The Mac pointer is inside this patch. A baked-in arrow makes a bright
        // or black edge against the flat background and fails this bound.
        for y in (bitmap.pixelsHigh / 2 - 10)..<(bitmap.pixelsHigh / 2 + 100) {
            for x in (bitmap.pixelsWide / 2 - 10)..<(bitmap.pixelsWide / 2 + 100) {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                largestDifference = max(largestDifference, abs(color.redComponent - 0.08), abs(color.greenComponent - 0.12), abs(color.blueComponent - 0.18))
            }
        }
        try require(largestDifference < 0.12, "Captured video contains a cursor or unexpected content in the pointer patch")
        print("display=\(display.id) video_cursor_absent=true patch_max_error=\(largestDifference)")
        if let directory = option("--output") {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let preview = NSImage(size: NSSize(width: 900, height: 900 * ci.extent.height / ci.extent.width))
            preview.lockFocus()
            NSImage(cgImage: bitmap.cgImage!, size: ci.extent.size).draw(in: NSRect(origin: .zero, size: preview.size))
            preview.unlockFocus()
            let png = NSBitmapImageRep(data: preview.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: directory + "/quality-pointer-\(display.id).png"))
        }
    }
    print("quality_proof_passed=true")
}

private func requireFormat(_ connection: Connection, display: UInt32) throws -> ScreenWire.VideoFormat {
    guard let format = connection.formats[display] else { throw ProbeError(message: "No format for display \(display)") }
    return format
}
