import XCTest
@testable import Term

/// The Screen's picture on the stage, fed a two-display Mac: a built-in
/// display (1728x1117 pt, 3456 px wide, main, at 0,0) and an external
/// 3440x1440 display (1 px per pt) placed to its right, 687 pt higher.
final class ScreenViewportTests: XCTestCase {
  let builtIn = (frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixelWidth: 3456)
  let external = (frame: CGRect(x: 1728, y: -687, width: 3440, height: 1440), pixelWidth: 3440)
  let stage = CGRect(x: 0, y: 0, width: 800, height: 600)

  private func all(visible: CGRect? = nil) -> ScreenViewport {
    ScreenViewport(displays: [builtIn, external], fit: stage, visible: visible ?? stage)
  }

  private func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: 0.01, file: file, line: line)
  }

  // Bug: All Displays drawn as one display's size, side by side ignoring the
  // external display's 687 pt rise, or not fitted whole into the stage.
  func testAllDisplaysFitInTheirRealArrangement() {
    let v = all()
    // The arrangement is 5168 x 1804 pt: width-bound at 800/5168, centred vertically.
    XCTAssertEqual(v.scale, 0.154799, accuracy: 0.000001)
    assertRect(v.stage(builtIn.frame), CGRect(x: 0, y: 266.718, width: 267.492, height: 172.910))
    assertRect(v.stage(external.frame), CGRect(x: 267.492, y: 160.372, width: 532.508, height: 222.910))
  }

  // Bug: one display shown at its place in the arrangement (tiny, off centre)
  // instead of filling the stage alone.
  func testOneDisplayFillsTheStage() {
    let v = ScreenViewport(displays: [external], fit: stage, visible: stage)
    assertRect(v.stage(external.frame), CGRect(x: 0, y: 132.558, width: 800, height: 334.884))
    let middle = v.mac(CGPoint(x: 400, y: 300))
    XCTAssertEqual(middle.x, 3448, accuracy: 0.01)
    XCTAssertEqual(middle.y, 33, accuracy: 0.01)
  }

  // Bug: zoom running past 2 stage points per Mac pixel, or a pinch below Fit staying there.
  func testZoomStopsAtTwoPointsPerPixelAndSpringsBackToFit() {
    var v = all()
    v.pinch(by: 100, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 300))
    XCTAssertEqual(v.scale, 4, accuracy: 0.0001, "the built-in display has 2 px per pt: 2 x 2")

    var one = ScreenViewport(displays: [external], fit: stage, visible: stage)
    one.pinch(by: 100, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 300))
    XCTAssertEqual(one.scale, 2, accuracy: 0.0001, "the external display has 1 px per pt")

    v = all()
    v.pinch(by: 0.1, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 300, y: 200))
    XCTAssertEqual(v.zoom, ScreenViewport.rubberZoom, accuracy: 0.0001)
    v.endPinch()
    XCTAssertEqual(v.zoom, 1)
    XCTAssertEqual(v, all(), "back to Fit, centred")
  }

  // Bug (the user's report): moving the fingers during a pinch at Fit doing
  // nothing (the picture pinned centred), so the bottom of the Mac could
  // never be brought above the keyboard; or the picture going back once the
  // fingers lift or the keyboard goes down.
  func testAPinchCarriesThePictureAtFitAndItStaysWhereItIsLeft() {
    var v = all()
    let fitted = v.origin
    let keyboardUp = CGRect(x: 0, y: 0, width: 800, height: 300)
    v.layout(fit: stage, visible: keyboardUp)
    v.pinch(by: 1, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 420, y: 100))
    v.endPinch()
    XCTAssertEqual(v.origin.x, fitted.x + 20, accuracy: 0.001)
    XCTAssertEqual(v.origin.y, fitted.y - 200, accuracy: 0.001)
    let bottom = v.stage(CGPoint(x: 0, y: 1117)).y
    XCTAssertLessThan(bottom, 300, "the Mac's bottom edge sits above the keyboard")
    v.layout(fit: stage, visible: stage)
    XCTAssertEqual(v.origin.y, fitted.y - 200, accuracy: 0.001, "it stays when the keyboard goes down")
  }

  // Bug: a picture flung past its edge lost off the stage for good.
  func testAPlacedPictureKeepsAPartInView() {
    var v = all()
    v.pinch(by: 1, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: -10_000, y: -10_000))
    XCTAssertEqual(v.stage(CGPoint(x: 5168, y: 1117)).x, ScreenViewport.keptVisible, accuracy: 0.001)
    XCTAssertEqual(v.stage(CGPoint(x: 5168, y: 1117)).y, ScreenViewport.keptVisible, accuracy: 0.001)
    v.pinch(by: 1, anchor: CGPoint(x: 0, y: 0), to: CGPoint(x: 10_000, y: 10_000))
    XCTAssertEqual(v.stage(CGPoint(x: 0, y: -687)).x, 800 - ScreenViewport.keptVisible, accuracy: 0.001)
    XCTAssertEqual(v.stage(CGPoint(x: 0, y: -687)).y, 600 - ScreenViewport.keptVisible, accuracy: 0.001)
  }

  // Bug: Trackpad Mode's picture-follows-pointer undoing the user's
  // placement whenever the Mac moves its pointer or the stage lays out again.
  func testFollowingLeavesAPlacementAloneUnlessTheUserMovesThePointerOutOfView() {
    var v = all()
    v.pinch(by: 1, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 100))
    v.endPinch()
    let placed = v.origin
    v.follow(CGPoint(x: 0, y: -687), margin: 32)  // the Mac put it at its top-left corner, above the stage
    XCTAssertEqual(v.origin, placed)
    v.layout(fit: stage, visible: stage)
    XCTAssertEqual(v.origin, placed)

    // The user drags the pointer from in view up past the stage's top: the picture comes down with it.
    v.follow(CGPoint(x: 800, y: -500), from: CGPoint(x: 800, y: 0), margin: 32)
    XCTAssertEqual(v.stage(CGPoint(x: 800, y: -500)).y, 32, accuracy: 0.001)
  }

  // Bug: pinching zooms around the stage's corner instead of the fingers.
  func testPinchKeepsTheMacPointUnderTheFingers() {
    var v = all()
    let fingers = CGPoint(x: 300, y: 320)
    let under = v.mac(fingers)
    v.pinch(by: 3, anchor: fingers, to: fingers)
    let after = v.stage(under)
    XCTAssertEqual(after.x, fingers.x, accuracy: 0.01)
    XCTAssertEqual(after.y, fingers.y, accuracy: 0.01)
  }

  // Bug: a zoomed picture panned off the stage, leaving empty space inside it.
  func testPanStopsAtThePicturesEdges() {
    var v = all()
    v.pinch(by: 4, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 300))
    let region = v.stage(CGRect(x: 0, y: -687, width: 5168, height: 1804))
    v.pan(by: CGVector(dx: 10_000, dy: 10_000))
    XCTAssertEqual(v.origin.x, 0, accuracy: 0.001)
    XCTAssertEqual(v.origin.y, 0, accuracy: 0.001)
    v.pan(by: CGVector(dx: -100_000, dy: -100_000))
    XCTAssertEqual(v.origin.x + region.width, 800, accuracy: 0.001)
    XCTAssertEqual(v.origin.y + region.height, 600, accuracy: 0.001)
  }

  // Bug: a picture that fits being dragged around (Screens: no movement when it fits).
  func testAFittingPictureDoesNotPan() {
    var v = all()
    let fitted = v.origin
    v.pan(by: CGVector(dx: 120, dy: -90))
    XCTAssertEqual(v.origin, fitted)
  }

  // Bug: the pointer driven off the visible area, or the picture jumping
  // further than the overshoot when it follows.
  func testThePictureFollowsThePointerByTheOvershoot() {
    var v = all()
    v.pinch(by: 4, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 300))
    v.pan(by: CGVector(dx: 10_000, dy: 0))  // the arrangement's left edge at the stage's
    let pointer = v.mac(CGPoint(x: 790, y: 300))
    v.follow(pointer, margin: 32)
    XCTAssertEqual(v.stage(pointer).x, 800 - 32, accuracy: 0.001)
    XCTAssertEqual(v.stage(pointer).y, 300, accuracy: 0.001)
  }

  // Bug: following past the display's own edge, showing empty space beyond it.
  func testFollowingStopsAtTheDisplaysEdge() {
    var v = all()
    v.pinch(by: 4, anchor: CGPoint(x: 400, y: 300), to: CGPoint(x: 400, y: 300))
    let lastColumn = CGPoint(x: 5167, y: 0)
    v.follow(lastColumn, margin: 32)
    let right = v.stage(CGPoint(x: 5168, y: 0)).x
    XCTAssertEqual(right, 800, accuracy: 0.001, "the arrangement's right edge stops at the stage's")
  }

  // Bug: the keyboard coming up moving the picture, or covering the pointer.
  func testKeyboardUpKeepsThePictureAndThePointerFollowsAboveIt() {
    var v = all()
    let fitted = v.origin
    let keyboardUp = CGRect(x: 0, y: 0, width: 800, height: 300)
    v.layout(fit: stage, visible: keyboardUp)
    XCTAssertEqual(v.origin, fitted, "covering never moves the picture")

    let pointer = CGPoint(x: 800, y: 900)  // on the built-in display, drawn at y 406, under the keyboard
    XCTAssertEqual(v.stage(pointer).y, 406.037, accuracy: 0.001)
    v.follow(pointer, margin: 32)
    XCTAssertEqual(v.stage(pointer).y, 300 - 32, accuracy: 0.001)

    v.layout(fit: stage, visible: stage)
    XCTAssertEqual(v.origin, fitted, "uncovering brings it back")
  }

  // Bug: trackpad travel ignoring the zoom (a zoomed-in pointer racing away) or the tracking speed.
  func testTrackpadTravelIsTheFingersDistanceAsDrawnTimesSpeed() {
    var v = all()
    let finger = CGVector(dx: 100, dy: -40)
    XCTAssertEqual(v.pointerTravel(finger, speed: 1).dx, 646.0, accuracy: 0.01)
    XCTAssertEqual(v.pointerTravel(finger, speed: 1).dy, -258.4, accuracy: 0.01)
    v.pinch(by: 100, anchor: .zero, to: .zero)  // 4 stage points per Mac point
    XCTAssertEqual(v.pointerTravel(finger, speed: 1).dx, 25, accuracy: 0.0001)
    XCTAssertEqual(v.pointerTravel(finger, speed: 2).dx, 50, accuracy: 0.0001)
    XCTAssertEqual(v.pointerTravel(finger, speed: 0.5).dy, -5, accuracy: 0.0001)
  }

  // Bug: the pointer parked in the arrangement's empty corner (right of the
  // built-in display, below the external one), where the Mac has no pixels.
  func testThePointerStaysOnADisplay() {
    let frames = [builtIn.frame, external.frame]
    XCTAssertEqual(ScreenArrangement.clamp(CGPoint(x: 2000, y: 1000), to: frames), CGPoint(x: 2000, y: 752))
    XCTAssertEqual(ScreenArrangement.clamp(CGPoint(x: 1800, y: 1100), to: frames), CGPoint(x: 1727, y: 1100))
    XCTAssertEqual(ScreenArrangement.clamp(CGPoint(x: 900, y: 400), to: frames), CGPoint(x: 900, y: 400))
    XCTAssertEqual(ScreenArrangement.clamp(CGPoint(x: 9000, y: -2000), to: frames), CGPoint(x: 5167, y: -687))
    XCTAssertEqual(ScreenArrangement.clamp(CGPoint(x: -5, y: 1117), to: frames), CGPoint(x: 0, y: 1116))
  }

  // Bug: an edge swipe sending the pointer one past the display (off it) or to the wrong display's edge.
  func testEdgeSwipesReachTheDisplaysEdgesAndCorners() {
    XCTAssertEqual(ScreenArrangement.edgePoint(.bottom, on: builtIn.frame), CGPoint(x: 864, y: 1116))
    XCTAssertEqual(ScreenArrangement.edgePoint([.top, .right], on: external.frame), CGPoint(x: 5167, y: -687))
    XCTAssertEqual(ScreenArrangement.edgePoint(.left, on: external.frame), CGPoint(x: 1728, y: 33))
  }
}
