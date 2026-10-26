import XCTest
@testable import Term

/// The count drawn on the tmux icon, in the band dock and over the vertical bar.
@MainActor
final class DockBadgeTests: XCTestCase {
  /// Bug it catches: a count that fell to zero (he entered the last session
  /// that had stopped) left the old number on the icon.
  func testCountShowsAndZeroHides() {
    let badge = DockBadge()
    XCTAssertTrue(badge.isHidden)
    badge.count = 3
    XCTAssertEqual(badge.text, "3")
    XCTAssertFalse(badge.isHidden)
    badge.count = 0
    XCTAssertTrue(badge.isHidden)
    badge.count = 12
    XCTAssertEqual(badge.text, "12")
    XCTAssertFalse(badge.isHidden)
  }

  func testTwoDigitsAreWiderThanOne() {
    let badge = DockBadge()
    badge.count = 1
    let one = badge.intrinsicContentSize
    badge.count = 12
    XCTAssertEqual(one.height, 16)
    XCTAssertGreaterThan(badge.intrinsicContentSize.width, one.width)
    XCTAssertGreaterThanOrEqual(one.width, one.height, "never narrower than a circle")
  }
}
