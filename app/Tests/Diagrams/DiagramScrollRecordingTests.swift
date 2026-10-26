import UIKit
import XCTest
@testable import Term

/// Opt-in real SSH/tmux reproduction, driven by scripts/verify-diagram-scroll.py.
@MainActor
final class DiagramScrollRecordingTests: XCTestCase {
  func testCopyModeSlowScrollAndFastMomentum() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let evidence = root.appending(path: "local/diagram-scroll")
    guard let run = try? String(contentsOf: evidence.appending(path: "run"), encoding: .utf8) else {
      throw XCTSkip("Diagram recording is opt-in")
    }
    struct Configuration: Decodable { var user: String; var port: Int }
    let fixture = root.appending(path: "local/e2e")
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fixture.appending(path: "reconnect.json")))
    let key = try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8)
    let name = "diagram-scroll-" + UUID().uuidString.prefix(8).lowercased()
    let tmux = "/opt/homebrew/bin/tmux -L termtest"
    let target = Command.shellQuote(name)
    let spec = ConnectSpec(transport: .ssh, hostname: "127.0.0.1", port: config.port, user: config.user,
                           privateKey: key, password: nil, hostKey: nil, command: nil, moshServer: nil,
                           prediction: .never, label: "Diagram scroll")
    func execute(_ command: String) async throws {
      let output = try await RemoteExec.run(spec, command).get()
      XCTAssertEqual(output.status, 0, String(decoding: output.stdout, as: UTF8.self))
    }
    try await execute("\(tmux) new-session -d -s \(target) -x 80 -y 40 /bin/sh; \(tmux) set-option -t \(target) mouse on; \(tmux) set-option -t \(target) status-position top")
    addTeardownBlock { @MainActor in
      _ = await RemoteExec.run(spec, "\(tmux) kill-session -t \(target)")
    }
    let samplesURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pele-samples", withExtension: "json"))
    let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: samplesURL)) as? [String: String])
    let captureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cap-120", withExtension: "txt"))
    let capture = try String(contentsOf: captureURL, encoding: .utf8).components(separatedBy: "\n")
    var rows = ["Diagram scrolling: flowchart and sequence", ""] + Array(capture[32...118]) + [""]
    var sources: [(String, String)] = [("flow", DiagramMatcherTests.flow), ("seq", DiagramMatcherTests.seq)]
    for type in ["pie", "gantt", "gitGraph", "classDiagram", "erDiagram"] {
      guard let source = samples[type] else { continue }
      sources.append((type, source))
      rows += ["Diagram: \(type)", "", "```mermaid"] + source.components(separatedBy: "\n") + ["```", "", ""]
    }
    XCTAssertGreaterThanOrEqual(sources.count, 5)
    rows += (0..<20).map { "Following paragraph \($0)" }
    let publication = try JSONSerialization.data(withJSONObject: ["v": 1, "d": sources.enumerated().map {
      ["h": $0.element.0, "t": $0.offset + 1, "src": $0.element.1] as [String: Any]
    }])
    try await execute("\(tmux) set-option -p -t \(target) @diagrams \(Command.shellQuote(String(decoding: publication, as: UTF8.self)))")
    var connection = spec
    connection.command = "\(tmux) attach-session -t \(target)"
    let session = try XCTUnwrap(Session(connect: connection, cols: 80, rows: 40))
    session.diagrams = DiagramSource(tmuxSession: name) { _ in
      guard let output = try? await RemoteExec.run(spec, "\(tmux) list-panes -t \(target) -F '#{@diagrams}'").get() else { return nil }
      return output.stdout
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    let terminal = TerminalView(session: session)
    terminal.frame = window.bounds
    terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(terminal)
    window.makeKeyAndVisible()
    terminal.layoutIfNeeded()
    defer { session.onFrame = nil; window.isHidden = true }
    try await Task.sleep(for: .seconds(2))
    // The pane's shell prints actual Unicode rows; no local terminal replay.
    let printCommand = "printf '%s\\n' " + rows.map(Command.shellQuote).joined(separator: " ")
    try await execute("\(tmux) send-keys -t \(target) -l \(Command.shellQuote(printCommand)); \(tmux) send-keys -t \(target) Enter")
    try await Task.sleep(for: .seconds(3))
    try await execute("\(tmux) copy-mode -t \(target)")
    terminal.scrollAnchor = (col: 10, row: 10)
    var times: [Double] = []
    let profile = FileManager.default.fileExists(atPath: evidence.appending(path: "profile").path)
    if profile {
      // A synchronous handler benchmark deliberately bypasses display-link
      // coalescing; never use that observer for the visual acceptance recording.
      session.onFrame = {
        let start = CACurrentMediaTime()
        terminal.render()
        times.append((CACurrentMediaTime() - start) * 1000)
      }
    }
    // Host recorder watches this marker, then records the actual framebuffer.
    try "ready".write(to: evidence.appending(path: "ready"), atomically: true, encoding: .utf8)
    try await Task.sleep(for: .seconds(2))
    for _ in 0..<65 {
      terminal.scroll(points: terminal.cellSizePoints.height)
      try await Task.sleep(for: .milliseconds(80))
    }
    for velocity: CGFloat in [-1700, 2100, -2300, 1600] {
      terminal.momentumVelocity = velocity
      terminal.momentumTime = CACurrentMediaTime()
      terminal.isCoasting = true
      terminal.setNeedsRender(build: false)
      try await Task.sleep(for: .seconds(2))
      terminal.stopCoasting()
    }
    let seen = terminal.diagramOverlay.shown.count
    XCTAssertGreaterThan(seen, 0, "No diagrams survived the copy-mode scroll")
    if profile {
      XCTAssertGreaterThan(times.count, 20, "No real copy-mode redraws were measured")
      let report = ["run": run.trimmingCharacters(in: .whitespacesAndNewlines), "mainFrameMilliseconds": times,
                    "diagrams": sources.count, "lastShown": seen] as [String: Any]
      try JSONSerialization.data(withJSONObject: report).write(to: evidence.appending(path: run.trimmingCharacters(in: .whitespacesAndNewlines) + "-timing.json"))
    }
    try "done".write(to: evidence.appending(path: "ready"), atomically: true, encoding: .utf8)
  }
}
