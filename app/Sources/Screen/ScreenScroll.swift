import CoreGraphics
import UIKit

/// Two-finger scrolling as a Mac trackpad gives it to apps: a gesture's
/// events (began, changed..., ended), then on lift a momentum run that
/// decays like UIScrollView's normal deceleration (momentum began,
/// changed..., ended). A new touch ends the momentum at once. Distances are
/// Mac points the content moves, positive following the fingers right and down.
struct ScrollPhaser {
  private(set) var inGesture = false
  private(set) var inMomentum = false
  /// Momentum began has gone out.
  private var momentumStarted = false
  /// Content velocity, Mac points per second.
  private var velocity = CGVector.zero

  /// Below this the momentum stops (Mac points per second).
  static let stopSpeed: CGFloat = 12
  /// UIScrollView.DecelerationRate.normal: velocity kept per millisecond.
  static let decay: CGFloat = UIScrollView.DecelerationRate.normal.rawValue

  /// The fingers moved the content by `delta`. A gesture that starts while
  /// momentum runs ends the momentum first.
  mutating func move(_ delta: CGVector) -> [ScreenWire.ScrollEvent] {
    var out = interrupt()
    out.append(ScreenWire.ScrollEvent(dx: delta.dx, dy: delta.dy, phase: inGesture ? .changed : .began, momentum: .none))
    inGesture = true
    return out
  }

  /// The fingers lifted moving at `velocity` (content points per second).
  /// Momentum follows when it is fast enough.
  mutating func lift(velocity: CGVector) -> [ScreenWire.ScrollEvent] {
    guard inGesture else { return [] }
    inGesture = false
    self.velocity = velocity
    inMomentum = hypot(velocity.dx, velocity.dy) >= Self.stopSpeed
    return [ScreenWire.ScrollEvent(dx: 0, dy: 0, phase: .ended, momentum: .none)]
  }

  /// The gesture was cancelled (a pinch won, the view went away): no momentum.
  mutating func cancel() -> [ScreenWire.ScrollEvent] {
    guard inGesture else { return interrupt() }
    inGesture = false
    return [ScreenWire.ScrollEvent(dx: 0, dy: 0, phase: .cancelled, momentum: .none)]
  }

  /// One frame of momentum, `dt` seconds after the last. Its last event is
  /// momentum ended; after that it returns nothing.
  mutating func tick(_ dt: TimeInterval) -> [ScreenWire.ScrollEvent] {
    guard inMomentum else { return [] }
    let started = velocity
    let keep = pow(Self.decay, CGFloat(dt * 1000))
    velocity = CGVector(dx: velocity.dx * keep, dy: velocity.dy * keep)
    // The distance covered while decaying from the old velocity to the new one.
    let travel = (1 - keep) / (-1000 * log(Self.decay))
    let phase: ScreenWire.MomentumPhase = momentumStarted ? .changed : .began
    momentumStarted = true
    var out = [ScreenWire.ScrollEvent(dx: started.dx * travel, dy: started.dy * travel, phase: .none, momentum: phase)]
    if hypot(velocity.dx, velocity.dy) < Self.stopSpeed { out += interrupt() }
    return out
  }

  /// Ends a running momentum (a touch landed): momentum ended, once.
  mutating func interrupt() -> [ScreenWire.ScrollEvent] {
    guard inMomentum else { return [] }
    inMomentum = false
    velocity = .zero
    defer { momentumStarted = false }
    return momentumStarted ? [ScreenWire.ScrollEvent(dx: 0, dy: 0, phase: .none, momentum: .ended)] : []
  }
}
