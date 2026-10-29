import XCTest
@testable import Term

/// The message rail's reading of a pane: what a refresh prints, where each
/// message starts, jumps and read state. The host is a fake that answers
/// each command kind with recorded output; it can fail.
@MainActor
final class MessageRailTests: XCTestCase {
  private typealias Line = (number: Int, text: String)

  private func message(_ id: String, _ head: String) -> MessageRail.Message {
    MessageRail.Message(id: id, time: Date(timeIntervalSince1970: 1_792_987_200), head: head)
  }

  /// A refresh's output as the host prints it (MessageRail.refreshCommand).
  private func refreshOutput(pane: String = "%5\t1200\t56\t0\ton\t0\t", messages: String, read: String = "", lines: [String] = []) -> Data {
    Data(([pane, messages, read, lines.joined(separator: "\n")].joined(separator: "\n\u{1E}\n") + "\n").utf8)
  }

  private let twoMessages = #"{"v":1,"m":[{"i":"a","t":1792987200,"h":"First answer."},{"i":"b","t":1792987260,"h":"The fix is in."}]}"#

  /// A host that answers refreshes with `refresh` (by call), jumps with `jump`, and records every command;
  /// the first `failedWrites` writes to `@read` fail.
  private final class FakeHost {
    var commands: [String] = []
    var refreshes: [Data?] = []
    var jumps: [Data?] = []
    var fallbackRefresh: Data?
    var failedWrites = 0

    func exec(_ command: String) -> Data? {
      commands.append(command)
      if command.contains("show-options -pqv") { return refreshes.isEmpty ? fallbackRefresh : refreshes.removeFirst() }
      if command.contains("goto-line") { return jumps.isEmpty ? nil : jumps.removeFirst() }
      if command.contains("@read '"), failedWrites > 0 {
        failedWrites -= 1
        return nil
      }
      return Data()
    }

    /// Writes of `id` to `@read`.
    func writes(of id: String) -> Int { commands.count { $0.contains("@read '#{@read} \(id)'") } }
  }

  private func rail(_ host: FakeHost) -> MessageRail {
    MessageRail(tmuxSession: "work") { host.exec($0) }
  }

  // MARK: - Parsing

  // Bug: misreading the pane line (status on top, the copy mode fields) puts every mark and jump rows off.
  func testRefreshReadsThePaneItsMessagesReadIdsAndMatchingLines() throws {
    let output = refreshOutput(pane: "%5\t1200\t56\t2\ton\t1\t40", messages: twoMessages, read: "a x",
                               lines: ["12:First answer. And more", "900: │ The fix is in, tests pass  │"])
    let read = MessageRail.parseRefresh(output)
    XCTAssertEqual(read.pane, MessageRail.Pane(id: "%5", historySize: 1200, height: 56, top: 3, inCopyMode: true, scrollPosition: 40))
    XCTAssertEqual(read.messages.map(\.id), ["a", "b"])
    XCTAssertEqual(read.messages.map(\.head), ["First answer.", "The fix is in."])
    XCTAssertEqual(read.messages.map(\.time), [Date(timeIntervalSince1970: 1_792_987_200), Date(timeIntervalSince1970: 1_792_987_260)])
    XCTAssertEqual(read.read, ["a", "x"])
    XCTAssertEqual(read.lines.map(\.number), [12, 900])
    XCTAssertEqual(read.lines.map(\.text), ["First answer. And more", " │ The fix is in, tests pass  │"])
  }

  // Bug: a session that ended (nothing printed) or a pane without the extension kept showing old marks.
  func testNothingPrintedOrNoListMeansNoPaneOrNoMessages() {
    XCTAssertNil(MessageRail.parseRefresh(Data()).pane)
    let unlisted = MessageRail.parseRefresh(refreshOutput(messages: ""))
    XCTAssertNotNil(unlisted.pane)
    XCTAssertEqual(unlisted.messages, [])
    let malformed = #"{"v":1,"m":[{"i":"a","t":1,"h":""},{"t":2,"h":"no id"},{"i":"c","h":"no time"},{"i":"d","t":3,"h":"kept"}]}"#
    XCTAssertEqual(MessageRail.parseMessages(malformed).map(\.id), ["d"])
    XCTAssertEqual(MessageRail.parseMessages(#"{"v":2,"m":[{"i":"a","t":1,"h":"x"}]}"#), [], "a future format is not guessed at")
  }

  // MARK: - Locating

  // Bug: the same words later in the history (tool output repeating "Done.") moved the newest message there,
  // or a naive per-message "last match" put an older message below a newer one.
  func testNewestTakesTheLastMatchAndEachOlderTheLastAboveTheNewer() {
    let messages = [message("a", "Same head"), message("b", "Other"), message("c", "Done."), message("d", "Done.")]
    let lines: [Line] = [(5, "Same head here"), (8, "Other words"), (12, "Same head again"), (30, "Done."), (44, "Done."), (60, "x Done.")]
    let marks = MessageRail.locate(messages, in: lines)
    XCTAssertEqual(marks.map(\.message.id), ["a", "b", "c", "d"])
    XCTAssertEqual(marks.map(\.line), [5, 8, 44, 60])
  }

  // Bug: one message missing from the history (before a compaction) stopped the older ones from being found.
  func testAMessageNotFoundLeavesTheOthersLocated() {
    let messages = [message("a", "Alpha"), message("b", "Gone"), message("c", "Gamma")]
    let marks = MessageRail.locate(messages, in: [(3, "Alpha"), (9, "Gamma")])
    XCTAssertEqual(marks.map(\.message.id), ["a", "c"])
    XCTAssertEqual(marks.map(\.line), [3, 9])
  }

  // Bug: the callout showed the box omp drew around a question, or the text before the head.
  func testAMarksLineStartsAtItsHeadWithoutABoxBorder() {
    let marks = MessageRail.locate([message("q", "Which build")], in: [(7, "│  Which build should I install?   │")])
    XCTAssertEqual(marks.first?.text, "Which build should I install?")
  }

  // MARK: - Refreshing

  // Bug: a message published since the last refresh was never searched for, so it never got a mark.
  func testNewHeadsAreSearchedForInASecondPass() async {
    let host = FakeHost()
    host.refreshes = [refreshOutput(messages: twoMessages),
                      refreshOutput(messages: twoMessages, lines: ["100:First answer.", "1150:The fix is in."])]
    let rail = rail(host)
    await rail.refreshed()
    XCTAssertEqual(host.commands.count, 2)
    XCTAssertFalse(host.commands.first?.contains("grep") ?? true, "no heads known yet: nothing to search for")
    let second = host.commands.dropFirst().first ?? ""
    XCTAssertTrue(second.contains("\nFirst answer.\nThe fix is in.\nTERM_RAIL_HEADS\n"), second)
    XCTAssertEqual(rail.marks.map(\.line), [100, 1150])
    // Known heads go with the first read next time: one exec.
    host.refreshes = [refreshOutput(messages: twoMessages, lines: ["101:First answer.", "1151:The fix is in."])]
    await rail.refreshed()
    XCTAssertEqual(host.commands.count, 3)
    XCTAssertEqual(rail.marks.map(\.line), [101, 1151])
  }

  // Bug: an empty head is a pattern grep matches on every line, flooding the reply with the whole history.
  func testTheCommandSearchesOnlyRealHeadsOfTheExactSession() {
    let command = MessageRail.refreshCommand(tmuxSession: "it's", heads: ["", "Done.", "TERM_RAIL_HEADS"])
    XCTAssertTrue(command.contains(#"-t '=it'\''s:'"#), command)
    XCTAssertTrue(command.contains("<<'TERM_RAIL_HEADS'\nDone.\nTERM_RAIL_HEADS\n"), command)
    XCTAssertFalse(MessageRail.refreshCommand(tmuxSession: "w", heads: [""]).contains("grep"))
  }

  // Bug: a failed exec (host unreachable) wiped the marks the rail already had.
  func testAFailedRefreshKeepsWhatWasFound() async {
    let host = FakeHost()
    host.refreshes = [refreshOutput(messages: twoMessages), refreshOutput(messages: twoMessages, lines: ["100:First answer."]), nil]
    let rail = rail(host)
    await rail.refreshed()
    XCTAssertEqual(rail.marks.count, 1)
    await rail.refreshed()
    XCTAssertEqual(rail.marks.count, 1)
  }

  // Bug: a new message on a session the user is not looking at ran a capture of its whole history every poll.
  func testTheAgentPollRefreshesOnlyARailOnScreenAndOnlyOnAChange() async throws {
    let host = FakeHost()
    host.fallbackRefresh = refreshOutput(messages: "")
    let rail = rail(host)
    rail.agentChanged(messages: 3, stopped: false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.commands.count, 0)
    rail.isShown = true
    rail.agentChanged(messages: 4, stopped: false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.commands.count, 1)
    rail.agentChanged(messages: 4, stopped: false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.commands.count, 1, "nothing new")
    XCTAssertFalse(rail.agentStopped)
    rail.agentChanged(messages: 4, stopped: true)
    XCTAssertTrue(rail.agentStopped)
  }

  // MARK: - Jumping

  // Bug: the head landed on the wrong row (the formula off by one), or a message already on screen entered copy mode.
  func testAJumpReportsTheRowItsHeadLandsOn() {
    // goto-line N puts line hs − N (0-based) on top: N = hs − L + 2 puts line L on the second row.
    XCTAssertEqual(MessageRail.parseJump(Data("jumped 1200 1189\n".utf8), line: 13), .shown(row: 1, position: 1189))
    XCTAssertEqual(MessageRail.parseJump(Data("jumped 1200 1200\n".utf8), line: 1), .shown(row: 0, position: 1200))
    XCTAssertEqual(MessageRail.parseJump(Data("jumped 1200 0\n".utf8), line: 1210), .shown(row: 9, position: 0))
    XCTAssertEqual(MessageRail.parseJump(Data("stale\n".utf8), line: 13), .stale)
    XCTAssertNil(MessageRail.parseJump(Data("can't find pane\n".utf8), line: 13))
  }

  // Bug: after omp rebuilt the history (a resize) the jump went to wherever the old line number now points.
  func testAStaleLineIsFoundAgainBeforeJumping() async {
    let host = FakeHost()
    host.refreshes = [refreshOutput(messages: twoMessages), refreshOutput(messages: twoMessages, lines: ["100:First answer.", "1150:The fix is in."]),
                      refreshOutput(messages: twoMessages, lines: ["80:First answer.", "1130:The fix is in."])]
    host.jumps = [Data("stale\n".utf8), Data("jumped 1200 1072\n".utf8)]
    let rail = rail(host)
    await rail.refreshed()
    let result = await rail.jump(to: "b")
    let jumps = host.commands.filter { $0.contains("goto-line") }
    XCTAssertEqual(jumps.count, 2)
    let (first, second) = (jumps.first ?? "", jumps.dropFirst().first ?? "")
    XCTAssertTrue(first.contains("l=1150"), first)
    XCTAssertTrue(second.contains("l=1130"), second)
    XCTAssertTrue(second.contains("h='The fix is in.'"), second)
    XCTAssertEqual(result, .shown(row: 1130 - 1 - (1200 - 1072)))
    XCTAssertTrue(rail.pane?.inCopyMode == true)
  }

  // Bug: tapping a mark left it accent until the next refresh, and other devices never heard of it.
  func testATappedMessageIsReadHereAtOnceAndOnTheHost() async throws {
    let host = FakeHost()
    host.refreshes = [refreshOutput(messages: twoMessages), refreshOutput(messages: twoMessages, lines: ["100:First answer.", "1150:The fix is in."])]
    host.jumps = [Data("jumped 1200 52\n".utf8)]
    let rail = rail(host)
    await rail.refreshed()
    XCTAssertFalse(rail.isRead("b"))
    _ = await rail.jump(to: "b")
    XCTAssertTrue(rail.isRead("b"))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(host.commands.contains(Tmux.path + #"; tmux set-option -p -F -t %5 @read '#{@read} b'"#), host.commands.joined(separator: "\n---\n"))
  }

  // Bug: a read the host never received (the write failed) stayed read on this phone only, never sent again.
  func testAReadTheHostMissedIsSentAgainUntilTheHostHoldsIt() async throws {
    let host = FakeHost()
    let lines = ["100:First answer.", "1150:The fix is in."]
    // The first refresh reads twice (its heads are new); the next once, still without b.
    host.refreshes = Array(repeating: refreshOutput(messages: twoMessages, lines: lines), count: 3)
    host.fallbackRefresh = refreshOutput(messages: twoMessages, read: "b", lines: lines)
    host.failedWrites = 1
    let rail = rail(host)
    await rail.refreshed()
    rail.markRead(["b"])
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(host.writes(of: "b"), 1)
    XCTAssertTrue(rail.isRead("b"), "read here at once")
    await rail.refreshed()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(host.writes(of: "b"), 2, "sent again once the host answered")
    await rail.refreshed()
    await rail.refreshed()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(host.writes(of: "b"), 2, "not again once the host holds it")
    XCTAssertTrue(rail.isRead("b"))
  }

  // MARK: - Reading

  // Bug: entering the session marked everything read, or a head that flashed past (scrolling) counted as read.
  func testAHeadOnScreenForASecondIsRead() async throws {
    let host = FakeHost()
    host.refreshes = [refreshOutput(messages: twoMessages, read: "a")]
    let rail = rail(host)
    await rail.refreshed()
    let t0 = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(rail.saw("x The fix is in. y", at: t0), [])
    XCTAssertEqual(rail.saw("nothing", at: t0.addingTimeInterval(0.5)), [], "it left the screen")
    XCTAssertEqual(rail.saw("The fix is in.", at: t0.addingTimeInterval(1)), [])
    XCTAssertEqual(rail.saw("The fix is in.", at: t0.addingTimeInterval(1.9)), [])
    XCTAssertEqual(rail.saw("The fix is in.", at: t0.addingTimeInterval(2)), ["b"])
    XCTAssertTrue(rail.isRead("b"))
    XCTAssertEqual(rail.saw("The fix is in. First answer.", at: t0.addingTimeInterval(5)), [], "read ones are not counted again")
  }

  // Bug: a read set by the Mac (a prompt answers the newest message) was ignored by the phone.
  func testTheHostsReadIdsCount() async {
    let host = FakeHost()
    host.refreshes = [refreshOutput(messages: twoMessages, read: "b")]
    let rail = rail(host)
    await rail.refreshed()
    XCTAssertEqual(rail.unread.map(\.id), ["a"])
  }
}
