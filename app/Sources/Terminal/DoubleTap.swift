import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A quick double tap, recognised without holding the first tap back: the
/// first acts at once (it raises the keyboard or sends the program a click),
/// and the second, landing inside UIKit's own double-tap window, becomes the
/// double tap and does nothing else, so a program never sees a double-click.
struct DoubleTap {
  /// UITapGestureRecognizer's own window for a double tap (read on iOS 27):
  /// at most 0.35 s from the first tap's lift to the second's touch, and 45 pt apart.
  static let interval: TimeInterval = 0.35
  static let distance: CGFloat = 45

  private var first: (lift: TimeInterval, point: CGPoint)?

  /// A plain tap at `point`, touched at `touch` and lifted at `lift` (the
  /// touches' event times, so a late handler changes nothing): true when it
  /// completes a double tap, which uses up both taps; false when it may start one.
  mutating func tap(at point: CGPoint, touch: TimeInterval, lift: TimeInterval) -> Bool {
    if let first, touch >= first.lift, touch - first.lift <= Self.interval,
       hypot(point.x - first.point.x, point.y - first.point.y) <= Self.distance {
      self.first = nil
      return true
    }
    first = (lift, point)
    return false
  }

  /// Something other than a plain tap happened: no double tap spans it.
  mutating func reset() { first = nil }
}

/// A tap recognizer that keeps its touch's event times, so a double tap is
/// told from two taps by when the fingers moved, never by when the handler ran.
class TimedTapGestureRecognizer: UITapGestureRecognizer {
  /// When the latest tap's finger came down and lifted (UITouch time).
  var touchTime: TimeInterval = 0
  var liftTime: TimeInterval = 0

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { touchTime = touch.timestamp }
    super.touchesBegan(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { liftTime = touch.timestamp }
    super.touchesEnded(touches, with: event)
  }
}
