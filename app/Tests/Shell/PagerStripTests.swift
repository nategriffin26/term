import XCTest
@testable import Term

final class PagerStripTests: XCTestCase {
  let w: CGFloat = 400

  // Bug: settling on the previous page sent the next page from the right edge
  // across the whole screen to the left, over the page coming in. It must stay
  // off the right edge, as the strip's last page.
  func testSettlingOnPreviousKeepsNextToTheRight() {
    XCTAssertEqual(PagerStrip.resting(on: .previous, width: w),
                   PagerStrip(previous: 0, current: 400, next: 800))
  }

  // Bug: the mirror of the above for a swipe toward the next page, hidden only
  // by view stacking order: the previous page must stay off the left edge.
  func testSettlingOnNextKeepsPreviousToTheLeft() {
    XCTAssertEqual(PagerStrip.resting(on: .next, width: w),
                   PagerStrip(previous: -800, current: -400, next: 0))
  }

  func testCancelledSwipeReturnsToTheCurrentPage() {
    XCTAssertEqual(PagerStrip.resting(on: .current, width: w),
                   PagerStrip(previous: -400, current: 0, next: 400))
  }

  // Invariant: pages keep their order, one width apart, wherever the finger is
  // and wherever the strip settles.
  func testPagesNeverCrossOrDriftApart() {
    var strips = [-500, -400, -1, 0, 1, 133, 400, 650].map { PagerStrip.dragged(by: CGFloat($0), width: w) }
    strips += [PagerStrip.Page.previous, .current, .next].map { PagerStrip.resting(on: $0, width: w) }
    for s in strips {
      XCTAssertEqual(s.current - s.previous, w, "\(s)")
      XCTAssertEqual(s.next - s.current, w, "\(s)")
    }
  }
}
