import XCTest
@testable import Term

/// A selection that crosses drawn diagrams copies each one's Mermaid source,
/// fenced, once, in place of its drawing's rows; the rest is the grid's text.
final class DiagramCopyTests: XCTestCase {
  let flow = DiagramOverlay.Drawing(top: 10, bottom: 20, hash: "f", source: "flowchart TD\n  A --> B")
  let seq = DiagramOverlay.Drawing(top: 30, bottom: 35, hash: "s", source: "sequenceDiagram\n  A->>B: hi")
  let fencedFlow = "```mermaid\nflowchart TD\n  A --> B\n```"
  let fencedSeq = "```mermaid\nsequenceDiagram\n  A->>B: hi\n```"

  /// The grid's text between two cells, as "[row:col-row:col]".
  func copy(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int, _ drawings: [DiagramOverlay.Drawing]) -> String {
    DiagramCopy.text(from: GridPoint(row: r0, col: c0), to: GridPoint(row: r1, col: c1), cols: 51, drawings: drawings) { a, b in
      "[\(a.row):\(a.col)-\(b.row):\(b.col)]"
    }
  }

  func testNoDiagramIsPlainText() {
    XCTAssertEqual(copy(5, 3, 25, 4, []), "[5:3-25:4]")
    XCTAssertEqual(copy(21, 0, 29, 50, [flow, seq]), "[21:0-29:50]")
  }

  func testAcrossADiagram() {
    XCTAssertEqual(copy(5, 3, 25, 4, [flow]), "[5:3-9:50]\n\(fencedFlow)\n[21:0-25:4]")
  }

  func testStartingOrEndingInside() {
    XCTAssertEqual(copy(15, 7, 25, 4, [flow]), "\(fencedFlow)\n[21:0-25:4]")
    XCTAssertEqual(copy(5, 3, 15, 7, [flow]), "[5:3-9:50]\n\(fencedFlow)")
    XCTAssertEqual(copy(12, 0, 12, 4, [flow]), fencedFlow)
  }

  /// Touching the first or last row counts; the row before or after does not.
  func testEdgeRows() {
    XCTAssertEqual(copy(5, 0, 10, 0, [flow]), "[5:0-9:50]\n\(fencedFlow)")
    XCTAssertEqual(copy(5, 0, 9, 50, [flow]), "[5:0-9:50]")
    XCTAssertEqual(copy(20, 50, 22, 0, [flow]), "\(fencedFlow)\n[21:0-22:0]")
    XCTAssertEqual(copy(21, 0, 22, 0, [flow]), "[21:0-22:0]")
    XCTAssertEqual(copy(10, 0, 20, 50, [flow]), fencedFlow)
  }

  func testTwoDiagramsInOrderWhateverTheirOrderGiven() {
    XCTAssertEqual(copy(0, 0, 40, 0, [seq, flow]),
                   "[0:0-9:50]\n\(fencedFlow)\n[21:0-29:50]\n\(fencedSeq)\n[36:0-40:0]")
  }

  func testBackToBackDiagrams() {
    let next = DiagramOverlay.Drawing(top: 21, bottom: 25, hash: "n", source: "pie\n  \"a\" : 1")
    XCTAssertEqual(copy(10, 0, 25, 9, [flow, next]), "\(fencedFlow)\n```mermaid\npie\n  \"a\" : 1\n```")
  }
  func testSplitBlockCopiesOnceAndKeepsChangedRowsBetweenItsFragments() {
    var first = flow
    first.bottom = 13
    first.blockTop = 10
    var second = flow
    second.top = 16
    second.blockTop = 10
    XCTAssertEqual(copy(10, 0, 20, 50, [first, second]), "\(fencedFlow)\n[14:0-15:50]")
    var repeated = flow
    repeated.top = 22
    repeated.bottom = 25
    XCTAssertEqual(copy(10, 0, 25, 50, [flow, repeated]), "\(fencedFlow)\n[21:0-21:50]\n\(fencedFlow)")
  }
}
