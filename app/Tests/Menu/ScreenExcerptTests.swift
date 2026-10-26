import XCTest
@testable import Term

/// A tmux row's excerpt, read off a real terminal (the core's VT) fed the
/// bytes a session would print.
@MainActor
final class ScreenExcerptTests: XCTestCase {
  private func excerpt(_ bytes: String, cols: Int = 40, rows: Int = 8, count: Int = 2) throws -> ScreenExcerpt {
    let session = try XCTUnwrap(Session(localCols: cols, rows: rows))
    session.feed(bytes)
    return ScreenExcerpt(session, count: count)
  }

  private func texts(_ excerpt: ScreenExcerpt) -> [String] {
    excerpt.lines.map { $0.map(\.text).joined() }
  }

  /// Bug it catches: the excerpt shows the top of the screen (long scrolled
  /// past) or pads lines with the row's trailing blanks, instead of the
  /// latest output and the prompt under it.
  func testShowsTheLastLinesUpToTheCursor() throws {
    XCTAssertEqual(texts(try excerpt("one\r\ntwo\r\nthree\r\ne2e api % ")), ["three", "e2e api %"])
    XCTAssertEqual(texts(try excerpt("GET /a\r\nGET /b\r\nGET /c\r\n")), ["GET /b", "GET /c"])
  }

  /// Bug it catches: blank lines, rules, box edges, vim's "~", line numbers
  /// and a bare prompt take the excerpt's two lines, so the row says nothing.
  func testSkipsLinesWithoutWords() throws {
    let screen = "compiling\r\nbuild ok\r\n\r\n────────\r\n~\r\n  42\r\n$ "
    XCTAssertEqual(texts(try excerpt(screen)), ["compiling", "build ok"])
    XCTAssertEqual(texts(try excerpt("\r\n~\r\n$ ")), [])
  }

  /// Bug it catches: an editor on its first line (the cursor at the top)
  /// shows that one line and nothing under it.
  func testTopsUpFromBelowWhenTheCursorIsNearTheTop() throws {
    XCTAssertEqual(texts(try excerpt("# Week\r\n\r\n- ship\r\n- tile\r\n\u{1B}[1;1H")), ["# Week", "- ship"])
  }

  /// Bug it catches: lines left below the cursor (an old screen's rest)
  /// crowd out the prompt line the cursor is on.
  func testLinesBelowTheCursorWaitWhileEnoughSitAbove() throws {
    XCTAssertEqual(texts(try excerpt("alpha\r\nbeta\r\ngamma\r\ndelta\u{1B}[2;1H")), ["alpha", "beta"])
  }

  /// Boundaries of the row choice: no rows, no lines wanted, a cursor off
  /// the screen either way, exactly enough above, one short, none at all.
  func testRowChoiceAtItsBoundaries() {
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [], cursor: 0, count: 2), [])
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [true, true], cursor: 1, count: 0), [])
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [true, true, true], cursor: -3, count: 2), [0, 1])
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [true, false, true, true], cursor: 9, count: 2), [2, 3])
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [true, true, false, true], cursor: 1, count: 2), [0, 1])
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [false, true, false, true], cursor: 1, count: 2), [1, 3])
    XCTAssertEqual(ScreenExcerpt.rows(withWords: [false, false, false], cursor: 1, count: 2), [])
  }

  /// Bug it catches: the terminal's colours are lost (a build's green
  /// "Finished" reads like any line), or default text keeps the terminal's
  /// own foreground instead of the row's ink.
  func testKeepsColoursAndLeavesDefaultTextToTheRow() throws {
    let runs = try XCTUnwrap(try excerpt("\u{1B}[32mGET\u{1B}[0m /v1 \u{1B}[36m200\u{1B}[0m").lines.first)
    XCTAssertEqual(runs.map(\.text), ["GET", " /v1 ", "200"])
    XCTAssertNotNil(runs[0].fg)
    XCTAssertNil(runs[1].fg)
    XCTAssertNotNil(runs[2].fg)
    XCTAssertNotEqual(runs[0].fg, runs[2].fg)
    XCTAssertEqual(runs.map(\.bg), [nil, nil, nil])
  }

  /// Bug it catches: reverse video (vim's and tmux's status lines) is drawn
  /// in the terminal's background colour on the row, which is invisible.
  func testReverseVideoKeepsItsBackground() throws {
    let runs = try XCTUnwrap(try excerpt("\u{1B}[7mNORMAL\u{1B}[0m notes.md").lines.first)
    XCTAssertEqual(runs.first?.text, "NORMAL")
    XCTAssertNotNil(runs.first?.bg)
    XCTAssertNil(runs.last?.bg)
  }

  /// Bug it catches: indent every line shares eats the row's width, or
  /// dropping it loses how lines line up with each other.
  func testDropsTheIndentEveryLineSharesOnly() throws {
    XCTAssertEqual(texts(try excerpt("      Finished dev\r\n  e2e %")), ["    Finished dev", "e2e %"])
  }

  /// Bug it catches: the right half of a wide character comes out as a
  /// space, so CJK text reads "日 本".
  func testWideCharactersShowOnce() throws {
    XCTAssertEqual(texts(try excerpt("日本語 ok")), ["日本語 ok"])
  }

  /// Bug it catches: bold text loses its weight.
  func testBoldIsKept() throws {
    let runs = try XCTUnwrap(try excerpt("\u{1B}[1mwarning\u{1B}[0m: unused").lines.first)
    XCTAssertEqual(runs.map(\.bold), [true, false])
  }
}
