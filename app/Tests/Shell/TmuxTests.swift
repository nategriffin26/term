import XCTest
@testable import Term

final class TmuxTests: XCTestCase {
  private func parse(_ status: Int32, _ text: String) -> Result<Tmux.Overview, Tmux.ListError> {
    Tmux.parseOverview(status: status, output: Data(text.utf8))
  }

  private func overview(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Tmux.Overview {
    guard case .success(let o) = parse(0, text) else {
      XCTFail("expected sessions from \(text.debugDescription)", file: file, line: line)
      return Tmux.Overview(sessions: [], screens: [:])
    }
    return o
  }

  private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

  /// A list line in `Tmux.fields` order.
  private func line(_ id: String, _ name: String, activity: Int = 100, windows: Int = 1, attached: Int = 0,
                    command: String = "zsh", path: String = "/home/u") -> String {
    "\(id)\t\(activity)\t\(windows)\t\(attached)\t50\t80\t24\t3\t5\t\(command)\t\(path)\t\(name)"
  }

  // MARK: - Overview output

  /// Captured from tmux 3.6a through the test sshd's zsh running
  /// `overviewCommand(skip: ["$0": …])` (home paths made neutral): two
  /// sessions captured, the skipped one listed without a screen, and tmux's
  /// own escaping of a tab in a name.
  func testRealOverviewOutput() {
    let out = "$8\t1792969779\t1\t0\t1792969779\t50\t10\t11\t0\tzsh\t/home/u/term\tit's\\ttab\n"
      + "$7\t1792969779\t1\t2\t1792969779\t60\t12\t11\t2\tzsh\t/private/tmp\tmy work\n"
      + "$0\t1792950408\t1\t0\t1792945985\t51\t25\t8\t22\tzsh\t/home/u\tt1\n"
      + "\u{1e}$7\n\u{1b}[32me2e\u{1b}[39m /tmp % printf red\n\u{1b}[31mred\u{1b}[0m plain\n\n"
      + "\u{1e}$8\n\u{1b}[32me2e\u{1b}[39m term % \n\n\n"
    let o = overview(out)
    XCTAssertEqual(o.sessions.map(\.name), ["it's\\ttab", "my work", "t1"])
    let work = o.sessions[1]
    XCTAssertEqual(work, Tmux.Session(id: "$7", name: "my work", windows: 1, attached: 2, created: at(1_792_969_779),
                                      lastActivity: at(1_792_969_779), command: "zsh", path: "/private/tmp",
                                      width: 60, height: 12, cursorX: 11, cursorY: 2))
    XCTAssertEqual(Set(o.screens.keys), ["$7", "$8"])
    XCTAssertEqual(o.screens["$7"], "\u{1b}[32me2e\u{1b}[39m /tmp % printf red\n\u{1b}[31mred\u{1b}[0m plain\n")
    XCTAssertEqual(o.screens["$8"], "\u{1b}[32me2e\u{1b}[39m term % \n\n")
  }

  func testFieldsAreReadInTheCommandsOrder() {
    let o = overview("$3\t300\t4\t2\t200\t120\t40\t7\t9\tnvim\t/srv/app\tmain\n")
    XCTAssertEqual(o.sessions, [Tmux.Session(id: "$3", name: "main", windows: 4, attached: 2, created: at(200),
                                            lastActivity: at(300), command: "nvim", path: "/srv/app",
                                            width: 120, height: 40, cursorX: 7, cursorY: 9)])
  }

  /// The name is the last field, so tabs, spaces and colons in it can't shift the others.
  func testNamesWithTabsSpacesColonsAndDotsSurvive() {
    let o = overview([line("$1", "my work"), line("$2", "a\tb", activity: 90), line("$3", "x:8080 api.v2", activity: 80)]
      .joined(separator: "\n"))
    XCTAssertEqual(o.sessions.map(\.name), ["my work", "a\tb", "x:8080 api.v2"])
    XCTAssertEqual(o.sessions[1].path, "/home/u")
  }

  func testMostRecentlyActiveFirst() {
    let o = overview([line("$1", "old", activity: 100), line("$2", "new", activity: 300), line("$3", "mid", activity: 200)]
      .joined(separator: "\n"))
    XCTAssertEqual(o.sessions.map(\.name), ["new", "mid", "old"])
  }

  func testEmptyOutputIsNoSessions() {
    XCTAssertEqual(overview(""), Tmux.Overview(sessions: [], screens: [:]))
    XCTAssertEqual(overview("\n\n"), Tmux.Overview(sessions: [], screens: [:]))
  }

  func testMalformedLinesAreSkippedAndGoodOnesKept() {
    let text = [
      line("$1", "good"),
      "$2\t100\t1\t0\t50\t80\t24\t3\t5\tzsh",
      line("noid", "bad id"),
      line("$4", "x").replacingOccurrences(of: "\t80\t", with: "\twide\t"),
      "",
      line("$5", "also good", activity: 50),
    ].joined(separator: "\n")
    XCTAssertEqual(overview(text).sessions.map(\.name), ["good", "also good"])
  }

  func testWindowsLineEndingsAndMissingFinalNewline() {
    XCTAssertEqual(overview(line("$1", "a", activity: 5) + "\r\n" + line("$2", "b", activity: 6)).sessions.map(\.name), ["b", "a"])
  }

  /// A screen keeps its blank rows; only the newline tmux ends it with goes.
  func testScreensKeepBlankRowsAndBelongToTheirId() {
    let o = overview(line("$1", "a") + "\n\u{1e}$1\ntop\n\n\nbottom\n\u{1e}$2\n\n")
    XCTAssertEqual(o.screens["$1"], "top\n\n\nbottom")
    XCTAssertEqual(o.screens["$2"], "")
  }

  func testSessionsNotCapturedHaveNoScreen() {
    XCTAssertEqual(overview(line("$1", "a") + "\n").screens, [:])
  }

  // MARK: - Failures

  func testNoServerRunningIsItsOwnState() {
    XCTAssertEqual(parse(1, "no server running on /private/tmp/tmux-502/default\n"), .failure(.notRunning))
    XCTAssertEqual(parse(1, "error connecting to /tmp/tmux-501/default (No such file or directory)\n"), .failure(.notRunning))
  }

  func testStatus127IsTmuxNotInstalled() {
    XCTAssertEqual(parse(127, "zsh:1: command not found: tmux\n"), .failure(.notInstalled))
    XCTAssertEqual(parse(127, ""), .failure(.notInstalled))
  }

  func testOtherFailuresCarryStatusAndOutput() {
    XCTAssertEqual(parse(1, "protocol version mismatch\n"), .failure(.failed(status: 1, output: "protocol version mismatch")))
    XCTAssertEqual(parse(255, "Permission denied\n"), .failure(.failed(status: 255, output: "Permission denied")))
  }

  func testSessionsWithNonZeroStatusAreNotTrusted() {
    XCTAssertEqual(parse(2, line("$1", "a")), .failure(.failed(status: 2, output: line("$1", "a"))))
  }

  // MARK: - Commands

  /// The capture loop reads id then activity; the parser reads every field
  /// with the name last. Both depend on this order.
  /// Bug: activity read from session_activity, which tmux moves only on key
  /// input, so a session printing output (a build, a log) kept its first
  /// snapshot and showed the age of its creation. window_activity moves on output.
  func testOverviewCommandListsTheParsersFieldsInOrder() {
    let command = Tmux.overviewCommand()
    let format = command.components(separatedBy: "list-sessions -F '")[1].components(separatedBy: "'")[0]
    XCTAssertEqual(format.components(separatedBy: "\t"), Tmux.fields.map { "#{\($0)}" })
    XCTAssertEqual(Tmux.fields.first, "session_id")
    XCTAssertEqual(Tmux.fields[1], "window_activity")
    XCTAssertEqual(Tmux.fields.last, "session_name")
    XCTAssertTrue(command.hasPrefix(Tmux.path + "; "))
    XCTAssertTrue(command.contains(#"tmux capture-pane -p -e -J -t "$i""#))
    XCTAssertTrue(command.contains(#"printf '\036%s\n' "$i""#))
  }

  /// Bug: a tmux server with no sessions showed "tmux failed": the capture
  /// loop ran once for the empty line and its failed capture became the
  /// exec's status (a session killed between list and capture did the same).
  /// Seen through the test sshd: the fixed command shows "No sessions".
  func testOverviewCommandSucceedsOnceTheListIsRead() {
    let command = Tmux.overviewCommand()
    XCTAssertTrue(command.contains(#"do [ -n "$i" ] || continue; case"#), command)
    XCTAssertTrue(command.contains(#"tmux capture-pane -p -e -J -t "$i" 2>/dev/null;;"#), command)
    XCTAssertTrue(command.hasSuffix("; done; exit 0"), command)
  }

  /// Unchanged sessions are skipped by id and activity in whole seconds,
  /// inside single quotes so "$3" is not a shell variable.
  func testOverviewCommandSkipsKnownSessions() {
    let command = Tmux.overviewCommand(skip: ["$3": at(1_700_000_000.9), "$10": at(5)])
    XCTAssertTrue(command.contains("case ' $10:5 $3:1700000000 ' in"), command)
    XCTAssertTrue(Tmux.overviewCommand().contains("case '  ' in"))
  }

  /// Seen working through the test sshd's zsh: created, duplicate refused,
  /// missing folder refused, unnamed session named by tmux.
  func testNewCommand() {
    XCTAssertEqual(Tmux.newCommand(name: "web app", folder: "~/Projects"),
                   "cd ~/Projects 2>/dev/null || { echo 'No such folder'; exit 2; }; \(Tmux.path); "
                   + #"tmux new -d -P -F '#{session_name}' -s 'web app' -c "$PWD" 2>&1"#)
    XCTAssertTrue(Tmux.newCommand(name: "", folder: "").hasPrefix("cd ~ 2>/dev/null"))
    XCTAssertFalse(Tmux.newCommand(name: "", folder: "/tmp").contains(" -s "))
    XCTAssertTrue(Tmux.newCommand(name: "x", folder: "~/my dir").hasPrefix("cd ~/'my dir' 2>"))
    XCTAssertTrue(Tmux.newCommand(name: "x", folder: " /srv/it's ").hasPrefix(#"cd '/srv/it'\''s' 2>"#))
    XCTAssertTrue(Tmux.newCommand(name: "a;b", folder: "~").contains("-s 'a;b' -c"))
  }

  /// "$3" unquoted is an empty shell variable, and tmux then targets the
  /// most recent session instead.
  func testActionsTargetTheSessionIdQuoted() {
    XCTAssertEqual(Tmux.renameCommand(id: "$3", to: "new name"), "\(Tmux.path); tmux rename-session -t '$3' 'new name' 2>&1")
    XCTAssertEqual(Tmux.killCommand(id: "$3"), "\(Tmux.path); tmux kill-session -t '$3' 2>&1")
    XCTAssertEqual(Tmux.detachOthersCommand(id: "$3", keep: []), "\(Tmux.path); tmux detach-client -s '$3' 2>&1")
  }

  /// Term's own clients (by size) stay attached; seen on the test sshd with
  /// clients of 70x20 and 44x30, keeping 44x30.
  func testDetachOthersKeepsTermsSizes() {
    XCTAssertEqual(Tmux.detachOthersCommand(id: "$7", keep: ["80x24", "44x30"]),
                   "\(Tmux.path); tmux list-clients -t '$7' -F '#{client_width}x#{client_height} #{client_tty}' | "
                   + #"while read -r z t; do case ' 44x30 80x24 ' in *" $z "*) ;; *) tmux detach-client -t "$t";; esac; done"#)
  }

  func testCleanNameDoesWhatTmuxDoes() {
    XCTAssertEqual(Tmux.cleanName("  a.b:c d "), "a_b_c d")
    XCTAssertEqual(Tmux.cleanName("   "), "")
  }

  func testShellPathKeepsTildeExpandable() {
    XCTAssertEqual(Tmux.shellPath("~"), "~")
    XCTAssertEqual(Tmux.shellPath("~/a b"), "~/'a b'")
    XCTAssertEqual(Tmux.shellPath("~user"), "'~user'")
    XCTAssertEqual(Tmux.shellPath("/tmp"), "/tmp")
    XCTAssertEqual(Tmux.shellPath("/tmp/$HOME"), "'/tmp/$HOME'")
  }

  /// A snapshot is drawn from a cleared screen, row by row with attributes
  /// reset at each row's end, the cursor where tmux had it (1-based).
  func testScreenBytes() {
    let bytes = String(decoding: Tmux.screenBytes("\u{1b}[44mtop\nnext", cursorX: 0, cursorY: 1), as: UTF8.self)
    XCTAssertEqual(bytes, "\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[44mtop\u{1b}[0m\r\nnext\u{1b}[0m\u{1b}[2;1H")
  }

  func testAttachCommandCreatesOrAttachesByName() {
    XCTAssertEqual(Tmux.attachCommand("main"), "tmux new -A -s main")
    XCTAssertEqual(Tmux.attachCommand("my work"), "tmux new -A -s 'my work'")
    XCTAssertEqual(Tmux.attachCommand("it's"), #"tmux new -A -s 'it'\''s'"#)
    XCTAssertEqual(Tmux.attachCommand("x; rm -rf ~"), "tmux new -A -s 'x; rm -rf ~'")
  }

  func testHistoryCommand() {
    XCTAssertEqual(Tmux.historyCommand(nil), "tmux capture-pane -p -e -J -S -3000")
    XCTAssertEqual(Tmux.historyCommand("main"), "tmux capture-pane -p -e -J -S -3000 -t main")
    XCTAssertEqual(Tmux.historyCommand("my work", lines: 50), "tmux capture-pane -p -e -J -S -50 -t 'my work'")
  }

  // MARK: - Session name from a startup command

  func testSessionNameFromAttachingCommands() {
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux new -A -s main"), "main")
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux attach -t main"), "main")
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux a -t main"), "main")
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux new-session -A -s main"), "main")
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux -L work new -A -s main -d"), "main")
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux new -A -s 'my work'"), "my work")
  }

  func testSessionNameNilWhenThereIsNoneToFind() {
    XCTAssertNil(Tmux.sessionName(inCommand: ""))
    XCTAssertNil(Tmux.sessionName(inCommand: "tmux"))
    XCTAssertNil(Tmux.sessionName(inCommand: "tmux attach"))
    XCTAssertNil(Tmux.sessionName(inCommand: "tmux new -A -s"))
    XCTAssertNil(Tmux.sessionName(inCommand: "ls -t main"))
    XCTAssertNil(Tmux.sessionName(inCommand: "tmux new -A -s 'main"))
  }

  /// Combined short flags are how people actually type it.
  func testSessionNameFromCombinedFlags() {
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux new -As main"), "main")
    XCTAssertEqual(Tmux.sessionName(inCommand: "tmux new -Ads main"), "main")
  }

  func testAttachCommandRoundTripsThroughSessionNameForAnyName() {
    var rng = SeededRandom(seed: 7)
    let alphabet: [Character] = ["a", "Z", "0", " ", "'", "\"", "\\", "$", ";", "-", "_", "é", "日", "\t", "&"]
    for _ in 0..<1000 {
      let n = 1 + Int(rng.next() % 10)
      let name = String((0..<n).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
      if Tmux.sessionName(inCommand: Tmux.attachCommand(name)) != name {
        XCTFail("\(name.debugDescription) came back as \(String(describing: Tmux.sessionName(inCommand: Tmux.attachCommand(name))))")
        return
      }
    }
  }

  /// tmux 3.6's own words (recorded from `tmux -L`), which showed raw in the
  /// new-session page and the rename and kill alerts.
  func testReadableErrorFromTmuxComplaints() {
    XCTAssertEqual(Tmux.readableError("duplicate session: api\n"), "api already exists")
    XCTAssertEqual(Tmux.readableError("duplicate session: a: b"), "a: b already exists")
    XCTAssertEqual(Tmux.readableError("can't find session: $999"), "That session has ended")
    XCTAssertEqual(Tmux.readableError("no server running on /private/tmp/tmux-501/default"), "tmux isn't running")
    XCTAssertEqual(Tmux.readableError("error connecting to /private/tmp/tmux-501/x (No such file or directory)"),
                   "tmux isn't running")
  }

  /// Our own messages and anything tmux says that has no shorter form pass through.
  func testReadableErrorKeepsOtherText() {
    XCTAssertEqual(Tmux.readableError("No such folder"), "No such folder")
    XCTAssertEqual(Tmux.readableError("zsh: command not found: tmux"), "zsh: command not found: tmux")
    XCTAssertEqual(Tmux.readableError("session duplicate session: x"), "session duplicate session: x")
  }
}
