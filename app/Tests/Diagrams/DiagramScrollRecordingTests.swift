import UIKit
import XCTest
@testable import Term

/// Opt-in real SSH/tmux reproduction, driven by scripts/verify-diagram-scroll.py.
@MainActor
final class DiagramScrollRecordingTests: XCTestCase {
  func testReferenceLocatesBothPartsOfAPartialJump() {
    let reference = (0..<30).map { "reference row \($0)" }
    let screen = ["status"] + Array(reference[0..<5]) + Array(reference[25..<30])
    XCTAssertEqual(DiagramScrollReference.locate(screen, in: reference),
                   [nil, 0, 1, 2, 3, 4, 25, 26, 27, 28, 29])
  }

  func testReferenceDoesNotTreatPartiallyWrittenRowsAsComplete() {
    let reference = (0..<12).map { "reference row \($0)" }
    var screen = ["status"] + reference
    screen[6] = "reference r"
    XCTAssertNil(DiagramScrollReference.locate(screen, in: reference)[6])
  }

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
    func execute(_ command: String) async throws -> String {
      let output = try await RemoteExec.run(spec, command).get()
      XCTAssertEqual(output.status, 0, String(decoding: output.stdout, as: UTF8.self))
      return String(decoding: output.stdout, as: UTF8.self)
    }
    _ = try await execute("\(tmux) new-session -d -s \(target) -x 80 -y 40 'stty -echo; exec /bin/sh'; \(tmux) set-option -t \(target) mouse on; \(tmux) set-option -t \(target) status-position top")
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
      let source = try XCTUnwrap(samples[type])
      sources.append((type, source))
      rows += ["Diagram: \(type)", "", "```mermaid"] + source.components(separatedBy: "\n") + ["```", "", ""]
    }
    rows += (0..<20).map { "Following paragraph \($0)" }
    let publication = try JSONSerialization.data(withJSONObject: ["v": 1, "d": sources.enumerated().map {
      ["h": $0.element.0, "t": $0.offset + 1, "src": $0.element.1] as [String: Any]
    }])
    _ = try await execute("\(tmux) set-option -p -t \(target) @diagrams \(Command.shellQuote(String(decoding: publication, as: UTF8.self)))")
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
    // Disable shell echo before printing, so g visits diagrams, not the command
    // that happened to print their sources into the private fixture.
    let printCommand = "printf '\\033[2J\\033[H'; printf '%s\\n' " + rows.map(Command.shellQuote).joined(separator: " ")
    _ = try await execute("\(tmux) send-keys -t \(target) -l \(Command.shellQuote(printCommand)); \(tmux) send-keys -t \(target) Enter")
    try await Task.sleep(for: .seconds(3))
    let reference = try await execute("\(tmux) capture-pane -p -S - -t \(target)")
    let candidates = sources.enumerated().map { DiagramMatcher.Candidate(hash: $0.element.0, time: Double($0.offset), source: $0.element.1) }
    let referenceRows = reference.components(separatedBy: "\n")
    let referenceMatches = DiagramMatcher.match(referenceRows, candidates, screen: false)
    XCTAssertEqual(Set(referenceMatches.map(\.hash)), Set(sources.map(\.0)), "The real tmux fixture must contain all seven diagrams")
    let probe = DiagramScrollProbe(terminal: terminal, reference: referenceRows, matches: referenceMatches)
    let link = CADisplayLink(target: probe, selector: #selector(DiagramScrollProbe.observe))
    link.add(to: .main, forMode: .common)
    defer { link.invalidate() }
    _ = try await execute("\(tmux) copy-mode -t \(target); \(tmux) send-keys -t \(target) -X history-bottom")
    terminal.scrollAnchor = (col: 10, row: 10)
    try await Task.sleep(for: .seconds(1))
    probe.phase = "cold-up"
    try "ready".write(to: evidence.appending(path: "ready"), atomically: true, encoding: .utf8)
    probe.begin()
    try await Task.sleep(for: .seconds(2))
    for _ in 0..<referenceRows.count {
      terminal.scroll(points: terminal.cellSizePoints.height)
      try await Task.sleep(for: .milliseconds(30))
    }
    probe.phase = "warm-down"
    _ = try await execute("\(tmux) send-keys -t \(target) -X history-top")
    for _ in stride(from: 0, through: referenceRows.count, by: 8) {
      terminal.scroll(points: -8 * terminal.cellSizePoints.height)
      try await Task.sleep(for: .milliseconds(160))
    }
    XCTAssertEqual(probe.known, Set(sources.map(\.0)), "Warm-up must actually show every image")
    var times: [Double] = []
    let profile = FileManager.default.fileExists(atPath: evidence.appending(path: "profile").path)
    if profile {
      // This explicit benchmark bypasses coalescing; normal recordings do not.
      session.onFrame = {
        let start = CACurrentMediaTime()
        terminal.render()
        times.append((CACurrentMediaTime() - start) * 1000)
      }
    }
    try await Task.sleep(for: .seconds(1))
    probe.phase = "slow"
    for _ in 0..<65 {
      terminal.scroll(points: terminal.cellSizePoints.height)
      try await Task.sleep(for: .milliseconds(80))
    }
    probe.phase = "flick"
    for velocity: CGFloat in [-1700, 2100, -2300, 1600] {
      terminal.momentumVelocity = velocity
      terminal.momentumTime = CACurrentMediaTime()
      terminal.isCoasting = true
      terminal.setNeedsRender(build: false)
      try await Task.sleep(for: .seconds(2))
      terminal.stopCoasting()
    }
    probe.phase = "reversal"
    for velocity: CGFloat in [-3000, 3000, -3000, 3000, -3000, 3000] {
      terminal.momentumVelocity = velocity
      terminal.momentumTime = CACurrentMediaTime()
      terminal.isCoasting = true
      terminal.setNeedsRender(build: false)
      try await Task.sleep(for: .milliseconds(180))
      terminal.stopCoasting()
    }
    probe.phase = "jump"
    for _ in 0..<4 {
      _ = try await execute("\(tmux) send-keys -t \(target) -X history-top")
      try await Task.sleep(for: .milliseconds(300))
      _ = try await execute("\(tmux) send-keys -t \(target) -X history-bottom")
      try await Task.sleep(for: .milliseconds(300))
    }
    let label = run.trimmingCharacters(in: .whitespacesAndNewlines)
    try JSONSerialization.data(withJSONObject: probe.report, options: .sortedKeys).write(to: evidence.appending(path: label + "-coverage.json"))
    XCTAssertGreaterThan(probe.checked, 100, "No real copy-mode screen changes were observed")
    XCTAssertEqual(probe.unlocated, 0, "Every observed screen must be located in the real tmux capture")
    XCTAssertEqual(probe.exposures, 0, "Known diagram rows were exposed; see the coverage report")
    XCTAssertGreaterThan(probe.alignmentChecks, 100, "Image alignment must be exercised against the full capture")
    XCTAssertEqual(probe.misaligned, 0, "Diagram image origins did not follow the captured block geometry")
    if profile {
      let report = ["run": label, "mainFrameMilliseconds": times, "diagrams": sources.count] as [String: Any]
      try JSONSerialization.data(withJSONObject: report).write(to: evidence.appending(path: label + "-timing.json"))
    }
    try "done".write(to: evidence.appending(path: "ready"), atomically: true, encoding: .utf8)
  }
}

/// Observes the normal display-link path without calling render or replacing
/// onFrame. The host's full tmux capture supplies independent row coordinates.
@MainActor
private final class DiagramScrollProbe: NSObject {
  let terminal: TerminalView
  let matches: [DiagramMatcher.Match]
  private let reference: [String]
  private var previous: [String] = []
  private var started: CFTimeInterval?
  private var observations: [[String: Any]] = []
  var phase = "ready"
  private(set) var known: Set<String> = []
  private(set) var checked = 0
  private(set) var unlocated = 0
  private(set) var exposures = 0
  private(set) var alignmentChecks = 0
  private(set) var misaligned = 0

  init(terminal: TerminalView, reference: [String], matches: [DiagramMatcher.Match]) {
    self.terminal = terminal
    self.matches = matches
    self.reference = reference.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  func begin() { started = CACurrentMediaTime(); previous = [] }

  @objc func observe() {
    known.formUnion(terminal.diagramOverlay.shown.map { $0.drawing.hash })
    guard let started else { return }
    let snapshot = terminal.snapshot
    var rows = DiagramOverlay.screenRows(snapshot)
    var counterRows: Set<Int> = []
    for row in rows.indices where row > 0 && (row < 3 || row >= rows.count - 3) {
      let cells = snapshot.cells[(row * snapshot.cols)..<((row + 1) * snapshot.cols)]
      if let column = cells.firstIndex(where: { $0.bg != snapshot.bg }) {
        rows[row] = String(rows[row].prefix(column - row * snapshot.cols))
        counterRows.insert(row)
      }
    }
    rows = rows.map { $0.trimmingCharacters(in: .whitespaces) }
    guard rows != previous, rows.count > 4 else { return }
    previous = rows
    let locations = DiagramScrollReference.locate(rows, in: reference, prefixes: counterRows)
    let unknown = rows.indices.filter { $0 > 0 && !rows[$0].isEmpty && locations[$0] == nil }
    if !unknown.isEmpty { unlocated += 1 }
    checked += 1
    var uncovered: [String] = []
    for row in rows.indices where row > 0 && !rows[row].isEmpty {
      guard let location = locations[row],
            let match = matches.first(where: { $0.top <= location && $0.bottom >= location }),
            known.contains(match.hash) else { continue }
      for col in 0..<snapshot.cols {
        let cell = snapshot.cells[row * snapshot.cols + col]
        guard cell.ch > 32, cell.bg == snapshot.bg else { continue }
        let point = CGPoint(x: terminal.gridOrigin.x / terminal.scale + (CGFloat(col) + 0.5) * terminal.cellSizePoints.width,
                            y: terminal.gridOrigin.y / terminal.scale + (CGFloat(row) + 0.5) * terminal.cellSizePoints.height)
        let covered = terminal.diagramOverlay.shown.contains { shown in
          guard shown.drawing.hash == match.hash, shown.frame.contains(point) else { return false }
          guard let mask = shown.tile.layer.mask as? CAShapeLayer, let path = mask.path else { return true }
          return path.contains(CGPoint(x: point.x - shown.frame.minX, y: point.y - shown.frame.minY), using: .evenOdd)
        }
        if !covered { uncovered.append("\(match.hash):\(row):\(col)") }
      }
    }
    if !uncovered.isEmpty { exposures += 1 }
    var alignmentErrors: [[String: Any]] = []
    for shown in terminal.diagramOverlay.shown {
      guard let block = matches.first(where: { $0.hash == shown.drawing.hash }) else { continue }
      var origins: [Int: Int] = [:]
      for row in rows.indices {
        if let position = locations[row], position >= block.top, position <= block.bottom {
          origins[position - row, default: 0] += 1
        }
      }
      guard let origin = origins.max(by: { $0.value < $1.value })?.key else { continue }
      let image = shown.tile.subviews[0].frame
      let referenceTop = block.top - origin, referenceBottom = block.bottom - origin
      // Equal provisional bounds do not prove the top when the preceding
      // separator is still behind terminal chrome.
      let unseenTop = shown.openTop && !shown.openBottom
      let expected = terminal.gridOrigin.y / terminal.scale + (unseenTop
        ? CGFloat(referenceBottom + 1) * terminal.cellSizePoints.height - image.height
        : CGFloat(referenceTop) * terminal.cellSizePoints.height)
      let actual = shown.frame.minY + image.minY
      alignmentChecks += 1
      if abs(actual - expected) > 0.5 {
        alignmentErrors.append(["hash": block.hash, "expected": expected, "actual": actual, "unseenTop": unseenTop])
      }
    }
    if !alignmentErrors.isEmpty { misaligned += 1 }
    var observation: [String: Any] = ["time": CACurrentMediaTime() - started, "phase": phase,
                                      "unlocatedRows": unknown, "uncovered": uncovered]
    observation["alignmentErrors"] = alignmentErrors
    if !uncovered.isEmpty || !unknown.isEmpty || !alignmentErrors.isEmpty {
      observation["rows"] = rows
      observation["drawings"] = terminal.diagramOverlay.drawings.map { ["hash": $0.hash, "top": $0.top, "bottom": $0.bottom] as [String: Any] }
      observation["shown"] = terminal.diagramOverlay.shown.map { ["hash": $0.drawing.hash, "top": $0.frame.minY, "bottom": $0.frame.maxY] as [String: Any] }
    }
    observations.append(observation)
  }

  var report: [String: Any] {
    ["checkedFrames": checked, "unlocatedFrames": unlocated, "exposedFrames": exposures,
     "knownDiagrams": known.sorted(), "alignmentChecks": alignmentChecks, "misalignedFrames": misaligned, "frames": observations]
  }
}

private enum DiagramScrollReference {
  static func locate(_ rows: [String], in reference: [String], prefixes: Set<Int> = []) -> [Int?] {
    var positions: [String: Int] = [:]
    var repeated: Set<String> = []
    for (row, text) in reference.enumerated() where !text.isEmpty {
      if positions.updateValue(row, forKey: text) != nil { repeated.insert(text) }
    }
    for text in repeated { positions.removeValue(forKey: text) }
    let anchors = rows.indices.compactMap { row -> (row: Int, position: Int)? in
      guard row > 0, let position = positions[rows[row]] else { return nil }
      return (row, position)
    }
    return rows.indices.map { row in
      guard row > 0 else { return nil }
      // A partially delivered jump contains independent old and new regions.
      // The nearest exact anchor supplies a candidate, never a global origin.
      var nearest: Int?
      var distance = Int.max
      for anchor in anchors where abs(anchor.row - row) < distance {
        let position = anchor.position + row - anchor.row
        guard reference.indices.contains(position) else { continue }
        if reference[position] == rows[row] ||
            (prefixes.contains(row) && !rows[row].isEmpty && reference[position].hasPrefix(rows[row])) {
          nearest = position
          distance = abs(anchor.row - row)
        }
      }
      return nearest
    }
  }
}
