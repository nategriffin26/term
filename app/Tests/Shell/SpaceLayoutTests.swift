import XCTest
@testable import Term

/// Pane placement on iPhone Duo, fed the geometry the Duo simulator reports
/// (iOS 27.1): inner display 951x669 pt landscape with the vertical bar on the
/// trailing edge (84 pt) and the home indicator (34 pt); fold region 40 pt
/// wide at x 455.5 (margins included); outer display 466x678 pt.
final class SpaceLayoutTests: XCTestCase {
  let innerLandscape = CGRect(x: 0, y: 0, width: 951, height: 669)
  let innerLandscapeSafe = CGRect(x: 0, y: 0, width: 867, height: 635)
  let bookFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)

  let innerPortrait = CGRect(x: 0, y: 0, width: 669, height: 951)
  let innerPortraitSafe = CGRect(x: 0, y: 82, width: 669, height: 835)
  let tabletopFold = CGRect(x: 0, y: 455.5, width: 669, height: 40)

  let outerPortrait = CGRect(x: 0, y: 0, width: 466, height: 678)
  let outerPortraitSafe = CGRect(x: 0, y: 0, width: 382, height: 644)

  // Bug: a grid laid across the fold, or a half that stops short of the window edge.
  func testBookFoldGivesOnePaneEachSideOfTheFold() {
    let layout = SpaceLayout.compute(bounds: innerLandscape, safe: innerLandscapeSafe, division: bookFold,
                                     splitWhenFlat: false, regularWidth: true)
    XCTAssertEqual(layout, .sideBySide(CGRect(x: 0, y: 0, width: 455.5, height: 669),
                                       CGRect(x: 495.5, y: 0, width: 455.5, height: 669)))
    for pane in layout.panes {
      XCTAssertFalse(pane.intersects(bookFold), "\(pane) crosses the fold")
    }
  }

  // Bug: the terminal drawn over the fold or below it in tabletop.
  func testTabletopKeepsTheTerminalAboveTheFold() {
    let layout = SpaceLayout.compute(bounds: innerPortrait, safe: innerPortraitSafe, division: tabletopFold,
                                     splitWhenFlat: true, regularWidth: true)
    XCTAssertEqual(layout, .tabletop(CGRect(x: 0, y: 0, width: 669, height: 455.5)))
  }

  // Bug: the terminal background stops at the safe area instead of running under the bars.
  func testFlatPaneFillsTheWindow() {
    XCTAssertEqual(SpaceLayout.compute(bounds: innerLandscape, safe: innerLandscapeSafe, division: nil,
                                       splitWhenFlat: false, regularWidth: true),
                   .single(innerLandscape))
    XCTAssertEqual(SpaceLayout.compute(bounds: outerPortrait, safe: outerPortraitSafe, division: nil,
                                       splitWhenFlat: true, regularWidth: false),
                   .single(outerPortrait))
  }

  // Bug: the vertical bar's width taken out of one pane only, or text run up against the hairline.
  func testTwoPanesHalveTheSafeAreaAroundAGap() {
    let layout = SpaceLayout.compute(bounds: innerLandscape, safe: innerLandscapeSafe, division: nil,
                                     splitWhenFlat: true, regularWidth: true)
    XCTAssertEqual(layout, .sideBySide(CGRect(x: 0, y: 0, width: 427, height: 669),
                                       CGRect(x: 440, y: 0, width: 511, height: 669)))
    // Both panes keep 427 pt of safe width; the right one runs on under the bar.
    XCTAssertEqual(layout.panes[0].intersection(innerLandscapeSafe).width, 427)
    XCTAssertEqual(layout.panes[1].intersection(innerLandscapeSafe).width, 427)
  }

  // Bug: splitting into panes too narrow to use (under 320 pt each).
  func testTwoPanesNeedRoomForTwo320PointPanes() {
    let bounds = CGRect(x: 0, y: 0, width: 700, height: 600)
    let narrow = SpaceLayout.compute(bounds: bounds, safe: CGRect(x: 0, y: 0, width: 652, height: 600), division: nil,
                                     splitWhenFlat: true, regularWidth: true)
    XCTAssertEqual(narrow, .single(bounds))
    let enough = SpaceLayout.compute(bounds: bounds, safe: CGRect(x: 0, y: 0, width: 653, height: 600), division: nil,
                                     splitWhenFlat: true, regularWidth: true)
    XCTAssertEqual(enough.panes.count, 2)
    XCTAssertEqual(enough.panes.map(\.width), [320, 367])
  }

  // Bug: Two Panes lost on the inner display held upright (669 pt wide, as the user holds it).
  func testTwoPanesFitTheInnerDisplayInPortrait() {
    XCTAssertEqual(SpaceLayout.compute(bounds: innerPortrait, safe: innerPortraitSafe, division: nil,
                                       splitWhenFlat: true, regularWidth: true).panes.count, 2)
  }

  // Bug: Two Panes on the compact outer display.
  func testTwoPanesNeedRegularWidth() {
    let layout = SpaceLayout.compute(bounds: innerLandscape, safe: innerLandscapeSafe, division: nil,
                                     splitWhenFlat: true, regularWidth: false)
    XCTAssertEqual(layout, .single(innerLandscape))
  }

  // Bug: a fold region outside the window's safe area still splitting it.
  func testFoldOutsideTheSafeAreaIsIgnored() {
    let offscreen = CGRect(x: 900, y: 0, width: 40, height: 669)
    let layout = SpaceLayout.compute(bounds: innerLandscape, safe: innerLandscapeSafe, division: offscreen,
                                     splitWhenFlat: false, regularWidth: true)
    XCTAssertEqual(layout, .single(innerLandscape))
  }
}
