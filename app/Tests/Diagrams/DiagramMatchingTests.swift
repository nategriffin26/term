import XCTest
@testable import Term

final class DiagramMatchingTests: XCTestCase {
  func testEmptyAndOneRowScreensCannotProduceAnInvalidUnmatchedSlice() async {
    let worker = DiagramMatching()
    let empty = await worker.scan([], candidates: [], screen: true)
    XCTAssertTrue(empty.matches.isEmpty)
    XCTAssertTrue(empty.unmatched.isEmpty)
    let edge = await worker.scan(["```mermaid"], candidates: [], screen: true)
    XCTAssertTrue(edge.matches.isEmpty)
    XCTAssertTrue(edge.unmatched.isEmpty)
  }

  func testWorkerMatchesTheSamePublishedDrawingAndReportsUnknownWords() async {
    let worker = DiagramMatching()
    let rows = ["", "┌────────────┐", "│ alpha beta │", "└────────────┘", ""]
    let known = await worker.scan(rows, candidates: [.init(hash: "flow", time: 1, source: "flowchart TD\n A[alpha] --> B[beta]")], screen: true)
    XCTAssertEqual(known.matches, [.init(top: 1, bottom: 3, hash: "flow")])
    XCTAssertEqual(known.unmatched, [])
    let unknown = await worker.scan(rows, candidates: [], screen: true)
    XCTAssertEqual(unknown.matches, [])
    XCTAssertEqual(unknown.unmatched, ["alpha beta"])
  }
}
