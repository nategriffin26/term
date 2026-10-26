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

/// The count over the system's vertical bar, whose items the bar moves itself.
@MainActor
final class BarBadgeTests: XCTestCase {
  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  }

  func testBadgeSitsOnTheIconsTopRightCorner() {
    let frame = BarBadge.frame(onCornerOf: CGRect(x: 100, y: 200, width: 38, height: 38), size: CGSize(width: 18, height: 16))
    XCTAssertEqual(frame, CGRect(x: 121, y: 198, width: 18, height: 16))
  }

  /// Bug it catches: the count stayed where the first layout put it when the
  /// bar later moved its icon on its own (window rotated, keyboard rose or
  /// fell), because it was placed once per layout of the terminal's view.
  func testBadgeFollowsAnIconTheBarMovesWithoutAnyLayoutOfOurs() {
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
    var item: CGRect? = CGRect(x: 399, y: 250, width: 38, height: 38)
    let badge = BarBadge(host: { host }, itemFrame: { _ in item })
    badge.count = 1
    XCTAssertEqual(badge.label.frame.midX, 399 + 19 + 11)
    XCTAssertEqual(badge.label.frame.minY, 248)
    XCTAssertTrue(badge.label.superview === host)

    item = CGRect(x: 611, y: 110, width: 38, height: 38)  // rotated: the bar moved
    pump(0.25)
    XCTAssertEqual(badge.label.frame.midX, 611 + 19 + 11)
    XCTAssertEqual(badge.label.frame.minY, 108)
    XCTAssertFalse(badge.label.isHidden)
  }

  /// Bug it would cause: a follower that never stops runs the display link
  /// for as long as a count is showing.
  func testFollowingStopsOnceTheIconIsAtRest() {
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
    let badge = BarBadge(host: { host }, itemFrame: { _ in CGRect(x: 399, y: 250, width: 38, height: 38) })
    badge.count = 2
    XCTAssertTrue(badge.isFollowing)
    pump(0.6)
    XCTAssertFalse(badge.isFollowing)
    badge.follow()
    XCTAssertTrue(badge.isFollowing, "a layout re-arms it")
  }

  /// Bug it catches: a count left floating where the bar used to be after the
  /// bar hid, its icon went away, or the count reached zero.
  func testBadgeHidesWithoutIconBarOrCount() {
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
    var item: CGRect? = CGRect(x: 399, y: 250, width: 38, height: 38)
    var shown: UIView? = host
    let badge = BarBadge(host: { shown }, itemFrame: { _ in item })
    badge.count = 1
    XCTAssertFalse(badge.label.isHidden)

    item = nil
    badge.follow()
    XCTAssertTrue(badge.label.isHidden)
    item = CGRect(x: 399, y: 250, width: 38, height: 38)
    badge.follow()
    XCTAssertFalse(badge.label.isHidden)

    shown = nil
    badge.follow()
    XCTAssertTrue(badge.label.isHidden)
    shown = host
    badge.follow()
    XCTAssertFalse(badge.label.isHidden)

    badge.count = 0
    XCTAssertTrue(badge.label.isHidden)
  }
}
