import XCTest
@testable import Term

final class TmuxTests: XCTestCase {
  private func parse(_ status: Int32, _ text: String) -> Result<[Tmux.Session], Tmux.ListError> {
    Tmux.parseList(status: status, output: Data(text.utf8))
  }

  private func sessions(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [Tmux.Session] {
    guard case .success(let s) = parse(0, text) else {
      XCTFail("expected sessions from \(text.debugDescription)", file: file, line: line)
      return []
    }
    return s
  }

  private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

  // MARK: - list-sessions output

  /// Captured from tmux 3.x on the Mac: `tmux -L termtest list-sessions` with
  /// four sessions, one of them with two windows. tmux itself rewrites ":" and
  /// "." in names to "_".
  func testRealTmuxOutput() {
    let out = "a_b\t1\t0\t1792908077\nmy work\t2\t0\t1792908077\nx_y\t1\t0\t1792908077\n日本\t1\t0\t1792908077\n"
    let s = sessions(out)
    XCTAssertEqual(Set(s.map(\.name)), ["a_b", "my work", "x_y", "日本"])
    XCTAssertEqual(s.first { $0.name == "my work" }?.windows, 2)
    XCTAssertEqual(s.first { $0.name == "x_y" }?.windows, 1)
    XCTAssertEqual(s.first { $0.name == "日本" }?.attached, 0)
    XCTAssertEqual(s.first?.lastActivity, at(1_792_908_077))
  }

  func testFieldsAreWindowsAttachedAndActivityInThatOrder() {
    let s = sessions("main\t3\t2\t1700000000\n")
    XCTAssertEqual(s, [Tmux.Session(name: "main", windows: 3, attached: 2, lastActivity: at(1_700_000_000))])
  }

  func testNamesWithSpacesAndColonsSurvive() {
    let s = sessions("my work\t1\t0\t10\nhost:8080 api\t2\t1\t20\n")
    XCTAssertEqual(s.map(\.name), ["host:8080 api", "my work"])
  }

  func testMostRecentlyActiveFirst() {
    let s = sessions("old\t1\t0\t100\nnew\t1\t0\t300\nmid\t1\t0\t200\n")
    XCTAssertEqual(s.map(\.name), ["new", "mid", "old"])
  }

  func testEmptyOutputIsNoSessions() {
    XCTAssertEqual(sessions(""), [])
    XCTAssertEqual(sessions("\n\n"), [])
  }

  func testMalformedLinesAreSkippedAndGoodOnesKept() {
    let text = [
      "good\t1\t0\t100",
      "three\t1\t0",
      "five\t1\t0\t100\textra",
      "nan\tx\t0\t100",
      "badattached\t1\t-\t100",
      "baddate\t1\t0\tyesterday",
      "",
      "also good\t2\t1\t50",
    ].joined(separator: "\n")
    XCTAssertEqual(sessions(text).map(\.name), ["good", "also good"])
  }

  func testWindowsLineEndingsAndMissingFinalNewline() {
    XCTAssertEqual(sessions("a\t1\t0\t5\r\nb\t1\t0\t6").map(\.name), ["b", "a"])
  }

  func testEmptySessionNameFieldStillCountsAsAField() {
    // `\t1\t0\t5` has four fields with an empty name; it is not dropped as malformed
    // because tmux never prints it, but it must not shift the other fields.
    XCTAssertEqual(sessions("\t1\t0\t5\n").first?.windows, 1)
  }

  // MARK: - Failures

  func testNoServerRunningMeansNoSessions() {
    let text = "no server running on /private/tmp/tmux-502/termtest\n"
    XCTAssertEqual(try parse(1, text).get(), [])
  }

  func testCannotConnectMeansNoSessions() {
    let text = "error connecting to /tmp/tmux-501/default (No such file or directory)\n"
    XCTAssertEqual(try parse(1, text).get(), [])
  }

  func testFailureWithNoOutputMeansNoSessions() {
    XCTAssertEqual(try parse(1, "").get(), [])
  }

  func testStatus127IsTmuxNotInstalled() {
    XCTAssertEqual(parse(127, "sh: tmux: command not found\n"), .failure(.notInstalled))
    XCTAssertEqual(parse(127, ""), .failure(.notInstalled))
  }

  func testOtherFailuresCarryStatusAndOutput() {
    XCTAssertEqual(parse(1, "protocol version mismatch\n"), .failure(.failed(status: 1, output: "protocol version mismatch\n")))
    XCTAssertEqual(parse(255, "Permission denied\n"), .failure(.failed(status: 255, output: "Permission denied\n")))
  }

  func testSessionsOnStderrNoiseWithNonZeroStatusAreNotTrusted() {
    XCTAssertEqual(parse(2, "a\t1\t0\t5\n"), .failure(.failed(status: 2, output: "a\t1\t0\t5\n")))
  }

  // MARK: - Commands

  func testListCommandAsksForFourTabSeparatedFieldsMatchingTheParser() {
    XCTAssertEqual(
      Tmux.listCommand,
      "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}'")
    let format = Tmux.listCommand.split(separator: "'")[1]
    XCTAssertEqual(format.split(separator: "\t", omittingEmptySubsequences: false).count, 4)
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
}
