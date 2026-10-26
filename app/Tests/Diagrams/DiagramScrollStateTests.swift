import XCTest
@testable import Term

final class DiagramScrollStateTests: XCTestCase {
  private let rows = ["status", "a first", "b second", "c third", "d fourth", "e fifth", "f sixth", "g seventh", "h eighth", "bottom"]

  func testDetectsBothScrollDirectionsDespiteFixedStatusRows() {
    let down = ["status 12:05", "new one", "new two"] + Array(rows[1...6]) + ["footer"]
    XCTAssertEqual(DiagramScrollState.shift(from: rows, to: down), 2)
    XCTAssertEqual(DiagramScrollState.shift(from: down, to: rows), -2)
  }

  func testDoesNotInventMotionFromBlankOrRepeatedRows() {
    XCTAssertNil(DiagramScrollState.shift(from: Array(repeating: "", count: 20), to: Array(repeating: "│", count: 20)))
    XCTAssertNil(DiagramScrollState.shift(from: rows, to: rows.map { $0 + " changed" }))
    XCTAssertNil(DiagramScrollState.shift(from: rows, to: Array(rows.dropLast())))
    XCTAssertEqual(DiagramScrollState.shift(from: rows, to: ["clock changed"] + Array(rows.dropFirst())), 0)
  }

  func testTranslatesKnownBoundsAndRetainsOneRowSlice() {
    var state = DiagramScrollState()
    state.update(rows)
    state.merge([.init(top: 2, bottom: 7, hash: "flow")], origin: state.origin, epoch: state.epoch)
    let shifted = ["new status"] + Array(rows[7...8]) + ["next 1", "next 2", "next 3", "next 4", "next 5", "next 6", "footer"]
    // Three independent rows are needed; use a larger screen for this edge.
    let full = (0..<30).map { "content row \($0)" }
    state.update(full)
    state.merge([.init(top: 2, bottom: 7, hash: "flow")], origin: state.origin, epoch: state.epoch)
    state.update(Array(full.dropFirst(7)) + (30..<37).map { "content row \($0)" })
    XCTAssertEqual(state.visible, [.init(top: -5, bottom: 0, hash: "flow")])
    XCTAssertNil(DiagramScrollState.shift(from: rows, to: shifted), "A two-row overlap is not enough evidence")
  }

  func testLateMatchUsesItsCapturedOriginButNotAReplacedScreen() {
    var state = DiagramScrollState()
    state.update(rows)
    let origin = state.origin, epoch = state.epoch
    let down = ["status 12:05", "new one", "new two"] + Array(rows[1...6]) + ["footer"]
    state.update(down)
    state.merge([.init(top: 2, bottom: 4, hash: "flow")], origin: origin, epoch: epoch)
    XCTAssertEqual(state.visible.first?.top, 4)
    state.update(rows.map { $0 + " replaced" })
    state.merge([.init(top: 2, bottom: 4, hash: "stale")], origin: origin, epoch: epoch)
    XCTAssertEqual(state.visible, [])
  }

  func testPartialRematchCannotDiscardPreviouslyKnownEdges() {
    var state = DiagramScrollState()
    state.update(rows)
    state.merge([.init(top: 2, bottom: 7, hash: "flow")], origin: state.origin, epoch: state.epoch)
    state.merge([.init(top: 3, bottom: 6, hash: "flow", openTop: true, openBottom: true)], origin: state.origin, epoch: state.epoch)
    XCTAssertEqual(state.visible, [.init(top: 2, bottom: 7, hash: "flow")])
  }

  func testAClockChangeDoesNotDiscardAnIdentifiedRepetitiveDrawing() {
    let old = ["clock 12:00"] + Array(repeating: "│", count: 18) + ["footer"]
    let new = ["clock 12:01"] + Array(repeating: "│", count: 18) + ["footer"]
    XCTAssertEqual(DiagramScrollState.shift(from: old, to: new), 0)
  }

  func testClosingFenceResolvesATallSourceWhoseOpeningHasScrolledAway() {
    var state = DiagramScrollState()
    let content = ["```mermaid"] + (1..<30).map { "source row \($0)" } + ["```", "following paragraph"]
    state.update(Array(content.prefix(20)))
    state.merge([.init(top: 0, bottom: 19, hash: "large", openBottom: true, isText: true)],
                origin: state.origin, epoch: state.epoch)
    state.update(Array(content[12...31]))
    XCTAssertEqual(state.visible.first?.top, -12)
    XCTAssertEqual(state.visible.first?.bottom, 18)
    XCTAssertEqual(state.visible.first?.openBottom, false)
  }

  func testChangedProseCannotRetainAnOldDiagramOverItsRows() {
    let old = (0..<30).map { "content row \($0)" }
    var changed = old
    changed[10] = "replacement prose"
    XCTAssertNil(DiagramScrollState.shift(from: old, to: changed))
  }

  func testKnownSlicesLeaveFixedStatusRowsUncovered() {
    var state = DiagramScrollState()
    let old = ["status"] + (1..<19).map { "row \($0)" } + ["footer"]
    state.update(old)
    state.merge([.init(top: 2, bottom: 9, hash: "flow")], origin: state.origin, epoch: state.epoch)
    state.update(["status changed"] + (6..<24).map { "row \($0)" } + ["footer"])
    XCTAssertEqual(state.visible.first?.top, -3)
    XCTAssertEqual(state.visible.first?.bottom, 4)
    XCTAssertEqual(state.visible.first?.clipTop, 1)
  }

  func testAPartialIdentityCanBeRefinedButACompleteDrawingCannotBeReplaced() {
    var state = DiagramScrollState()
    state.update(rows)
    state.merge([.init(top: 0, bottom: 5, hash: "partial", openTop: true)], origin: state.origin, epoch: state.epoch)
    state.merge([.init(top: 0, bottom: 5, hash: "complete")], origin: state.origin, epoch: state.epoch)
    XCTAssertEqual(state.visible.first?.hash, "complete")
    state.merge([.init(top: 0, bottom: 5, hash: "wrong", openTop: true)], origin: state.origin, epoch: state.epoch)
    XCTAssertEqual(state.visible.count, 1)
    XCTAssertEqual(state.visible.first?.hash, "complete")
  }

  func testCopyPositionBelowTheStatusLineDoesNotBreakTranslation() {
    let old = ["status", "top position 0"] + (2..<29).map { "row \($0)" } + ["footer"]
    let new = ["status", "top position 5"] + (7..<34).map { "row \($0)" } + ["footer"]
    XCTAssertEqual(DiagramScrollState.shift(from: old, to: new), -5)
    var state = DiagramScrollState()
    state.update(old)
    state.merge([.init(top: 2, bottom: 9, hash: "flow")], origin: state.origin, epoch: state.epoch)
    state.update(new)
    XCTAssertEqual(state.visible.first?.clipTop, 2)
  }
}
