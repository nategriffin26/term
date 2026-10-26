import XCTest
@testable import Term

/// A tab outside tmux has no server-side history: its own terminal is the
/// source, so the buffer must come out whole and replay the same.
@MainActor
final class SessionHistoryTests: XCTestCase {
  func testHistoryIsScrollbackAndScreenWithColors() throws {
    let session = try XCTUnwrap(Session(localCols: 20, rows: 3))
    session.feed(Data("\u{1b}[31mred\u{1b}[0m one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
    let history = String(decoding: session.history(), as: UTF8.self)
    for word in ["red", "one", "two", "three", "four", "five"] {
      XCTAssertTrue(history.contains(word), "\(word) missing from \(history.debugDescription)")
    }
    XCTAssertTrue(history.contains("\u{1b}["), "colors kept")
  }

  func testHistoryReplaysToTheSameText() throws {
    let session = try XCTUnwrap(Session(localCols: 20, rows: 3))
    session.feed(Data("\u{1b}[1mone\u{1b}[0m\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
    let copy = try XCTUnwrap(Session(localCols: 20, rows: 8))
    copy.feed(HistoryViewController.terminalBytes(session.history()))
    XCTAssertEqual(copy.text(fromCol: 0, row: 0, toCol: 19, row: 4), "one\ntwo\nthree\nfour\nfive")
  }
}
