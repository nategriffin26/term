import SwiftUI
import XCTest
@testable import Term

/// The working mark on a Sessions title bar and a tmux row: a light that
/// spirals over a 3 × 3 cell of dots, only while it can be seen.
@MainActor
final class WorkingMarkTests: XCTestCase {
  /// The user's pick: clockwise round the edge from the top-left, then the
  /// centre, then the top-left again. As (column, row).
  private let spiral = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1), (1, 1)]
  /// His values (1 · Hold and exhale): steps of 0.13 s winding in from 1.3× to
  /// 0.7×, a 0.40 s tail, a 0.70 s breath after the centre, 1.87 s a loop.
  private let gaps = [0.169, 0.15925, 0.1495, 0.13975, 0.13, 0.12025, 0.1105, 0.10075]
  private let loop = 1.87

  private func mark(moving: Bool, in window: UIWindow) -> WorkingMarkView {
    let view = WorkingMarkView(frame: CGRect(x: 0, y: 0, width: 15, height: 15))
    window.addSubview(view)
    view.layoutIfNeeded()
    view.moving = moving
    return view
  }

  /// The dot at (column, row), from where it is drawn.
  private func dot(_ cell: (Int, Int), of view: WorkingMarkView) throws -> CALayer {
    let byPlace = view.dots.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    XCTAssertEqual(Set(view.dots.map(\.frame.minX)).count, 3, "three columns")
    XCTAssertEqual(Set(view.dots.map(\.frame.minY)).count, 3, "three rows")
    return try XCTUnwrap(byPlace.indices.contains(cell.1 * 3 + cell.0) ? byPlace[cell.1 * 3 + cell.0] : nil)
  }

  private func lit(_ layer: CALayer) -> CAKeyframeAnimation? { layer.animation(forKey: "lit") as? CAKeyframeAnimation }

  private func makeWindow() -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    window.isHidden = false
    return window
  }

  // Bug: the light skips the centre, runs the wrong way, keeps an even pace
  // instead of quickening toward the centre, or starts again without the breath.
  func testTheLightWindsInFromTheTopLeftToTheCentreThenBreathesBeforeStartingAgain() throws {
    let view = mark(moving: true, in: makeWindow())
    let animations = try spiral.map { try XCTUnwrap(lit(try dot($0, of: view)), "dot \($0) lights") }
    for (gap, (earlier, later)) in zip(gaps, zip(animations, animations.dropFirst())) {
      XCTAssertEqual(later.beginTime - earlier.beginTime, gap, accuracy: 0.0001)
    }
    let centre = try XCTUnwrap(animations.last).beginTime - animations[0].beginTime
    XCTAssertEqual(loop - centre, 0.791, accuracy: 0.0001, "the centre's 0.091 s step, then the 0.70 s breath")
    for animation in animations {
      XCTAssertEqual(animation.duration, loop, accuracy: 0.0001, "after the breath, the top-left again")
      XCTAssertEqual(animation.repeatCount, .infinity)
    }
  }

  // Bug: a dot goes dark between visits (the cell stops reading as a grid),
  // or stays lit as a line instead of fading behind the light.
  func testEachEdgeDotFadesBehindTheLightToItsRestingDim() throws {
    let view = mark(moving: true, in: makeWindow())
    for cell in spiral.dropLast() {
      let animation = try XCTUnwrap(lit(try dot(cell, of: view)))
      let values = try XCTUnwrap(animation.values as? [NSNumber]).map(\.floatValue)
      XCTAssertEqual(values, [1, 0.18, 0.18], "lit, then at rest and still visible")
      XCTAssertEqual(try XCTUnwrap(animation.keyTimes?[1]).doubleValue * loop, 0.40, accuracy: 0.0001, "the tail")
    }
  }

  // Bug: the centre drops at once (the rushed restart the user saw), or is
  // still lit when the top-left starts again.
  func testTheCentreHoldsThenExhalesToRestAsTheTopLeftLightsAgain() throws {
    let view = mark(moving: true, in: makeWindow())
    let centre = try XCTUnwrap(lit(try dot((1, 1), of: view)))
    XCTAssertEqual(try XCTUnwrap(centre.values as? [NSNumber]).map(\.floatValue), [1, 1, 0.18, 0.18])
    let times = try XCTUnwrap(centre.keyTimes).map { $0.doubleValue * loop }
    XCTAssertEqual(times[1], 0.301, accuracy: 0.0001, "lit through its step and 30 % of the breath")
    XCTAssertEqual(times[2], 0.791, accuracy: 0.0001, "at rest when the top-left lights")
    let exhale = try XCTUnwrap(centre.timingFunctions?[1])
    var p1: [Float] = [0, 0], p2: [Float] = [0, 0]
    exhale.getControlPoint(at: 1, values: &p1)
    exhale.getControlPoint(at: 2, values: &p2)
    XCTAssertEqual(p1 + p2, [0.42, 0, 0.58, 1], "a slow exhale: ease in-out")
  }

  // Bug: two working sessions on screen blink out of step.
  func testMarksStartedApartLightTheSameDotTogether() throws {
    let window = makeWindow()
    let first = mark(moving: true, in: window)
    Thread.sleep(forTimeInterval: 0.05)
    let second = mark(moving: true, in: window)
    let a = try XCTUnwrap(lit(first.dots[0])).beginTime, b = try XCTUnwrap(lit(second.dots[0])).beginTime
    XCTAssertEqual(fmod(abs(a - b), loop), 0, accuracy: 0.0001)
  }

  // Bug: marks keep animating with the menu closed or their tab hidden.
  func testItMovesOnlyWhileItsSurfaceIsOnScreen() throws {
    let window = makeWindow()
    let host = UIHostingController(rootView: AnyView(WorkingMark().environment(\.isOnScreen, true)))
    window.rootViewController = host
    host.view.frame = window.bounds
    settle(host)
    let view = try XCTUnwrap(find(in: host.view))
    XCTAssertNotNil(lit(view.dots[0]), "on screen")

    host.rootView = AnyView(WorkingMark().environment(\.isOnScreen, false))
    settle(host)
    XCTAssertTrue(view.dots.allSatisfy { $0.animationKeys() == nil }, "out of sight")

    host.rootView = AnyView(WorkingMark().environment(\.isOnScreen, true))
    settle(host)
    XCTAssertNotNil(lit(view.dots[0]), "back on screen")

    view.removeFromSuperview()
    XCTAssertTrue(view.dots.allSatisfy { $0.animationKeys() == nil }, "out of the window")
  }

  // Bug: under Reduce Motion the mark goes blank or reads as idle.
  func testStillItShowsTheTopRowLitTowardItsEnd() throws {
    let view = mark(moving: false, in: makeWindow())
    XCTAssertTrue(view.dots.allSatisfy { $0.animationKeys() == nil })
    XCTAssertEqual(try dot((0, 0), of: view).opacity, 0.4)
    XCTAssertEqual(try dot((1, 0), of: view).opacity, 0.65)
    XCTAssertEqual(try dot((2, 0), of: view).opacity, 1)
    for cell in spiral.dropFirst(3) { XCTAssertEqual(try dot(cell, of: view).opacity, 0.18, "\(cell) at rest") }
  }

  // Bug: the dots keep the old theme's text colour after a theme change.
  func testTheDotsFollowTheThemeOfTheirWindow() throws {
    let window = makeWindow()
    window.traitOverrides[AppThemeTrait.self] = AppTheme.fixed()
    let view = mark(moving: true, in: window)
    window.layoutIfNeeded()
    XCTAssertEqual(UIColor(cgColor: try XCTUnwrap(view.dots[0].backgroundColor)).argb, UIColor(rgb: 0xF6F4FA).argb, "the fixed palette's text")

    var red = AppTheme.fixed()
    red.fg = AppTheme.Tone(rgb: 0xFF0000)
    window.traitOverrides[AppThemeTrait.self] = red
    window.layoutIfNeeded()
    XCTAssertEqual(UIColor(cgColor: try XCTUnwrap(view.dots[0].backgroundColor)).argb, 0xFFFF_0000)
  }

  /// SwiftUI applies a new root view on its next update.
  private func settle(_ host: UIHostingController<AnyView>) {
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
  }

  private func find(in view: UIView) -> WorkingMarkView? {
    if let mark = view as? WorkingMarkView { return mark }
    return view.subviews.lazy.compactMap { self.find(in: $0) }.first
  }
}
