import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let host = Host()
do {
    try host.start()
    application.run()
} catch {
    fputs("Term Screen Host: \(error)\n", stderr)
    exit(1)
}
