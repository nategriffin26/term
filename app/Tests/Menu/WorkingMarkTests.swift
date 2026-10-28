import SwiftUI
import XCTest
@testable import Term

/// The working mark on a Sessions title bar and a tmux row: a light that
/// spirals over a 3 × 3 cell of dots, only while it can be seen.
@MainActor
final class WorkingMarkTests: XCTestCase {
  /// The user's pick: clockwise round the edge from the top-left, then the
  /// centre, 0.12 s a dot, then the top-left again. As (column, row).
  private let spiral = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1), (1, 1)]

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

  // Bug: the light skips the centre, runs the wrong way, or does not start
  // again from the top-left after the centre.
  func testTheLightSpiralsInFromTheTopLeftToTheCentreThenStartsAgain() throws {
    let view = mark(moving: true, in: makeWindow())
    let animations = try spiral.map { try XCTUnwrap(lit(try dot($0, of: view)), "dot \($0) lights") }
    for (earlier, later) in zip(animations, animations.dropFirst()) {
      XCTAssertEqual(later.beginTime - earlier.beginTime, 0.12, accuracy: 0.0001)
    }
    for animation in animations {
      XCTAssertEqual(animation.duration, 1.08, accuracy: 0.0001, "after the centre, the top-left again")
      XCTAssertEqual(animation.repeatCount, .infinity)
    }
  }

  // Bug: a dot goes dark between visits (the cell stops reading as a grid),
  // or stays lit as a line instead of fading behind the light.
  func testEachDotFadesBehindTheLightToItsRestingDim() throws {
    let view = mark(moving: true, in: makeWindow())
    for layer in view.dots {
      let animation = try XCTUnwrap(lit(layer))
      let values = try XCTUnwrap(animation.values as? [NSNumber]).map(\.floatValue)
      XCTAssertEqual(values.first, 1, "lit")
      XCTAssertEqual(values.last, 0.18, "at rest, still visible")
      XCTAssertEqual(values.min(), 0.18, "never darker than at rest")
      XCTAssertEqual(try XCTUnwrap(animation.keyTimes?[1]).doubleValue * 1.08, 0.36, accuracy: 0.0001, "dimmed after three steps")
    }
  }

  // Bug: two working sessions on screen blink out of step.
  func testMarksStartedApartLightTheSameDotTogether() throws {
    let window = makeWindow()
    let first = mark(moving: true, in: window)
    Thread.sleep(forTimeInterval: 0.05)
    let second = mark(moving: true, in: window)
    let a = try XCTUnwrap(lit(first.dots[0])).beginTime, b = try XCTUnwrap(lit(second.dots[0])).beginTime
    XCTAssertEqual(fmod(abs(a - b), 1.08), 0, accuracy: 0.0001)
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
