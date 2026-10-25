import XCTest
@testable import Term

final class HerdrTests: XCTestCase {
  /// `herdr api snapshot` from herdr 0.9.5: workspace api (a shell, then omp
  /// named api-worker, blocked), web (claude, working), tmp (a shell).
  private static let realSnapshot = #"""
  {"id":"cli:api:snapshot","result":{"snapshot":{"agents":[{"agent":"omp","agent_status":"blocked","cwd":"/private/tmp/herdr-e2e/api","focused":false,"foreground_cwd":"/private/tmp/herdr-e2e/api","name":"api-worker","pane_id":"w1:p2","revision":0,"state_change_seq":1,"tab_id":"w1:t1","terminal_id":"term_65eafc59e364d2","workspace_id":"w1"},{"agent":"claude","agent_status":"working","cwd":"/private/tmp/herdr-e2e/web","focused":false,"foreground_cwd":"/private/tmp/herdr-e2e/web","pane_id":"w2:p1","revision":0,"state_change_seq":2,"tab_id":"w2:t1","terminal_id":"term_65eafc59e40203","workspace_id":"w2"}],"focused_pane_id":"w1:p1","focused_tab_id":"w1:t1","focused_workspace_id":"w1","layouts":[{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w1:p1","panes":[{"focused":true,"pane_id":"w1:p1","rect":{"height":40,"width":60,"x":0,"y":0}},{"focused":false,"pane_id":"w1:p2","rect":{"height":40,"width":60,"x":60,"y":0}}],"splits":[{"direction":"right","id":"split_0_root","ratio":0.5,"rect":{"height":40,"width":120,"x":0,"y":0}}],"tab_id":"w1:t1","workspace_id":"w1","zoomed":false},{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w2:p1","panes":[{"focused":true,"pane_id":"w2:p1","rect":{"height":40,"width":120,"x":0,"y":0}}],"splits":[],"tab_id":"w2:t1","workspace_id":"w2","zoomed":false},{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w3:p1","panes":[{"focused":true,"pane_id":"w3:p1","rect":{"height":40,"width":120,"x":0,"y":0}}],"splits":[],"tab_id":"w3:t1","workspace_id":"w3","zoomed":false}],"panes":[{"agent_status":"unknown","cwd":"/private/tmp/herdr-e2e/api","focused":true,"foreground_cwd":"/private/tmp/herdr-e2e/api","pane_id":"w1:p1","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":38},"tab_id":"w1:t1","terminal_id":"term_65eafc59e2db21","workspace_id":"w1"},{"agent":"omp","agent_status":"blocked","cwd":"/private/tmp/herdr-e2e/api","focused":false,"foreground_cwd":"/private/tmp/herdr-e2e/api","pane_id":"w1:p2","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":38},"tab_id":"w1:t1","terminal_id":"term_65eafc59e364d2","workspace_id":"w1"},{"agent":"claude","agent_status":"working","cwd":"/private/tmp/herdr-e2e/web","focused":false,"foreground_cwd":"/private/tmp/herdr-e2e/web","pane_id":"w2:p1","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40},"tab_id":"w2:t1","terminal_id":"term_65eafc59e40203","workspace_id":"w2"},{"agent_status":"unknown","cwd":"/private/tmp","focused":false,"foreground_cwd":"/private/tmp","pane_id":"w3:p1","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40},"tab_id":"w3:t1","terminal_id":"term_65eafc59e49a44","workspace_id":"w3"}],"protocol":22,"tabs":[{"agent_status":"blocked","focused":true,"label":"1","number":1,"pane_count":2,"tab_id":"w1:t1","workspace_id":"w1"},{"agent_status":"working","focused":false,"label":"1","number":1,"pane_count":1,"tab_id":"w2:t1","workspace_id":"w2"},{"agent_status":"unknown","focused":false,"label":"1","number":1,"pane_count":1,"tab_id":"w3:t1","workspace_id":"w3"}],"version":"0.9.5","workspaces":[{"active_tab_id":"w1:t1","agent_status":"blocked","focused":true,"label":"api","number":1,"pane_count":2,"tab_count":1,"workspace_id":"w1"},{"active_tab_id":"w2:t1","agent_status":"working","focused":false,"label":"web","number":2,"pane_count":1,"tab_count":1,"workspace_id":"w2"},{"active_tab_id":"w3:t1","agent_status":"unknown","focused":false,"label":"tmp","number":3,"pane_count":1,"tab_count":1,"workspace_id":"w3"}]},"type":"session_snapshot"}}
  """#

  private func snapshot(_ text: String = realSnapshot, status: Int32 = 0,
                        file: StaticString = #filePath, line: UInt = #line) -> Herdr.Snapshot {
    switch Herdr.parseSnapshot(status: status, output: Data(text.utf8)) {
    case .success(let s): return s
    case .failure(let f):
      XCTFail("expected a snapshot, got \(f)", file: file, line: line)
      return Herdr.Snapshot(workspaces: [])
    }
  }

  private func failure(_ status: Int32, _ text: String) -> Herdr.Failure? {
    if case .failure(let f) = Herdr.parseSnapshot(status: status, output: Data(text.utf8)) { return f }
    return nil
  }

  // MARK: - Snapshot

  func testRealSnapshotGroupsPanesByWorkspaceBlockedFirst() {
    let s = snapshot()
    XCTAssertEqual(s.workspaces.map(\.label), ["api", "web", "tmp"])
    XCTAssertEqual(s.workspaces[0].panes.map(\.id), ["w1:p2", "w1:p1"], "the blocked agent comes before the shell")
    let worker = s.workspaces[0].panes[0]
    XCTAssertEqual(worker.terminal, "term_65eafc59e364d2")
    XCTAssertEqual(worker.agent, "omp")
    XCTAssertEqual(worker.name, "api-worker", "the name lives only in the agents list")
    XCTAssertEqual(worker.state, .blocked)
    XCTAssertEqual(worker.cwd, "/private/tmp/herdr-e2e/api")
    XCTAssertEqual(worker.title, "api-worker")
    XCTAssertEqual(worker.sessionName, "api-worker")
    XCTAssertEqual(s.workspaces[1].panes.first?.state, .working)
  }

  func testPaneWithoutAgentHasNoStateAndIsNamedForItsWorkspace() {
    let shell = snapshot().workspaces[0].panes[1]
    XCTAssertNil(shell.agent)
    XCTAssertNil(shell.state, "herdr says unknown for a plain shell; that is not an agent state")
    XCTAssertEqual(shell.title, "shell")
    XCTAssertEqual(shell.sessionName, "api")
  }

  func testUnnamedAgentShowsItsKindAndItsWorkspaceElsewhere() {
    let claude = snapshot().workspaces[1].panes[0]
    XCTAssertEqual(claude.title, "claude")
    XCTAssertEqual(claude.sessionName, "web")
  }

  func testOrderIsBlockedDoneWorkingIdleUnknownThenNoAgent() {
    let states: [String?] = ["idle", nil, "working", "unknown", "done", "blocked"]
    let panes = states.enumerated().map { i, s in
      #"{"pane_id":"w\#(i):p1","terminal_id":"t\#(i)","workspace_id":"w\#(i)"\#(s.map { #","agent":"x","agent_status":"\#($0)""# } ?? "")}"#
    }
    let workspaces = states.indices.map { #"{"workspace_id":"w\#($0)","label":"l\#($0)"}"# }
    let text = #"{"result":{"snapshot":{"workspaces":[\#(workspaces.joined(separator: ","))],"panes":[\#(panes.joined(separator: ","))]}}}"#
    XCTAssertEqual(snapshot(text).workspaces.map(\.label), ["l5", "l4", "l2", "l0", "l3", "l1"])
  }

  func testEqualUrgencyKeepsHerdrsOrder() {
    let text = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w2","label":"b"},{"workspace_id":"w1","label":"a"}],"panes":[]}}}"#
    XCTAssertEqual(snapshot(text).workspaces.map(\.label), ["b", "a"])
  }

  func testUnknownStateWordFromANewerHerdrIsUnknownNotDropped() {
    let text = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1"}],"panes":[{"pane_id":"w1:p1","terminal_id":"t","workspace_id":"w1","agent":"x","agent_status":"thinking"}]}}}"#
    let s = snapshot(text)
    XCTAssertEqual(s.panes.first?.state, .unknown)
    XCTAssertEqual(s.workspaces.first?.label, "w1", "a workspace without a label shows its id")
  }

  func testEmptyServerHasNoWorkspaces() {
    let text = #"{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[],"layouts":[],"panes":[],"protocol":22,"tabs":[],"version":"0.9.5","workspaces":[]},"type":"session_snapshot"}}"#
    XCTAssertEqual(snapshot(text).workspaces, [])
  }

  func testLogLineBeforeTheJSONIsSkipped() {
    XCTAssertEqual(snapshot("note: a newer herdr is available\n" + Self.realSnapshot).workspaces.count, 3)
  }

  // MARK: - Failures

  func testStatus127IsNotInstalled() {
    XCTAssertEqual(failure(127, "zsh:1: command not found: herdr\n"), .notInstalled)
    XCTAssertEqual(failure(127, ""), .notInstalled)
  }

  func testServerNotRunningIsItsOwnCase() {
    let text = #"{"id":"cli:api:snapshot","error":{"code":"server_not_running","message":"no herdr server is running at /x/herdr.sock; run `herdr session attach x` to start or attach it"}}"#
    XCTAssertEqual(failure(1, text), .notRunning)
    XCTAssertEqual(Herdr.Failure.notRunning.message(host: "mac"), "herdr is not running on mac. Start it on the computer.")
  }

  func testOtherErrorsCarryHerdrsMessage() {
    let text = #"{"error":{"code":"pane_not_found","message":"pane w9:p9 not found"},"id":"cli:pane:read"}"#
    XCTAssertEqual(failure(1, text), .failed("pane w9:p9 not found"))
  }

  func testNonJSONFailureShowsItsText() {
    XCTAssertEqual(failure(2, "error: unexpected argument '--bogus'\n"), .failed("error: unexpected argument '--bogus'"))
    XCTAssertEqual(failure(1, ""), .failed("herdr exited with status 1."))
  }

  func testSuccessThatCannotBeReadIsAFailureNotAnEmptyList() {
    XCTAssertEqual(failure(0, #"{"result":{"snapshot":{"panes":"no"}}}"#), .failed("Term could not read herdr's answer."))
    XCTAssertEqual(failure(0, "not json"), .failed("Term could not read herdr's answer."))
  }

  func testErrorJSONWithStatusZeroIsStillAnError() {
    XCTAssertEqual(failure(0, #"{"error":{"code":"x","message":"boom"}}"#), .failed("boom"))
  }

  // MARK: - Resolving names

  func testResolveTakesAgentNamePaneIdWorkspaceOrTerminal() {
    let s = snapshot()
    XCTAssertEqual(s.resolve("api-worker")?.id, "w1:p2")
    XCTAssertEqual(s.resolve("w2:p1")?.id, "w2:p1")
    XCTAssertEqual(s.resolve("api")?.id, "w1:p1", "a workspace attaches its pane in front, not its most urgent")
    XCTAssertEqual(s.resolve("term_65eafc59e40203")?.id, "w2:p1")
    XCTAssertNil(s.resolve("nope"))
    XCTAssertNil(s.resolve(""))
  }

  func testAgentNameWinsOverAWorkspaceOfTheSameName() {
    let text = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"web","active_tab_id":"w1:t1"},{"workspace_id":"w2","label":"api"}],"panes":[{"pane_id":"w1:p1","terminal_id":"t1","workspace_id":"w1"},{"pane_id":"w2:p1","terminal_id":"t2","workspace_id":"w2","agent":"omp","agent_status":"idle"}],"agents":[{"pane_id":"w2:p1","name":"web"}],"layouts":[{"tab_id":"w1:t1","focused_pane_id":"w1:p1"}]}}}"#
    XCTAssertEqual(snapshot(text).resolve("web")?.id, "w2:p1")
  }

  func testCurrentFollowsThePaneToItsNewTerminalAfterARestart() {
    let s = snapshot()
    var before = s.panes.first { $0.id == "w1:p2" }!
    XCTAssertEqual(s.current(before), before)
    before.terminal = "term_from_before_the_restart"
    XCTAssertEqual(s.current(before)?.terminal, "term_65eafc59e364d2")
    before.id = "w9:p9"
    XCTAssertNil(s.current(before), "a closed pane is gone, not some other pane")
  }

  func testPaneForTarget() {
    let s = snapshot()
    XCTAssertEqual(s.pane(for: .terminal("term_65eafc59e364d2"))?.id, "w1:p2")
    XCTAssertEqual(s.pane(for: .agent("api-worker"))?.id, "w1:p2")
    XCTAssertEqual(s.pane(for: .agent("w2:p1"))?.id, "w2:p1")
    XCTAssertNil(s.pane(for: .terminal("w1:p1")), "terminal attach takes terminal ids only")
  }

  // MARK: - Commands

  func testAttachCommandFindsHerdrAndTakesThePane() {
    XCTAssertEqual(Herdr.attachCommand("term_65eafc59e364d2"),
                   #"env PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin" herdr terminal attach term_65eafc59e364d2 --takeover"#)
    XCTAssertTrue(Herdr.attachCommand("x; rm -rf ~").contains("attach 'x; rm -rf ~' --takeover"))
  }

  func testExecCommands() {
    let cli = #"PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin" herdr"#
    XCTAssertEqual(Herdr.snapshotCommand, "\(cli) api snapshot 2>&1")
    XCTAssertEqual(Herdr.historyCommand("w1:p2"), "\(cli) pane read w1:p2 --source recent-unwrapped --lines 3000 --ansi 2>&1")
    XCTAssertEqual(Herdr.historyCommand("it's", lines: 5), #"\#(cli) pane read 'it'\''s' --source recent-unwrapped --lines 5 --ansi 2>&1"#)
    XCTAssertEqual(Herdr.paneCommand("w1:p2"), "\(cli) pane get w1:p2 2>&1")
  }

  func testCreateCommandChecksTheFolderBeforeHerdrFallsBackToHome() {
    let cli = #"PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin" herdr"#
    XCTAssertEqual(Herdr.createCommand(cwd: " ~/Projects/my app "),
                   #"if cd ~/'Projects/my app' 2>/dev/null; then \#(cli) workspace create --cwd "$PWD" --no-focus 2>&1; "#
                     + #"else echo 'No folder ~/Projects/my app.'; exit 1; fi"#)
    XCTAssertEqual(Herdr.createCommand(cwd: ""),
                   #"if cd ~ 2>/dev/null; then \#(cli) workspace create --cwd "$PWD" --no-focus 2>&1; "#
                     + #"else echo 'No folder ~.'; exit 1; fi"#)
  }

  func testShellPathExpandsHomeAndQuotesTheRest() {
    XCTAssertEqual(Herdr.shellPath(""), "~")
    XCTAssertEqual(Herdr.shellPath("  ~ "), "~")
    XCTAssertEqual(Herdr.shellPath("~/"), "~/''")
    XCTAssertEqual(Herdr.shellPath("~/src"), "~/src")
    XCTAssertEqual(Herdr.shellPath("/tmp/a b"), "'/tmp/a b'")
    XCTAssertEqual(Herdr.shellPath("$(reboot)"), "'$(reboot)'")
    XCTAssertEqual(Herdr.shellPath("~other/x"), "'~other/x'", "only the user's own home expands")
  }

  func testDisplayPathShowsHomeAsTilde() {
    XCTAssertEqual(Herdr.displayPath("/Users/me/Projects/api", user: "me"), "~/Projects/api")
    XCTAssertEqual(Herdr.displayPath("/home/me", user: "me"), "~")
    XCTAssertEqual(Herdr.displayPath("/Users/meg/x", user: "me"), "/Users/meg/x")
    XCTAssertEqual(Herdr.displayPath("/private/tmp", user: "me"), "/private/tmp")
  }

  // MARK: - Other answers

  func testCreatedWorkspaceGivesItsPane() {
    let text = #"{"id":"cli:workspace:create","result":{"root_pane":{"agent_status":"unknown","cwd":"/private/tmp","focused":false,"foreground_cwd":"/private/tmp","pane_id":"w3:p1","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40},"tab_id":"w3:t1","terminal_id":"term_65eafac32e4eb4","workspace_id":"w3"},"tab":{"agent_status":"unknown","focused":false,"label":"1","number":1,"pane_count":1,"tab_id":"w3:t1","workspace_id":"w3"},"type":"workspace_created","workspace":{"active_tab_id":"w3:t1","agent_status":"unknown","focused":false,"label":"tmp","number":3,"pane_count":1,"tab_count":1,"workspace_id":"w3"}}}"#
    let pane = try? Herdr.parseCreated(status: 0, output: Data(text.utf8)).get()
    XCTAssertEqual(pane, Herdr.Pane(id: "w3:p1", terminal: "term_65eafac32e4eb4", workspace: "tmp", cwd: "/private/tmp"))
  }

  func testCreateInAMissingFolderShowsWhy() {
    let result = Herdr.parseCreated(status: 1, output: Data("No folder /nope.\n".utf8))
    XCTAssertEqual(result, .failure(.failed("No folder /nope.")))
  }

  func testFolderIsTheForegroundProcessesThenThePanes() {
    func folder(_ pane: String) -> Result<String, Herdr.Failure> {
      Herdr.parseFolder(status: 0, output: Data(#"{"result":{"pane":{"pane_id":"w1:p1","terminal_id":"t","workspace_id":"w1",\#(pane)}}}"#.utf8))
    }
    XCTAssertEqual(folder(#""cwd":"/a","foreground_cwd":"/a/sub""#), .success("/a/sub"))
    XCTAssertEqual(folder(#""cwd":"/a""#), .success("/a"))
    XCTAssertEqual(folder(#""cwd":"""#), .failure(.failed("herdr knows no folder for pane w1:p1.")))
  }

  func testHistoryIsTheRawTextOrHerdrsError() {
    let text = Data("\u{1b}[0mred\r\nprompt % ".utf8)
    XCTAssertEqual(Herdr.parseHistory(status: 0, output: text), .success(text))
    let error = Data(#"{"error":{"code":"pane_not_found","message":"pane w1:p9 not found"}}"#.utf8)
    XCTAssertEqual(Herdr.parseHistory(status: 1, output: error), .failure(.failed("pane w1:p9 not found")))
  }

  @MainActor
  func testHistoryKeepsHerdrsCRLFAndAddsCRToBareLF() {
    let bytes = HistoryViewController.terminalBytes(Data("a\r\nb\nc".utf8))
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "a\r\nb\r\nc\u{1b}[?25l")
  }

  // MARK: - Startup commands

  func testTargetFromAttachCommandsRoundTrips() {
    for id in ["term_65eafc59e364d2", "x y", "it's"] {
      XCTAssertEqual(Herdr.target(inCommand: Herdr.attachCommand(id)), .terminal(id))
    }
    XCTAssertEqual(Herdr.target(inCommand: "herdr agent attach reviewer --takeover"), .agent("reviewer"))
    XCTAssertEqual(Herdr.target(inCommand: "/Users/me/.local/bin/herdr terminal attach t1"), .terminal("t1"))
    XCTAssertEqual(Herdr.target(inCommand: "herdr --session work terminal attach t1"), .terminal("t1"))
    XCTAssertEqual(Herdr.target(inCommand: "HERDR_SESSION=x herdr agent attach w1:p2"), .agent("w1:p2"))
  }

  func testNoTargetWhenNothingSpecificIsAttached() {
    XCTAssertNil(Herdr.target(inCommand: "herdr"))
    XCTAssertNil(Herdr.target(inCommand: "herdr agent list"))
    XCTAssertNil(Herdr.target(inCommand: "herdr terminal attach"))
    XCTAssertNil(Herdr.target(inCommand: "echo herdr terminal attach t1"))
    XCTAssertNil(Herdr.target(inCommand: ""))
    XCTAssertNil(Herdr.target(inCommand: "herdr terminal attach 'unterminated"))
  }

  func testRunsHerdrDecidesReconnectAndIdleTimeout() {
    func spec(_ command: String?) -> ConnectSpec {
      ConnectSpec(transport: .mosh, hostname: "h", port: 22, user: "u", command: command, prediction: .adaptive, label: "h")
    }
    XCTAssertTrue(spec(Herdr.attachCommand("t")).runsInHerdr)
    XCTAssertTrue(spec("herdr").runsInHerdr)
    XCTAssertTrue(spec("/opt/homebrew/bin/herdr agent attach x").runsInHerdr)
    XCTAssertFalse(spec(nil).runsInHerdr)
    XCTAssertFalse(spec("tmux new -A -s main").runsInHerdr)
    XCTAssertFalse(spec("env FOO=1 zsh").runsInHerdr)
    XCTAssertFalse(spec("herdrx").runsInHerdr)
    XCTAssertEqual(spec("herdr").idleTimeout, 120)
    XCTAssertEqual(spec(nil).idleTimeout, 604_800)
  }
}
