import XCTest
@testable import Term

/// Screens captured from omp 18.12.6 in tmux (Fixtures/), and the two sources it drew.
final class DiagramMatcherTests: XCTestCase {
  static let flow = """
    flowchart TD
      A[Phone: Term] -->|mosh| B[mosh-server]
      B --> C[tmux pane]
      C --> D{omp prints mermaid?}
      D -->|yes| E[ASCII in grid]
      D -->|no| F[Plain text]
      E --> G[Term overlays diagram]
    """
  static let seq = """
    sequenceDiagram
      participant P as Phone
      participant T as tmux
      participant O as omp
      P->>T: attach (mosh)
      O->>T: ASCII diagram
      O-->>T: @diagrams {hash, src}
      T->>P: screen diff
      P->>T: show-options @diagrams
      T-->>P: sources
      Note over P: render with Pele
    """
  let sources = [
    DiagramMatcher.Candidate(hash: "flow", time: 1, source: flow),
    DiagramMatcher.Candidate(hash: "seq", time: 2, source: seq),
  ]

  func rows(_ name: String) throws -> [String] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
  }

  func testSharedParticipantNamesCannotIdentifyAnUnseenPartialDiagram() {
    let partial = ["▌ unrelated status", "┌───────┐   ┌──────┐   ┌─────┐",
                   "│ Phone │   │ tmux │   │ omp │", "└───────┘   └──────┘   └─────┘", "", "following prose"]
    XCTAssertEqual(DiagramMatcher.match(partial, sources), [],
                   "A partial sequence suffix must not briefly show the flowchart just because its vocabulary is smaller")
  }

  /// Finds both drawings whole at 120 columns, and nothing in omp's banner or composer.
  func testWideScreenMatchesBothDrawingsAndNoChrome() throws {
    XCTAssertEqual(DiagramMatcher.match(try rows("cap-120"), sources),
                   [.init(top: 32, bottom: 86, hash: "flow"), .init(top: 90, bottom: 118, hash: "seq")])
  }

  /// At 51 columns omp clips the sequence diagram's third lane and its labels mid-word.
  func testClippedPhoneWidthStillMatches() throws {
    XCTAssertEqual(DiagramMatcher.match(try rows("cap-51"), sources),
                   [.init(top: 35, bottom: 89, hash: "flow"), .init(top: 94, bottom: 122, hash: "seq")])
  }

  /// The live screen: only the flowchart's last three rows are left at the top.
  func testLiveScreenCatchesThePartialDrawingAtTheTop() throws {
    XCTAssertEqual(DiagramMatcher.match(try rows("screen-51"), sources),
                   [.init(top: 0, bottom: 2, hash: "flow", openTop: true), .init(top: 7, bottom: 35, hash: "seq")])
  }

  /// Seen live on the iPhone: tmux's status line sat right on a flowchart
  /// that ran off the top, its words (clock, battery) sank the block under
  /// the precision bar, and the flowchart stayed ASCII. The status row is not
  /// part of the drawing, and the drawing goes on behind it.
  func testStatusLineOnTopOfADrawingIsLeftOut() throws {
    let signIn = DiagramMatcher.Candidate(hash: "signin", time: 3, source: """
      flowchart TD
          A[Enter password] --> B{Password valid?}
          B -- No --> C[Show error]
          B -- Yes --> D{2FA enabled?}
          D -- No --> E[Sign in]
          D -- Yes --> F[Enter code]
          F --> G{Code valid?}
          G -- Yes --> E
          G -- No --> C
      """)
    XCTAssertEqual(DiagramMatcher.match(try rows("status-51"), sources + [signIn]),
                   [.init(top: 1, bottom: 33, hash: "signin", openTop: true)])
  }

  /// At most two foreign rows come off an edge: past that, it is not the drawing.
  func testAtMostTwoRowsTrimmedAtAnEdge() {
    let ab = DiagramMatcher.Candidate(hash: "ab", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")
    let box = ["┌───────┐", "│ alpha │", "└───┬───┘", "    ▼", "┌───────┐", "│ beta  │", "└───────┘"]
    let chrome = "▌zebra yak ◉ 12% ▬ 00:41"
    XCTAssertEqual(DiagramMatcher.match([chrome, chrome] + box + [chrome, chrome], [ab]),
                   [.init(top: 2, bottom: 8, hash: "ab", openTop: true, openBottom: true)])
    XCTAssertEqual(DiagramMatcher.match([chrome, chrome, chrome] + box, [ab]), [])
  }

  /// omp's composer, two rules around the prompt, is never a drawing, even
  /// when its title is all words of a source.
  func testComposerIsNotADrawing() {
    let composer = ["", "─── alpha beta ───", "❯ ", "──────────────", ""]
    let ab = DiagramMatcher.Candidate(hash: "ab", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")
    XCTAssertEqual(DiagramMatcher.match(composer, [ab]), [])
  }

  /// No source published: every drawing stays ASCII.
  func testNoSourcesNoMatch() throws {
    XCTAssertEqual(DiagramMatcher.match(try rows("cap-120"), []), [])
  }

  /// On a page (tmux history), a drawing at the first or last row is whole.
  func testPageDrawingsAreNeverOpen() throws {
    let rows = try rows("cap-120")
    let flow = try XCTUnwrap(DiagramMatcher.match(Array(rows[32...86]), sources, screen: false).first)
    XCTAssertEqual(flow, .init(top: 0, bottom: 54, hash: "flow"))
    XCTAssertEqual(DiagramMatcher.match(Array(rows[32...86]), sources).first?.openTop, true)
  }

  static let pie = "pie title Pets adopted\n  \"Dogs\" : 386\n  \"Cats\" : 85\n  \"Rats\" : 15"

  /// omp prints types its ASCII renderer lacks as source between fences.
  func testSourceTextBlockMatchesFromFenceToFence() {
    let rows = ["Here are the pets:", "", "```mermaid", "pie title Pets adopted", "  \"Dogs\" : 386",
                "  \"Cats\" : 85", "  \"Rats\" : 15", "```", "", "Dogs win."]
    let pie = DiagramMatcher.Candidate(hash: "pie", time: 3, source: Self.pie)
    XCTAssertEqual(DiagramMatcher.match(rows, sources + [pie]), [.init(top: 2, bottom: 7, hash: "pie", isText: true)])
    XCTAssertEqual(DiagramMatcher.match(rows, sources), [])
  }

  /// Unclosed at the screen's bottom: it may go on below. A plain code block is not one.
  func testSourceTextBlockOpenAtTheBottomAndOtherFences() {
    let pie = DiagramMatcher.Candidate(hash: "pie", time: 3, source: Self.pie)
    XCTAssertEqual(DiagramMatcher.match(["x", "```mermaid", "pie title Pets adopted", "  \"Dogs\" : 386"], [pie]),
                   [.init(top: 1, bottom: 3, hash: "pie", openBottom: true, isText: true)])
    XCTAssertEqual(DiagramMatcher.match(["```", "pie title Pets adopted", "  \"Dogs\" : 386", "```"], [pie]), [])
    XCTAssertEqual(DiagramMatcher.match(["x", "```mermaid"], [pie]), [])
  }

  /// An edge label on its own row is bridged; a third plain row or a blank row ends the block.
  func testBlocksBridgeUpToTwoPlainRows() {
    let rows = ["┌─┐", "label", "more", "└─┘", "", "│", "a", "b", "c", "│"]
    XCTAssertEqual(DiagramMatcher.blocks(rows).map { [$0.top, $0.bottom, $0.glyphRows] },
                   [[0, 3, 2], [5, 5, 1], [9, 9, 1]])
  }

  func source(_ seen: [String], in candidates: [DiagramMatcher.Candidate]) -> String? {
    DiagramMatcher.drawn([seen.joined(separator: " ")], in: candidates)?.hash
  }

  func testWordsArePrefixesCutAtThePaneEdge() {
    XCTAssertEqual(DiagramMatcher.words("│ ASCII dia  show-options @diagrams. x 5.5"), ["ascii", "dia", "show-options", "diagrams", "5.5"])
    XCTAssertEqual(source(["ascii", "dia", "attach", "scre", "sources"], in: sources), "seq")
  }

  /// Under 80% of a block's words in a source: not that source.
  func testPrecisionBar() {
    let four = ["phone", "tmux", "sources", "zebra", "yak"]
    XCTAssertNil(source(four, in: sources))
    XCTAssertEqual(source(Array(four.prefix(4)) + ["phone"], in: sources), "seq")
  }

  /// Same words in two sources: the one that covers more of its own words, then the newer.
  func testTiesGoToRecallThenNewest() {
    let a = DiagramMatcher.Candidate(hash: "a", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")
    let b = DiagramMatcher.Candidate(hash: "b", time: 2, source: "flowchart TD\n A[alpha] --> B[beta]")
    let wide = DiagramMatcher.Candidate(hash: "wide", time: 3, source: "flowchart TD\n A[alpha] --> B[beta] --> C[gamma] --> D[delta]")
    XCTAssertEqual(source(["alpha", "beta"], in: [a, b]), "b")
    XCTAssertEqual(source(["alpha", "beta"], in: [a, wide]), "a")
  }
}

/// Retained slice placement: 45 rows, 51 columns of 7.5 × 17 pt.
final class DiagramPlacementTests: XCTestCase {
  let cell = CGSize(width: 7.5, height: 17)

  /// A drawing at row 0 may go on above the screen, one at row 44 below it.
  func place(top: Int, bottom: Int, height: CGFloat, width: CGFloat = 300) -> DiagramPlacement? {
    DiagramPlacement.place(.init(top: top, bottom: bottom, hash: "", openTop: top == 0, openBottom: bottom == 44),
                           cols: 51, rows: 45, cell: cell, size: CGSize(width: width, height: height))
  }

  /// On a page every drawing is whole: the part on screen is the tile, the
  /// image keeps its place at the drawing's first row, off screen or not.
  func page(top: Int, bottom: Int, height: CGFloat) -> DiagramPlacement? {
    DiagramPlacement.place(.init(top: top, bottom: bottom, hash: ""), cols: 51, rows: 45, cell: cell,
                           size: CGSize(width: 300, height: height))
  }

  func testPageDrawingAboveTheScreenMovesWithItsText() throws {
    let p = try XCTUnwrap(page(top: -3, bottom: 10, height: 200))
    XCTAssertEqual(p.tile, CGRect(x: 0, y: 0, width: 382.5, height: 11 * 17))
    XCTAssertEqual(p.image.minY, -51)
    XCTAssertEqual(p.image.height, 200)
  }

  /// Fitted to the whole drawing (14 rows), not to the 11 on screen.
  func testPageDrawingFitsItsWholeBlock() throws {
    let p = try XCTUnwrap(page(top: -3, bottom: 10, height: 14 * 17 + 10))
    XCTAssertEqual(p.image.height, 14 * 17, accuracy: 0.001)
  }

  func testPageDrawingBelowTheScreenEndsAtTheLastRow() throws {
    let p = try XCTUnwrap(page(top: 40, bottom: 60, height: 100))
    XCTAssertEqual(p.tile, CGRect(x: 0, y: 40 * 17, width: 382.5, height: 5 * 17))
    XCTAssertEqual(p.image.minY, 0)
  }

  /// One row on screen at either edge still shows; none does not.
  func testPageDrawingAtTheEdges() {
    XCTAssertEqual(page(top: -5, bottom: 0, height: 100)?.tile.height, 17)
    XCTAssertNil(page(top: -5, bottom: -1, height: 100))
    XCTAssertEqual(page(top: 44, bottom: 50, height: 100)?.tile.minY, 44 * 17)
    XCTAssertNil(page(top: 45, bottom: 50, height: 100))
  }

  func testTileCoversExactlyTheVisibleRowsAndImageIsCentered() throws {
    let p = try XCTUnwrap(place(top: 5, bottom: 20, height: 100))
    XCTAssertEqual(p.tile, CGRect(x: 0, y: 85, width: 382.5, height: 272))
    XCTAssertEqual(p.image, CGRect(x: 41.25, y: 0, width: 300, height: 100))
  }

  /// Block top at row 1: aligned to it. At row 0 (it may run on above): pinned at the top.
  func testBlockTopAtRowOneAndZero() throws {
    XCTAssertEqual(try XCTUnwrap(place(top: 1, bottom: 44, height: 100)).image.minY, 0)
    XCTAssertEqual(try XCTUnwrap(place(top: 1, bottom: 44, height: 100)).tile.minY, 17)
    XCTAssertEqual(try XCTUnwrap(place(top: 0, bottom: 44, height: 2000)).image.minY, 0)
  }

  func testUnseenTopStaysBottomAnchoredWhenScrollingUpOneRow() throws {
    var state = DiagramScrollState()
    let rows = (0..<30).map { "drawing row \($0)" }
    state.update(rows)
    state.merge([.init(top: 0, bottom: 5, hash: "cold", openTop: true)], origin: state.origin, epoch: state.epoch)
    let first = try XCTUnwrap(DiagramPlacement.place(try XCTUnwrap(state.visible.first),
      cols: 51, rows: 30, cell: cell, size: CGSize(width: 300, height: 300)))
    XCTAssertEqual(first.image.minY, -198)
    state.update(["earlier row"] + Array(rows.prefix(29)))
    state.merge([.init(top: 0, bottom: 6, hash: "cold", openTop: true)], origin: state.origin, epoch: state.epoch)
    let match = try XCTUnwrap(state.visible.first)
    XCTAssertTrue(match.openTop, "A partial rematch has not discovered the drawing's real top")
    let next = try XCTUnwrap(DiagramPlacement.place(match,
      cols: 51, rows: 30, cell: cell, size: CGSize(width: 300, height: 300)))
    XCTAssertEqual(next.image.minY, -181)
    XCTAssertEqual(next.tile.minY + next.image.minY - first.tile.minY - first.image.minY, 17)
  }

  /// Once its real top is known, an offscreen drawing keeps that origin.
  func testKnownDrawingUsesItsRetainedOriginAtEveryImageHeight() throws {
    for height: CGFloat in [169, 170, 171] {
      let match = DiagramMatcher.Match(top: -3, bottom: 9, hash: "", openTop: false)
      let p = try XCTUnwrap(DiagramPlacement.place(match, cols: 51, rows: 45, cell: cell,
                                                  size: CGSize(width: 300, height: height)))
      XCTAssertEqual(p.image.minY, -51)
      XCTAssertEqual(p.image.height, height)
    }
  }

  /// A whole block on screen shrinks its diagram to fit, down to 0.75, then clips.
  func testWholeBlockFitsDownToTheFloor() throws {
    let region: CGFloat = 10 * 17
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region)).image.height, region)
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region + 1)).image.height, region, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region * 2)).image.height, region * 2 * 0.75, accuracy: 0.001)
  }

  /// Source text has no natural height, so a diagram taller than its rows is
  /// fitted whole (a pie in 7 rows was clipped to a half pie); an ASCII drawing
  /// keeps the floor.
  func testSourceTextBlockFitsWholeBelowTheFloor() throws {
    let region: CGFloat = 8 * 17
    let text = DiagramMatcher.Match(top: 5, bottom: 12, hash: "", isText: true)
    let p = try XCTUnwrap(DiagramPlacement.place(text, cols: 51, rows: 45, cell: cell, size: CGSize(width: 300, height: region * 3)))
    XCTAssertEqual(p.image.height, region, accuracy: 0.001)
    XCTAssertEqual(p.image.width, 100, accuracy: 0.001)
    XCTAssertFalse(p.clipsBottom)
  }

  /// Clipped past the floor, with the drawing's last row on screen: fade. Whole,
  /// still streaming, or last row below the screen: no fade.
  func testClippedBlockFadesAtItsLastRowOnly() throws {
    let region: CGFloat = 10 * 17
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region * 2)).clipsBottom, true)
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region)).clipsBottom, false)
    XCTAssertEqual(try XCTUnwrap(place(top: 30, bottom: 44, height: 2000)).clipsBottom, false)
    XCTAssertEqual(try XCTUnwrap(page(top: 40, bottom: 60, height: 2000)).clipsBottom, false)
    XCTAssertEqual(try XCTUnwrap(page(top: 30, bottom: 40, height: 2000)).clipsBottom, true)
  }

  /// Wider than 49 columns: scaled to fit the width.
  func testWideDiagramFitsTheWidth() throws {
    let p = try XCTUnwrap(place(top: 5, bottom: 40, height: 100, width: 735))
    XCTAssertEqual(p.image.width, 367.5, accuracy: 0.001)
    XCTAssertEqual(p.image.minX, 7.5, accuracy: 0.001)
  }
}
