import XCTest
@testable import Term

/// The rail's scripts on a real host: opt-in, against the private sshd of
/// local/e2e (reconnect.json and client_key, as TmuxReconnectTests), whose
/// `tmux` is the isolated `tmux -L termtest` server. Each test makes and
/// ends its own session there.
@MainActor
final class MessageRailRemoteTests: XCTestCase {
  private var host: Host?
  private var keyName = ""
  private var sessionName = ""
  private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "local/e2e")

  override func tearDown() async throws {
    if let host, !sessionName.isEmpty {
      _ = await RemoteExec.run(Tab.spec(for: host), Tmux.killCommand(ids: ["=" + sessionName]))
    }
    Keychain.deleteKey(named: keyName)
  }

  private func connect() throws -> Host {
    struct Configuration: Decodable { var user: String; var port: Int }
    let url = fixture.appending(path: "reconnect.json")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private sshd fixture is not configured") }
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    let key = try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8)
    keyName = "rail-" + UUID().uuidString
    try Keychain.addKey(name: keyName, privateKey: key, publicKey: try XCTUnwrap(SSHKeys.publicKey(for: key)))
    let host = Host(alias: "e2e", hostname: "127.0.0.1", port: config.port, user: config.user, keyName: keyName, transport: .ssh)
    self.host = host
    return host
  }

  private func run(_ command: String) async throws -> String {
    let output = try await RemoteExec.run(Tab.spec(for: try XCTUnwrap(host)), Tmux.path + "; " + command).get()
    return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A 60 × 20 pane that printed 300 lines, the head of message `a` on line 120 and of `b` on line 290,
  /// and published both in `@messages`.
  private func pane() async throws {
    sessionName = "rail-" + UUID().uuidString.prefix(8).lowercased()
    let script = #"i=0; while [ $i -lt 300 ]; do i=$((i+1)); case $i in 120) echo "  The fix is in, line 120";; 290) echo "Ready for review";; *) echo "filler $i";; esac; done; exec sleep 600"#
    _ = try await run("tmux new-session -d -s \(sessionName) -x 60 -y 20 \(Command.shellQuote("sh -c " + Command.shellQuote(script)))")
    let list = #"{"v":1,"m":[{"i":"a","t":1792987200,"h":"The fix is in"},{"i":"b","t":1792987260,"h":"Ready for review"}]}"#
    for _ in 0..<40 {
      if try await run("tmux capture-pane -p -t '=\(sessionName):' | grep -c 'filler 299'") == "1" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    _ = try await run("tmux set-option -p -t '=\(sessionName):' @messages \(Command.shellQuote(list))")
  }

  // Bug: the scripts work in a test double but not in a real login shell (quoting, the heads' here-document,
  // grep's line numbers), so on the phone no mark would show and no jump would land.
  func testARealPaneIsLocatedJumpedToReadAndLeft() async throws {
    let host = try connect()
    try await pane()
    let rail = MessageRail(host: host, tmuxSession: sessionName)
    await rail.refreshed()
    let pane = try XCTUnwrap(rail.pane)
    XCTAssertEqual(pane.height, 20)
    XCTAssertEqual(pane.historySize + pane.height, 301, "300 lines and the cursor's")
    XCTAssertEqual(rail.marks.map(\.message.id), ["a", "b"])
    XCTAssertEqual(rail.marks.map(\.line), [120, 290])
    XCTAssertEqual(rail.marks.first?.text, "The fix is in, line 120")

    let jumped = await rail.jump(to: "a")
    XCTAssertEqual(jumped, .shown(row: 1), "the head on the pane's second row")
    let target = "'=\(sessionName):'"
    // goto-line N puts line hs − N on top: hs − 120 + 2 puts line 120 second.
    let scrolled = try await run("tmux display-message -p -t \(target) '#{pane_in_mode} #{scroll_position}'")
    XCTAssertEqual(scrolled, "1 \(pane.historySize - 120 + 2)")
    let read = try await run("tmux show-options -pqv -t \(target) @read")
    XCTAssertEqual(read, "a", "a jump reads its message, for every device")

    // Line 290 is on the live screen (its 9th row): no copy mode needed, and the one entered for `a` ends.
    let onScreen = await rail.jump(to: "b")
    XCTAssertEqual(onScreen, .shown(row: 290 - 1 - pane.historySize))
    let modeAfterB = try await run("tmux display-message -p -t \(target) '#{pane_in_mode}'")
    XCTAssertEqual(modeAfterB, "0")

    _ = await rail.jump(to: "a")
    rail.backToLive()
    try await Task.sleep(for: .milliseconds(500))
    let modeAfterLive = try await run("tmux display-message -p -t \(target) '#{pane_in_mode}'")
    XCTAssertEqual(modeAfterLive, "0")
  }

  // Bug: tmux dropping the oldest lines at its limit (or omp rewriting the history) shifted every line, and the
  // jump went to the old number.
  func testAJumpAfterTheHistoryShiftedFindsTheLineAgain() async throws {
    let host = try connect()
    try await pane()
    let rail = MessageRail(host: host, tmuxSession: sessionName)
    await rail.refreshed()
    XCTAssertEqual(rail.marks.first?.line, 120)
    _ = try await run("tmux clear-history -t '=\(sessionName):'")
    let jumped = await rail.jump(to: "a")
    XCTAssertEqual(jumped, .gone, "cleared history: the message is no longer there")
    let mode = try await run("tmux display-message -p -t '=\(sessionName):' '#{pane_in_mode}'")
    XCTAssertEqual(mode, "0", "and nothing scrolled")
  }
}
