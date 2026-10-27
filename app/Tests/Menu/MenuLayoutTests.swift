import XCTest
@testable import Term

/// Where the menu panel goes, fed the geometry the simulators report:
/// iPhone 11 414x896 pt portrait (safe area 48 pt top, 34 pt bottom), and the
/// Duo inner display 951x669 pt landscape (vertical bar 84 pt on the right,
/// home indicator 34 pt).
final class MenuLayoutTests: XCTestCase {
  let phone = CGRect(x: 0, y: 0, width: 414, height: 896)
  let phoneSafe = UIEdgeInsets(top: 48, left: 0, bottom: 34, right: 0)
  /// The panel over the whole safe area: 8 pt margins inside 0,48 414x814.
  let phoneFull = CGRect(x: 8, y: 56, width: 398, height: 798)

  // Bug: the panel under the notch or the home indicator, or not filling the terminal.
  func testKeyboardDownFillsTheSafeArea() {
    // The keyboard layout guide sits at the safe area's bottom while the keyboard is down.
    XCTAssertEqual(MenuLayout.panelFrame(bounds: phone, safe: phoneSafe, keyboardTop: 862), phoneFull)
    XCTAssertEqual(MenuLayout.panelFrame(bounds: phone, safe: phoneSafe, keyboardTop: nil), phoneFull)
    XCTAssertEqual(MenuLayout.panelFrame(bounds: phone, safe: phoneSafe, keyboardTop: 896), phoneFull)
  }

  // Bug: the panel drawn behind the keyboard instead of over the visible terminal.
  func testKeyboardUpEndsThePanelAboveIt() {
    let panel = MenuLayout.panelFrame(bounds: phone, safe: phoneSafe, keyboardTop: 520)
    XCTAssertEqual(panel, CGRect(x: 8, y: 56, width: 398, height: 456))
  }

  // Bug: the split keyboard on the Duo's inner display ignored, or the panel under the vertical bar.
  func testDuoSplitKeyboardKeepsThePanelLeftOfTheBarAndAboveTheKeys() {
    let inner = CGRect(x: 0, y: 0, width: 951, height: 669)
    let innerSafe = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)
    // The split keyboard stays docked at the bottom, its top at y 342.
    XCTAssertEqual(MenuLayout.panelFrame(bounds: inner, safe: innerSafe, keyboardTop: 342),
                   CGRect(x: 8, y: 8, width: 851, height: 326))
    XCTAssertEqual(MenuLayout.panelFrame(bounds: inner, safe: innerSafe, keyboardTop: 635),
                   CGRect(x: 8, y: 8, width: 851, height: 619))
  }

  // A short viewport must not dismiss the keyboard or put the panel behind it.
  func testShortPanelStaysAboveTheKeyboard() {
    for height in [279.0, 280.0, 281.0] {
      XCTAssertEqual(MenuLayout.panelFrame(bounds: phone, safe: phoneSafe, keyboardTop: 48 + height + 16),
                     CGRect(x: 8, y: 56, width: 398, height: height))
    }
  }

  // No available height still produces a nonnegative, on-screen frame.
  func testKeyboardAboveTheSafeAreaLeavesAnEmptyPanel() {
    XCTAssertEqual(MenuLayout.panelFrame(bounds: phone, safe: phoneSafe, keyboardTop: 20),
                   CGRect(x: 8, y: 48, width: 398, height: 0))
  }

  // Bug (seen on the Duo): a hidden tab keeps 48 rows while its tile fits 31,
  // and the thumbnail showed the empty bottom rows, so every tile but the
  // current one was black.
  func testThumbnailOfATallSessionShowsTheTopWhenTheCursorIsThere() {
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 48, cursor: 1, visible: 31), 0)
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 48, cursor: 30, visible: 31), 0)
  }

  // Bug: a prompt that scrolled to the bottom of a tall session cut off.
  func testThumbnailFollowsTheCursorDown() {
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 48, cursor: 31, visible: 31), 1)
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 48, cursor: 47, visible: 31), 17)
  }

  // Bug: a session shorter than its tile shifted up, or a degenerate tile crashing.
  func testThumbnailOfAShortSessionStartsAtTheTop() {
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 20, cursor: 19, visible: 31), 0)
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 0, cursor: 0, visible: 0), 0)
  }

  // Bug (seen on the Duo at 3 columns): a 120-column session squeezed into its
  // tile at ~2 pt, so no tile could be told apart from another.
  @MainActor
  func testThumbnailTextNeverDropsBelowSixPoints() {
    let fonts = ThumbnailRenderer().fonts(cellWidth: 5, scale: 3, family: FontSet.family)
    XCTAssertGreaterThanOrEqual(fonts.pointSize, 6)
  }

  // Bug: a command line longer than the tile's legible width cut off with the
  // cursor out of view, or a short line shifted off its prompt.
  func testThumbnailKeepsTheCursorColumnInView() {
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 120, cursor: 2, visible: 40), 0)
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 120, cursor: 39, visible: 40), 0)
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 120, cursor: 40, visible: 40), 1)
    XCTAssertEqual(MenuLayout.thumbnailFirst(count: 120, cursor: 119, visible: 40), 80)
  }
}

/// The session HUD's dots: at most 7 shown, a window around the current session.
final class DotStripTests: XCTestCase {
  private func indices(_ strip: DotStrip) -> [Int] { strip.dots.map(\.index) }
  private func scales(_ strip: DotStrip) -> [CGFloat] { strip.dots.map(\.scale) }

  // Bug: dots shrunk or dropped when every session fits.
  func testUpToSevenSessionsShowEveryDotFullSize() {
    let three = DotStrip.layout(count: 3, position: 1)
    XCTAssertEqual(indices(three), [0, 1, 2])
    XCTAssertEqual(scales(three), [1, 1, 1])
    XCTAssertEqual(three.highlight, 1)

    let seven = DotStrip.layout(count: 7, position: 6)
    XCTAssertEqual(indices(seven), [0, 1, 2, 3, 4, 5, 6])
    XCTAssertEqual(scales(seven), [1, 1, 1, 1, 1, 1, 1])
    XCTAssertEqual(seven.highlight, 6)
  }

  // Bug: an eighth dot drawn past the capsule, or no hint that more sessions follow.
  func testEightSessionsWindowToSevenWithASmallEdge() {
    let eight = DotStrip.layout(count: 8, position: 0)
    XCTAssertEqual(indices(eight), [0, 1, 2, 3, 4, 5, 6])
    XCTAssertEqual(scales(eight), [1, 1, 1, 1, 1, 1, 0.5])
  }

  // Bug: the highlight off its session once the row is windowed, or small dots
  // on an edge with nothing beyond it.
  func testTwentySessionsKeepTheCurrentOneInTheWindow() {
    let first = DotStrip.layout(count: 20, position: 0)
    XCTAssertEqual(indices(first), [0, 1, 2, 3, 4, 5, 6])
    XCTAssertEqual(scales(first), [1, 1, 1, 1, 1, 1, 0.5])
    XCTAssertEqual(first.highlight, 0)

    let middle = DotStrip.layout(count: 20, position: 10)
    XCTAssertEqual(indices(middle), [7, 8, 9, 10, 11, 12, 13])
    XCTAssertEqual(scales(middle), [0.5, 1, 1, 1, 1, 1, 0.5])
    XCTAssertEqual(middle.highlight, 3)

    let last = DotStrip.layout(count: 20, position: 19)
    XCTAssertEqual(indices(last), [13, 14, 15, 16, 17, 18, 19])
    XCTAssertEqual(scales(last), [0.5, 1, 1, 1, 1, 1, 1])
    XCTAssertEqual(last.highlight, 6)
  }

  // Bug: the highlight jumping between dots mid-swipe instead of following the finger.
  func testFractionalPositionPutsTheHighlightBetweenDots() {
    XCTAssertEqual(DotStrip.layout(count: 3, position: 1.25).highlight, 1.25, accuracy: 0.0001)
    let mid = DotStrip.layout(count: 20, position: 10.4)
    XCTAssertEqual(indices(mid), [7, 8, 9, 10, 11, 12, 13])
    XCTAssertEqual(mid.highlight, 3.4, accuracy: 0.0001)
    // Past halfway the window has moved on one session; the highlight is still at 10.6.
    let past = DotStrip.layout(count: 20, position: 10.6)
    XCTAssertEqual(past.dots[Int(past.highlight.rounded())].index, 11)
    XCTAssertEqual(CGFloat(past.dots[0].index) + past.highlight, 10.6, accuracy: 0.0001)
  }

  // Bug: an overscrolled swipe (rubber band) moving the highlight off the row.
  func testPositionIsClampedToTheSessions() {
    XCTAssertEqual(DotStrip.layout(count: 4, position: -0.3).highlight, 0)
    XCTAssertEqual(DotStrip.layout(count: 4, position: 3.4).highlight, 3)
    XCTAssertEqual(DotStrip.layout(count: 0, position: 0).dots, [])
  }
}
