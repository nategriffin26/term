import UIKit
import XCTest
@testable import Term

@MainActor
final class DiagramScrollTests: XCTestCase {
  private let source = "flowchart TD\n A[alpha] --> B[beta]"
  private let box = ["┌───────┐", "│ alpha │", "└───┬───┘", "    ▼", "┌───────┐", "│ beta  │", "└───────┘"]

  private func terminal() throws -> TerminalView {
    let session = try XCTUnwrap(Session(localCols: 40, rows: 20))
    let sources = DiagramSource(tmuxSession: nil) { _ in nil }
    sources.merge([.init(hash: "scroll-flow", time: 1, source: source)])
    session.diagrams = sources
    return TerminalView(session: session)
  }

  private func frame(_ rows: [String], in view: TerminalView) {
    view.session.feed("\u{1B}[2J\u{1B}[H" + rows.joined(separator: "\r\n"))
    var frame = TermFrame()
    _ = view.session.frame(after: .max, into: &frame)
    view.snapshot.load(frame)
    view.diagramOverlay.frameChanged()
  }

  private func settle(_ view: TerminalView) async throws {
    for _ in 0..<100 {
      if !view.diagramOverlay.shown.isEmpty { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("The fixture diagram never rendered")
  }

  func testKnownDrawingMovesImmediatelyWhenOnlyOneGlyphRowRemains() async throws {
    let view = try terminal()
    let content = ["intro", ""] + box + ["", "following text", "more text", "last line"]
    frame(content, in: view)
    try await settle(view)
    frame(Array(content.dropFirst(8)), in: view)
    XCTAssertEqual(view.diagramOverlay.shown.count, 1, "An identified edge slice must not revert to ASCII")
    XCTAssertEqual(view.diagramOverlay.drawings.first?.top, -6)
    XCTAssertEqual(view.diagramOverlay.drawings.first?.bottom, 0)
  }

  func testKnownDrawingKeepsItsScaleAndImageOriginAcrossTopEdge() async throws {
    let view = try terminal()
    let content = ["intro", ""] + box + ["", "following text", "more text", "last line"]
    frame(content, in: view)
    try await settle(view)
    let old = try XCTUnwrap(view.diagramOverlay.shown.first)
    let oldImage = old.tile.subviews[0].frame
    frame(Array(content.dropFirst(4)), in: view)
    let new = try XCTUnwrap(view.diagramOverlay.shown.first)
    XCTAssertEqual(new.tile.subviews[0].frame.size, oldImage.size, "Clipping must not resize the diagram")
    XCTAssertEqual(new.tile.subviews[0].frame.minY, -2 * view.cellSizePoints.height, accuracy: 0.001)
  }

  func testSourceTextKeepsFullPieSizeWhenClosingFenceLeavesScreen() async throws {
    let view = try terminal()
    let pie = "pie title Pets adopted\n \"Dogs\" : 386\n \"Cats\" : 85\n \"Rats\" : 15"
    view.session.diagrams?.merge([.init(hash: "scroll-pie", time: 2, source: pie)])
    let content = ["intro", ""] + box + ["", "pie follows", "```mermaid"] + pie.components(separatedBy: "\n") + ["```", "", "end"]
    frame(content, in: view)
    for _ in 0..<100 {
      if view.diagramOverlay.shown.contains(where: { $0.drawing.hash == "scroll-pie" }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let old = try XCTUnwrap(view.diagramOverlay.shown.first { $0.drawing.hash == "scroll-pie" })
    let size = old.tile.subviews[0].frame.size
    frame(["older 1", "older 2", "older 3", "older 4", "older 5"] + Array(content.prefix(15)), in: view)
    let new = try XCTUnwrap(view.diagramOverlay.shown.first { $0.drawing.hash == "scroll-pie" })
    XCTAssertEqual(new.tile.subviews[0].frame.size, size, "A pie must not grow when its closing fence leaves the viewport")
  }

  func testNewSourceAtBottomWaitsForItsHeightInsteadOfShowingAnEnlargedSlice() async throws {
    let view = try terminal()
    let pie = "pie title Pets adopted\n \"Dogs\" : 386\n \"Cats\" : 85\n \"Rats\" : 15"
    view.session.diagrams?.merge([.init(hash: "cold-pie", time: 2, source: pie)])
    frame((0..<17).map { "paragraph \($0)" } + ["```mermaid", "pie title Pets adopted", " \"Dogs\" : 386"], in: view)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(view.diagramOverlay.shown.contains { $0.drawing.hash == "cold-pie" },
                   "An unknown block height must not show a large half-pie")
  }

  func testSelectionDoesNotReplaceTmuxStatusWithTheClippedDiagramSource() async throws {
    let view = try terminal()
    let content = ["intro", ""] + box + ["", "following text", "more text", "last line"]
    frame(["status", "position 0"] + content, in: view)
    try await settle(view)
    frame(["status", "position 5"] + Array(content.dropFirst(5)), in: view)
    XCTAssertEqual(view.diagramOverlay.drawings.first?.top, 2,
                   "The diagram's offscreen origin is not its selectable visible slice")
  }

  func testCopyPositionPreservesOnlyItsColoredSuffixNotARawSourceRow() async throws {
    let view = try terminal()
    let content = ["intro", ""] + box + ["", "following text", "more text", "last line"]
    frame(["status", "position 0"] + content, in: view)
    try await settle(view)
    let marker = "[5/99]"
    let row = box[2] + String(repeating: " ", count: 40 - box[2].count - marker.count)
      + "\u{1B}[7m" + marker + "\u{1B}[0m"
    frame(["status", row] + Array(content.dropFirst(5)), in: view)
    let shown = try XCTUnwrap(view.diagramOverlay.shown.first)
    XCTAssertEqual(view.diagramOverlay.drawings.first?.top, 1)
    XCTAssertEqual(shown.frame.minY, view.cellSizePoints.height, accuracy: 0.001)
    let mask = try XCTUnwrap(shown.tile.layer.mask as? CAShapeLayer)
    let path = try XCTUnwrap(mask.path)
    XCTAssertTrue(path.contains(CGPoint(x: 5, y: 5), using: .evenOdd))
    XCTAssertFalse(path.contains(CGPoint(x: view.cellSizePoints.width * 38, y: 5), using: .evenOdd))
  }
  func testCopyCounterInsideVerifiedEdgeRowsKeepsItsOwnCells() async throws {
    let view = try terminal()
    frame(["intro", ""] + box + ["", "following text", "more text", "last line"], in: view)
    try await settle(view)
    for (i, scalar) in "[3/99]".unicodeScalars.enumerated() {
      let cell = 2 * view.snapshot.cols + view.snapshot.cols - 6 + i
      view.snapshot.cells[cell].ch = scalar.value
      view.snapshot.cells[cell].bg = 0xFF12_3456
    }
    view.diagramOverlay.layoutTiles()
    let shown = try XCTUnwrap(view.diagramOverlay.shown.first)
    let mask = try XCTUnwrap(shown.tile.layer.mask as? CAShapeLayer,
                             "A partially delivered copy counter can be inside an otherwise verified block")
    let path = try XCTUnwrap(mask.path)
    XCTAssertFalse(path.contains(CGPoint(x: view.cellSizePoints.width * 38, y: 5), using: .evenOdd))
  }

  func testTerminalPresentationSharesTheDiagramLayerTransaction() throws {
    let view = try terminal()
    XCTAssertTrue(view.metalLayer.presentsWithTransaction,
                  "The grid must not show an older frame beneath already-moved diagram tiles")
  }

  func testLastKnownRowBesideCopyCounterRemainsCovered() async throws {
    let view = try terminal()
    let content = ["intro", ""] + box + ["", "following text", "more text", "last line"]
    frame(["status", "position 0"] + content, in: view)
    try await settle(view)
    let marker = "[9/99]"
    let row = box[6] + String(repeating: " ", count: 40 - box[6].count - marker.count)
      + "\u{1B}[7m" + marker + "\u{1B}[0m"
    frame(["status", row] + Array(content.dropFirst(9)), in: view)
    XCTAssertEqual(view.diagramOverlay.shown.count, 1, "The last known row must not be dropped before the counter cutout is applied")
    XCTAssertEqual(view.diagramOverlay.drawings.first?.top, 1)
    XCTAssertEqual(view.diagramOverlay.drawings.first?.bottom, 1)
  }
}
