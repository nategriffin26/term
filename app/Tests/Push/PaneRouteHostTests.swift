import XCTest
@testable import Term

/// The push route's host commands run against the private sshd in local/e2e
/// (skipped without it; its `tmux` uses the isolated socket termtest).
/// A command a stale route runs must change nothing and make nothing.
final class PaneRouteHostTests: XCTestCase {
  private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "local/e2e")
  private var spec: ConnectSpec!
  private var session = ""

  override func setUp() async throws {
    struct Fixture: Decodable { var user: String; var port: Int }
    let url = fixture.appending(path: "reconnect.json")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private sshd fixture is not configured") }
    let config = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    spec = ConnectSpec(transport: .ssh, hostname: "127.0.0.1", port: config.port, user: config.user,
                       privateKey: try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8),
                       prediction: .adaptive, label: "e2e")
    session = "route-" + UUID().uuidString.prefix(8).lowercased()
  }

  override func tearDown() async throws {
    if spec != nil { _ = await RemoteExec.run(spec, "\(Tmux.path); tmux kill-session -t \(Command.shellQuote("=" + session)) 2>/dev/null") }
  }

  private func run(_ command: String) async throws -> RemoteExec.Output {
    try await RemoteExec.run(spec, command).get()
  }

  private func text(_ output: RemoteExec.Output) -> String {
    String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A session with two panes, the first active; returns both as the route lists them.
  private func makeSession() async throws -> (active: TmuxPane, other: TmuxPane) {
    let made = try await run([
      Tmux.path,
      "a=$(tmux -u new-session -d -P -F '#{pane_id}' -s \(Command.shellQuote(session)) 'exec sleep 600')",
      "b=$(tmux split-window -P -F '#{pane_id}' -t \"$a\" 'exec sleep 600')",
      "tmux select-pane -t \"$a\"",
      "printf '%s %s' \"$a\" \"$b\"",
    ].joined(separator: "; "))
    let ids = text(made).split(separator: " ").map(String.init)
    XCTAssertEqual(ids.count, 2, text(made))
    let panes = PaneRoute.parse(try await run(PaneRoute.listCommand).stdout).filter { $0.session == session }
    return (try XCTUnwrap(panes.first { $0.pane == ids[0] }), try XCTUnwrap(panes.first { $0.pane == ids[1] }))
  }

  private func activePane() async throws -> String {
    text(try await run("\(Tmux.path); tmux display-message -p -t \(Command.shellQuote("=" + session + ":")) '#{pane_id}'"))
  }

  func testSelectingTheRoutedPaneMakesItActive() async throws {
    let (_, other) = try await makeSession()
    let selected = try await run(PaneRoute.selectCommand(other))
    XCTAssertEqual(selected.status, 0, text(selected))
    let now = try await activePane()
    XCTAssertEqual(now, other.pane)
  }

  // Bug: only the session name was rechecked, so after a tmux restart a
  // reused pane id was selected for an old push.
  func testAnotherServerGenerationIsRefusedAndChangesNothing() async throws {
    let (active, other) = try await makeSession()
    var restarted = other
    restarted.serverPID = String((Int(other.serverPID) ?? 0) + 1)
    let select = try await run(PaneRoute.selectCommand(restarted))
    XCTAssertEqual(select.status, PaneRoute.goneStatus)
    let attach = try await run(PaneRoute.attachCommand(restarted))
    XCTAssertEqual(attach.status, PaneRoute.goneStatus)
    restarted = other
    restarted.serverStart = String((Int(other.serverStart) ?? 0) - 1)
    let earlier = try await run(PaneRoute.selectCommand(restarted))
    XCTAssertEqual(earlier.status, PaneRoute.goneStatus)
    let now = try await activePane()
    XCTAssertEqual(now, active.pane)
  }

  // Bug: a push's tab attached with `new -A`, so a session that ended after
  // the route was resolved came back empty under the same name.
  func testAGoneSessionIsNeverMadeAgain() async throws {
    let (_, other) = try await makeSession()
    _ = try await run("\(Tmux.path); tmux kill-session -t \(Command.shellQuote("=" + session))")
    let attach = try await run(PaneRoute.attachCommand(other))
    XCTAssertEqual(attach.status, PaneRoute.goneStatus, text(attach))
    let exists = try await run(Tmux.hasSessionCommand(session))
    XCTAssertNotEqual(exists.status, 0, "the attach made the session again")
  }

  // A pane moved to another session is not the routed one.
  func testAPaneInAnotherSessionIsRefused() async throws {
    let (_, other) = try await makeSession()
    var moved = other
    moved.session = session + "-elsewhere"
    let select = try await run(PaneRoute.selectCommand(moved))
    XCTAssertEqual(select.status, PaneRoute.goneStatus)
  }
}
