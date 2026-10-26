import AppKit
import ScreenProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func runProbe() {
do {
    let connection = try Connection()
    try connection.wait(5) { connection.welcome != nil }
    let welcome = connection.welcome!
    print("welcome_version=\(welcome.version) screen_access=\(welcome.access.screen) input_access=\(welcome.access.input) locked=\(welcome.locked) displays=\(welcome.displays.count)")
    if !arguments.contains("--welcome") {
        let directory = option("--output") ?? NSTemporaryDirectory() + "term-screen-shots"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        connection.watchTime = DispatchTime.now().uptimeNanoseconds
        try connection.send(.watch, ScreenWire.Watch(displays: welcome.displays.map(\.id)))
        try connection.wait(15) { welcome.displays.allSatisfy { connection.decoders[$0.id]?.image != nil } }
        for display in welcome.displays {
            let path = directory + "/display-\(display.id).png"
            let decoder = connection.decoders[display.id]!
            try require(CVPixelBufferGetWidth(decoder.image!) == display.pixelWidth && CVPixelBufferGetHeight(decoder.image!) == display.pixelHeight,
                        "Decoded size differs from Welcome")
            try decoder.save(path)
            print(String(format: "display=%u pixels=%dx%d first_key_ms=%.2f png=%@", display.id,
                display.pixelWidth, display.pixelHeight, connection.firstKeyMillis[display.id]!, path))
        }
        if arguments.contains("--exercise") {
            try exercise(connection, seconds: Double(option("--seconds") ?? "15") ?? 15)
        }
        try connection.send(.watch, ScreenWire.Watch(displays: []))
        print("cursor_images=\(connection.cursorCount) external_pointer_updates=\(connection.pointerCount)")
    }
} catch {
    fputs("Screen host proof failed: \(error)\n", stderr)
    exit(1)
}
    exit(0)
}
Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in runProbe() }
app.run()
