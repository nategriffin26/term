import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A quick double tap in the terminal's right edge band. A tap there is held
/// for UIKit's double-tap window, so a pair never moves the keyboard or reaches
/// the program; a tap left alone is released when the window has passed.
@MainActor
final class DoubleTap {
  /// UITapGestureRecognizer's own window for a double tap (read on iOS 27):
  /// at most 0.35 s from the first tap's lift to the second's touch, and 45 pt apart.
  static let interval: TimeInterval = 0.35
  static let distance: CGFloat = 45

  /// The right 18 % of a terminal of `bounds`, at least 56 pt wide.
  static func band(in bounds: CGRect) -> CGRect {
    let width = min(bounds.width, max(bounds.width * 0.18, 56))
    return CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
  }

  /// When the finger now on the terminal touched down (UITouch time); nil when none is.
  var touchDown: () -> TimeInterval? = { nil }

  private var held: (lift: TimeInterval, point: CGPoint, release: () -> Void, timer: Timer)?

  /// The held tap's lift (UITouch time); nil when none is held.
  var heldLift: TimeInterval? { held?.lift }

  /// The last tap released (not dropped), for the diagnostic log: a band tap
  /// inside the window of a tap already released shows what released it.
  private(set) var lastRelease: (lift: TimeInterval, byTimer: Bool)?

  /// Whether a tap at `point`, touched at `touch` (event times, so a late
  /// handler changes nothing), completes a double tap with the held one.
  func pairs(at point: CGPoint, touch: TimeInterval) -> Bool {
    guard let held else { return false }
    return touch >= held.lift && touch - held.lift <= Self.interval
      && hypot(point.x - held.point.x, point.y - held.point.y) <= Self.distance
  }

  /// Holds a tap lifted at `lift` (its UITouch time, which pairing compares
  /// with the next touch): `release` runs once the window has passed with no
  /// second tap. The window is timed from now, never by comparing `lift` with
  /// another clock. A tap already held is released first.
  func hold(at point: CGPoint, lift: TimeInterval, release: @escaping () -> Void) {
    self.release()
    held = (lift, point, release, schedule(after: Self.interval))
  }

  /// Releases the held tap now.
  func release() {
    release(byTimer: false)
  }

  private func release(byTimer: Bool) {
    guard let held else { return }
    self.held = nil
    lastRelease = (held.lift, byTimer)
    held.timer.invalidate()
    held.release()
  }

  /// Something other than a plain tap happened, or the pair completed: the held tap is dropped.
  func reset() {
    guard let held else { return }
    held.timer.invalidate()
    self.held = nil
    DiagnosticLog.record(.tap, "hold-dropped")
  }

  private func schedule(after delay: TimeInterval) -> Timer {
    let start = CACurrentMediaTime()
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.windowPassed(delay: delay, waited: CACurrentMediaTime() - start) }
    }
    // Common modes: the window runs out while another view is tracking a touch too.
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  /// A finger that touched down inside the window may still lift as the
  /// second tap: wait for its tap before releasing the first.
  private func windowPassed(delay: TimeInterval, waited: TimeInterval) {
    guard let held else { return }
    let timing = "delay=\(DiagnosticLog.seconds(delay)) fired=\(DiagnosticLog.seconds(waited)) lift=\(DiagnosticLog.seconds(held.lift))"
    if let touch = touchDown(), touch >= held.lift, touch - held.lift <= Self.interval {
      DiagnosticLog.record(.tap, "hold-extended", timing + " fingerDown=\(DiagnosticLog.seconds(touch - held.lift))")
      self.held?.timer = schedule(after: 0.03)
      return
    }
    DiagnosticLog.record(.tap, "hold-released", timing)
    release(byTimer: true)
  }
}

/// A tap recognizer that keeps its touch's event times, so a double tap is
/// told from two taps by when the fingers moved, never by when the handler ran.
class TimedTapGestureRecognizer: UITapGestureRecognizer {
  /// When the latest tap's finger came down and lifted (UITouch time).
  var touchTime: TimeInterval = 0
  var liftTime: TimeInterval = 0

  /// When the finger it is tracking now came down; nil when none is.
  var touchingSince: TimeInterval? {
    state == .possible && numberOfTouches > 0 ? touchTime : nil
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { touchTime = touch.timestamp }
    super.touchesBegan(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { liftTime = touch.timestamp }
    super.touchesEnded(touches, with: event)
  }
}
