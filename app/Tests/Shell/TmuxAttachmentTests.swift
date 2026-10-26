import XCTest
@testable import Term

final class TmuxAttachmentTests: XCTestCase {
  func testAncestrySelectsOnlyThisTabsClient() {
    let output = "91\tother\n42\tmy work\n\u{1e}\n10 1\n20 10\n42 20\n91 90\n"
    XCTAssertEqual(TmuxAttachment.parse(output, root: 10), .attached("my work"))
    XCTAssertEqual(TmuxAttachment.parse(output, root: 90), .unavailable)
  }

  func testDetachedShellDoesNotKeepAnotherClientsSession() {
    XCTAssertEqual(TmuxAttachment.parse("91\tother\n\u{1e}\n10 1\n20 10\n", root: 10), .detached)
    XCTAssertEqual(TmuxAttachment.parse("\u{1e}\n10 1\n", root: 10), .detached)
  }

  func testMissingRootAndMalformedSnapshotAreNotDetachObservations() {
    XCTAssertEqual(TmuxAttachment.parse("42\twork\n\u{1e}\n42 20\n", root: 10), .unavailable)
    XCTAssertEqual(TmuxAttachment.parse("permission denied", root: 10), .unavailable)
    XCTAssertEqual(TmuxAttachment.parse("42\twork\n\u{1e}\n10 1\n42 43\n43 42\n", root: 10), .detached)
  }

  func testClientCanReplaceTheRootProcessAndNamesRemainLiteral() {
    XCTAssertEqual(TmuxAttachment.parse("10\tit's café\twork\n\u{1e}\n10 1\n", root: 10), .attached("it's café\twork"))
  }

  func testManualReconnectAttachesExactlyAndReturnsToLoginShell() {
    XCTAssertEqual(TmuxAttachment.reconnectCommand(startup: nil, session: "my work"),
                   Tmux.path + "; tmux attach -t '=my work'; exec \"$SHELL\" -l")
    XCTAssertEqual(TmuxAttachment.reconnectCommand(startup: nil, session: "it's"),
                   Tmux.path + "; tmux attach -t '=it'\\''s'; exec \"$SHELL\" -l")
    XCTAssertNil(TmuxAttachment.reconnectCommand(startup: nil, session: nil))
  }

  func testConfiguredAttachRemainsAttachOnlyAndNeverCreatesMissingSession() {
    XCTAssertEqual(TmuxAttachment.reconnectCommand(startup: Tmux.attachCommand("work"), session: "work"),
                   "tmux attach -t '=work'")
    XCTAssertEqual(TmuxAttachment.reconnectCommand(startup: "exec htop", session: nil), "exec htop")
  }
}
