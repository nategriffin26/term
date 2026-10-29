import XCTest
@testable import Term

/// `ask_answered` counts only an answer seen to happen: unmodified Return in
/// the pane that waits, then that pane's stop over at the next probe.
final class AnswerWatchTests: XCTestCase {
  private let asking = ShownAgent(pane: "%3", state: .ask, stop: 1793241830.5)

  func testReturnThenTheStopEndingCounts() {
    var watch = AnswerWatch()
    XCTAssertFalse(watch.observe(asking))
    watch.submitted()
    XCTAssertTrue(watch.observe(ShownAgent(pane: "%3", state: .working, stop: nil)))
    XCTAssertFalse(watch.observe(ShownAgent(pane: "%3", state: .working, stop: nil)), "counted once")
  }

  // Bug: Return was counted as an answer the moment it was typed, though nothing changed.
  func testNoTransitionNoAnswer() {
    var watch = AnswerWatch()
    _ = watch.observe(asking)
    watch.submitted()
    XCTAssertFalse(watch.observe(asking))
    XCTAssertFalse(watch.observe(asking))
    XCTAssertTrue(watch.observe(ShownAgent(pane: "%3", state: .done, stop: 1793241900)))
  }

  func testAnsweredThenAskedAgainCounts() {
    var watch = AnswerWatch()
    _ = watch.observe(asking)
    watch.submitted()
    XCTAssertTrue(watch.observe(ShownAgent(pane: "%3", state: .approval, stop: 1793241840)))
  }

  // Bug: the session's most urgent agent stood for every pane, so Return in a
  // working pane counted when another pane in the session was asking.
  func testAnotherPanesAskIsNotThisAnswer() {
    var watch = AnswerWatch()
    _ = watch.observe(ShownAgent(pane: "%4", state: .working, stop: nil))
    watch.submitted()
    XCTAssertFalse(watch.observe(ShownAgent(pane: "%4", state: .idle, stop: nil)))

    _ = watch.observe(asking)
    watch.submitted()
    XCTAssertFalse(watch.observe(ShownAgent(pane: "%5", state: .working, stop: nil)), "switched panes")
    XCTAssertFalse(watch.observe(ShownAgent(pane: "%3", state: .working, stop: nil)), "the watch ended with the switch")
  }

  // Seeing, opening or clearing a stop is no answer.
  func testAStopEndingWithoutReturnDoesNotCount() {
    var watch = AnswerWatch()
    _ = watch.observe(asking)
    XCTAssertFalse(watch.observe(ShownAgent(pane: "%3", state: .working, stop: nil)))
  }

  func testAnAgentGoneFromThePaneIsNoAnswer() {
    var watch = AnswerWatch()
    _ = watch.observe(asking)
    watch.submitted()
    XCTAssertFalse(watch.observe(ShownAgent(pane: "%3", state: nil, stop: nil)))
    XCTAssertFalse(watch.observe(nil))
  }

  func testShownAgentReadsOnlyThisTabsClient() {
    let output = "91\tother\n42\twork\n\u{1e}\nR\t10\tmosh-server\n10 1\n20 10\n42 20\n91 90\n\u{1d}\n"
      + "91\t%7\t{\"state\":\"ask\",\"stop\":{\"at\":5}}\n"
      + "42\t%3\t{\"state\":\"approval\",\"q\":\"Run it? yes\\tno\",\"stop\":{\"at\":1793241830.5}}\n"
    XCTAssertEqual(TmuxAttachment.shownAgent(output, root: 10), ShownAgent(pane: "%3", state: .approval, stop: 1793241830.5))
    XCTAssertEqual(TmuxAttachment.parse(output, root: 10), .attached("work"), "the new section leaves attachment as it was")
    XCTAssertNil(TmuxAttachment.shownAgent(output, root: 90))
  }

  func testPaneWithoutAgentAndOldProbes() {
    let base = "42\twork\n\u{1e}\nR\t10\tsshd\n10 1\n42 10\n"
    XCTAssertEqual(TmuxAttachment.shownAgent(base + "\u{1d}\n42\t%3\t\n", root: 10), ShownAgent(pane: "%3", state: nil, stop: nil))
    XCTAssertNil(TmuxAttachment.shownAgent(base, root: 10), "a probe without the section")
  }

  // Bug: Shift-Return (a new line in omp's editor) armed the watch like a submit.
  @MainActor
  func testOnlyUnmodifiedReturnSubmits() throws {
    let view = TerminalView(session: try XCTUnwrap(Session(localCols: 20, rows: 5)))
    var submits = 0
    view.onSubmit = { submits += 1 }
    view.send(TERM_KEY_ENTER, mods: UInt32(TERM_MOD_SHIFT))
    view.send(TERM_KEY_ENTER, mods: UInt32(TERM_MOD_ALT))
    view.send(TERM_KEY_TAB)
    XCTAssertEqual(submits, 0)
    view.send(TERM_KEY_ENTER)
    XCTAssertEqual(submits, 1)
  }
}
