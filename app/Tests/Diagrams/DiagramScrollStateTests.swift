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
  func testUnrelatedRedrawDoesNotDiscardVerifiedBlockGeometry() {
    let original = (0..<30).map { "content row \($0)" }
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 5, bottom: 12, hash: "flow")], origin: state.origin, epoch: state.epoch)
    var changed = original
    changed[20] = "new paragraph"
    state.update(changed)
    XCTAssertEqual(state.visible, [.init(top: 5, bottom: 12, hash: "flow")])
  }

  func testLargeJumpBackRestoresKnownSourceBeforeAsyncMatching() {
    let original = (0..<30).map { "content row \($0)" }
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 5, bottom: 12, hash: "source", isText: true)], origin: state.origin, epoch: state.epoch)
    state.update((100..<130).map { "other row \($0)" })
    state.update(original)
    XCTAssertEqual(state.visible, [.init(top: 5, bottom: 12, hash: "source", isText: true)])
  }

  func testNonuniformRedrawRepositionsEachBlockIndependently() {
    let original = (0..<30).map { "content row \($0)" }
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 3, bottom: 7, hash: "first"), .init(top: 15, bottom: 20, hash: "second")],
                origin: state.origin, epoch: state.epoch)
    var changed = (100..<130).map { "other row \($0)" }
    changed.replaceSubrange(5...9, with: original[3...7])
    changed.replaceSubrange(14...19, with: original[15...20])
    state.update(changed)
    XCTAssertEqual(state.visible, [.init(top: 5, bottom: 9, hash: "first"), .init(top: 14, bottom: 19, hash: "second")])
  }

  func testPartialRedrawCoversOnlyIndependentlyVerifiedRows() {
    let original = (0..<30).map { "content row \($0)" }
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 5, bottom: 12, hash: "source", isText: true)], origin: state.origin, epoch: state.epoch)
    var changed = original
    changed.replaceSubrange(9...12, with: (100..<104).map { "replacement \($0)" })
    state.update(changed)
    XCTAssertEqual(state.visible, [.init(top: 5, bottom: 12, hash: "source", isText: true, clipBottom: 8)])
    state.merge([.init(top: 5, bottom: 12, hash: "source", isText: true)], origin: state.origin, epoch: state.epoch)
    XCTAssertEqual(state.visible, [.init(top: 5, bottom: 12, hash: "source", isText: true, clipBottom: 8)],
                   "A vocabulary rematch cannot overrule exact evidence that those rows changed")
  }

  func testJumpToKnownSourceFragmentKeepsOffscreenFencesAndFullHeight() {
    let original = (0..<30).map { "content row \($0)" }
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 5, bottom: 12, hash: "source", isText: true)], origin: state.origin, epoch: state.epoch)
    state.update((100..<130).map { "other row \($0)" })
    let fragment = ["status", "position"] + Array(original[9...12]) + (200..<224).map { "new row \($0)" }
    state.update(fragment)
    XCTAssertEqual(state.visible, [.init(top: -2, bottom: 5, hash: "source", isText: true, clipTop: 2)])
  }
  func testOpeningFenceAloneCannotIdentifyAnotherSource() {
    var state = DiagramScrollState()
    let original = ["intro", "```mermaid", "erDiagram", "  USER ||--o{ TASK : owns", "```"] + (5..<20).map { "row \($0)" }
    state.update(original)
    state.merge([.init(top: 1, bottom: 4, hash: "er", isText: true)], origin: state.origin, epoch: state.epoch)
    state.update((100..<120).map { "other \($0)" })
    state.update((200..<219).map { "new \($0)" } + ["```mermaid"])
    XCTAssertTrue(state.visible.isEmpty, "A fence is shared syntax, not a source identity")
  }

  func testRowsSharedByDifferentSourcesCannotEstablishIdentity() {
    var state = DiagramScrollState()
    let original = ["intro", "```mermaid", "first source", "int id", "string name", "```", "separator",
                    "```mermaid", "second source", "int id", "string name", "```"] + (12..<20).map { "row \($0)" }
    state.update(original)
    state.merge([.init(top: 1, bottom: 5, hash: "first", isText: true),
                 .init(top: 7, bottom: 11, hash: "second", isText: true)], origin: state.origin, epoch: state.epoch)
    state.update((100..<120).map { "other \($0)" })
    var changed = (200..<220).map { "new \($0)" }
    changed[9] = "int id"
    changed[10] = "string name"
    state.update(changed)
    XCTAssertTrue(state.visible.isEmpty, "Shared field rows must not choose either source")
  }
  func testReanchoringOneBlockPreservesVerifiedWordlessNeighborOnReversal() {
    var original = (0..<30).map { "content row \($0)" }
    original[12] = "└───────┘"
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 5, bottom: 12, hash: "first"), .init(top: 20, bottom: 27, hash: "second")],
                origin: state.origin, epoch: state.epoch)
    let jumped = ["status", "position", "changed 1", "changed 2", "changed 3"] + Array(original[20...27]) + (100..<117).map { "new \($0)" }
    XCTAssertNil(DiagramScrollState.shift(from: original, to: jumped))
    state.update(jumped)
    XCTAssertEqual(state.visible.map(\.hash), ["second"])
    let reversed = ["status", "└───────┘"] + Array(original[13...14]) + Array(jumped[0...25])
    state.update(reversed)
    XCTAssertEqual(state.visible.first?.hash, "first", "A verified neighboring block establishes the coordinate space before a wordless edge returns")
    XCTAssertEqual(state.visible.first?.top, -6)
    XCTAssertEqual(state.visible.first?.bottom, 1)
  }
  func testRemovedCopyCounterDoesNotKeepAVerifiedSourceRowClipped() {
    let original = (0..<30).map { "content row \($0)" }
    var state = DiagramScrollState()
    state.update(original)
    state.merge([.init(top: 2, bottom: 12, hash: "source", isText: true)], origin: state.origin, epoch: state.epoch)
    var shifted = ["status", "copy counter"] + Array(original[7...29]) + (30..<35).map { "content row \($0)" }
    state.update(shifted)
    XCTAssertEqual(state.visible.first?.clipTop, 2)
    shifted[1] = original[6]
    state.update(shifted)
    XCTAssertEqual(state.visible.first?.clipTop, 1, "A restored exact source row is not terminal chrome")
  }

  func testColdUpwardScrollExtendsKnownGlyphRowsAndFindsTheRealTop() {
    let candidate = DiagramMatcher.Candidate(hash: "flow", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")
    let old = ["status", "│ alpha │", "│ beta │", "└──────┘"] + (4..<30).map { "paragraph \($0)" }
    var state = DiagramScrollState()
    state.update(old)
    state.merge([.init(top: 1, bottom: 3, hash: "flow", openTop: true)], origin: state.origin, epoch: state.epoch)
    let up = ["status", "┌──────┐"] + Array(old[1...28])
    state.update(up, candidates: [candidate])
    XCTAssertEqual(state.visible.first?.top, 1, "A known image must cover newly arriving glyph rows before an async rematch")
    XCTAssertEqual(state.visible.first?.openTop, true)
    state.update(["status", "heading", ""] + Array(up[1...27]), candidates: [candidate])
    XCTAssertEqual(state.visible.first?.top, 3)
    XCTAssertEqual(state.visible.first?.openTop, false, "The visible blank separator establishes the real top immediately")
  }

  func testColdDownwardScrollExtendsKnownGlyphRowsAndFindsTheRealBottom() {
    let candidate = DiagramMatcher.Candidate(hash: "flow", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")
    let old = (0..<27).map { "paragraph \($0)" } + ["┌──────┐", "│ alpha │", "│ beta │"]
    var state = DiagramScrollState()
    state.update(old)
    state.merge([.init(top: 27, bottom: 29, hash: "flow", openBottom: true)], origin: state.origin, epoch: state.epoch)
    let down = Array(old.dropFirst()) + ["└──────┘"]
    state.update(down, candidates: [candidate])
    XCTAssertEqual(state.visible.first?.bottom, 29)
    state.update(Array(down.dropFirst()) + ["following prose"], candidates: [candidate])
    XCTAssertEqual(state.visible.first?.bottom, 28)
    XCTAssertEqual(state.visible.first?.openBottom, false)
  }
}
