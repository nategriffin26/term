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
                   [.init(top: 0, bottom: 2, hash: "flow"), .init(top: 7, bottom: 35, hash: "seq")])
  }

  /// No source published: every drawing stays ASCII.
  func testNoSourcesNoMatch() throws {
    XCTAssertEqual(DiagramMatcher.match(try rows("cap-120"), []), [])
  }

  /// An edge label on its own row is bridged; a third plain row or a blank row ends the block.
  func testBlocksBridgeUpToTwoPlainRows() {
    let rows = ["┌─┐", "label", "more", "└─┘", "", "│", "a", "b", "c", "│"]
    XCTAssertEqual(DiagramMatcher.blocks(rows).map { [$0.top, $0.bottom, $0.glyphRows] },
                   [[0, 3, 2], [5, 5, 1], [9, 9, 1]])
  }

  func testWordsArePrefixesCutAtThePaneEdge() {
    XCTAssertEqual(DiagramMatcher.words("│ ASCII dia  show-options @diagrams. x 5.5"), ["ascii", "dia", "show-options", "diagrams", "5.5"])
    XCTAssertEqual(DiagramMatcher.source(of: ["ascii", "dia", "attach", "scre", "sources"], in: sources), "seq")
  }

  /// Under 80% of a block's words in a source: not that source.
  func testPrecisionBar() {
    let four = ["phone", "tmux", "sources", "zebra", "yak"]
    XCTAssertNil(DiagramMatcher.source(of: four, in: sources))
    XCTAssertEqual(DiagramMatcher.source(of: Array(four.prefix(4)) + ["phone"], in: sources), "seq")
  }

  /// Same words in two sources: the one that covers more of its own words, then the newer.
  func testTiesGoToRecallThenNewest() {
    let a = DiagramMatcher.Candidate(hash: "a", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")
    let b = DiagramMatcher.Candidate(hash: "b", time: 2, source: "flowchart TD\n A[alpha] --> B[beta]")
    let wide = DiagramMatcher.Candidate(hash: "wide", time: 3, source: "flowchart TD\n A[alpha] --> B[beta] --> C[gamma] --> D[delta]")
    XCTAssertEqual(DiagramMatcher.source(of: ["alpha", "beta"], in: [a, b]), "b")
    XCTAssertEqual(DiagramMatcher.source(of: ["alpha", "beta"], in: [a, wide]), "a")
  }
}

/// Sticky placement (design §3): 45 rows, 51 columns of 7.5 × 17 pt.
final class DiagramPlacementTests: XCTestCase {
  let cell = CGSize(width: 7.5, height: 17)

  func place(top: Int, bottom: Int, height: CGFloat, width: CGFloat = 300) -> DiagramPlacement? {
    DiagramPlacement.place(top: top, bottom: bottom, rows: 45, cols: 51, cell: cell, size: CGSize(width: width, height: height))
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

  /// Scrolling off the top: pinned while the rest of the block is taller than
  /// the image (−1, equal), then it leaves with the block's last row (+1).
  func testScrollingOutLeavesWithTheLastRow() throws {
    let region: CGFloat = 10 * 17
    XCTAssertEqual(try XCTUnwrap(place(top: 0, bottom: 9, height: region - 1)).image.minY, 0)
    XCTAssertEqual(try XCTUnwrap(place(top: 0, bottom: 9, height: region)).image.minY, 0)
    XCTAssertEqual(try XCTUnwrap(place(top: 0, bottom: 9, height: region + 1)).image.minY, -1)
  }

  /// A whole block on screen shrinks its diagram to fit, down to 0.75, then clips.
  func testWholeBlockFitsDownToTheFloor() throws {
    let region: CGFloat = 10 * 17
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region)).image.height, region)
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region + 1)).image.height, region, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(place(top: 5, bottom: 14, height: region * 2)).image.height, region * 2 * 0.75, accuracy: 0.001)
  }

  /// Wider than 49 columns: scaled to fit the width.
  func testWideDiagramFitsTheWidth() throws {
    let p = try XCTUnwrap(place(top: 5, bottom: 40, height: 100, width: 735))
    XCTAssertEqual(p.image.width, 367.5, accuracy: 0.001)
    XCTAssertEqual(p.image.minX, 7.5, accuracy: 0.001)
  }
}
