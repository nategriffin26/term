import UIKit

/// The session switcher's position readout: a capsule in the middle of the
/// pane with one dot per session (the current one in the accent) and the
/// sessions' names in a row under it, the current one centred and its
/// neighbours fading out to the sides. Dots and names follow a swipe as it
/// moves; the capsule fades out after it settles.
@MainActor
final class SessionHUD: UIView {
  private let dotsView = UIView()
  private var dots: [UIView] = []
  private let highlight = UIView()
  private let namesView = UIView()
  private let fade = CAGradientLayer()
  private var labels: [UILabel] = []
  private var names: [String] = []
  private var hideTimer: Timer?
  private var firstShown = -1

  static let dotSize: CGFloat = 7
  static let pitch: CGFloat = 15
  static let namePitch: CGFloat = 112
  static let size = CGSize(width: 280, height: 62)
  static let linger: TimeInterval = 0.8

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    alpha = 0
    bounds = CGRect(origin: .zero, size: Self.size)
    backgroundColor = Helm.UI.raised.withAlphaComponent(0.94)
    layer.cornerRadius = 22
    layer.cornerCurve = .continuous
    layer.borderWidth = 0.5
    layer.borderColor = Helm.UI.line2.cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.35
    layer.shadowRadius = 20
    layer.shadowOffset = CGSize(width: 0, height: 12)
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath

    addSubview(dotsView)
    highlight.backgroundColor = Helm.UI.accent
    highlight.bounds = CGRect(x: 0, y: 0, width: Self.dotSize + 1, height: Self.dotSize + 1)
    highlight.layer.cornerRadius = (Self.dotSize + 1) / 2
    dotsView.addSubview(highlight)

    namesView.frame = CGRect(x: 0, y: 14 + Self.dotSize + 9, width: Self.size.width, height: 18)
    fade.frame = namesView.bounds
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
    fade.locations = [0.04, 0.3, 0.7, 0.96]
    namesView.layer.mask = fade
    addSubview(namesView)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Shows the strip at `position` (a session index, fractional mid-swipe),
  /// centered on `center`.
  func track(names: [String], position: CGFloat, center: CGPoint) {
    hideTimer?.invalidate()
    hideTimer = nil
    setNames(names)
    layoutStrip(position: position, center: center, animateWindow: true)
    if alpha < 1 {
      layer.removeAllAnimations()
      UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.alpha = 1 }
    }
  }

  /// The swipe ended on `index`: dots and names spring there, then the
  /// capsule fades out.
  func settle(names: [String], index: Int, center: CGPoint) {
    setNames(names)
    let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: Helm.springTiming)
    animator.addAnimations { self.layoutStrip(position: CGFloat(index), center: center, animateWindow: false) }
    animator.startAnimation()
    if alpha < 1 {
      UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) { self.alpha = 1 }
    }
    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: Self.linger, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.fadeOut() }
    }
  }

  func hide() {
    hideTimer?.invalidate()
    hideTimer = nil
    layer.removeAllAnimations()
    alpha = 0
  }

  private func fadeOut() {
    hideTimer = nil
    UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) { self.alpha = 0 }
  }

  private func setNames(_ names: [String]) {
    guard names != self.names else { return }
    self.names = names
    firstShown = -1
    for label in labels { label.removeFromSuperview() }
    labels = names.map { name in
      let label = UILabel()
      label.text = name
      label.font = Helm.uiMono(12.5, .medium)
      label.textColor = Helm.UI.fg
      label.textAlignment = .center
      label.lineBreakMode = .byTruncatingMiddle
      label.bounds = CGRect(x: 0, y: 0, width: Self.namePitch - 10, height: namesView.bounds.height)
      namesView.addSubview(label)
      return label
    }
  }

  private func layoutStrip(position: CGFloat, center: CGPoint, animateWindow: Bool) {
    let strip = DotStrip.layout(count: names.count, position: position)
    while dots.count < strip.dots.count {
      let dot = UIView()
      dot.backgroundColor = Helm.UI.muted.withAlphaComponent(0.55)
      dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
      dot.layer.cornerRadius = Self.dotSize / 2
      dotsView.insertSubview(dot, belowSubview: highlight)
      dots.append(dot)
    }
    for (i, dot) in dots.enumerated() { dot.isHidden = i >= strip.dots.count }

    let first = strip.dots.first?.index ?? 0
    let windowMoved = firstShown >= 0 && first != firstShown
    firstShown = first
    let place = {
      for (slot, d) in strip.dots.enumerated() {
        let dot = self.dots[slot]
        dot.center = CGPoint(x: Self.dotSize / 2 + CGFloat(slot) * Self.pitch, y: Self.dotSize / 2)
        dot.transform = CGAffineTransform(scaleX: d.scale, y: d.scale)
      }
      self.highlight.center = CGPoint(x: Self.dotSize / 2 + strip.highlight * Self.pitch, y: Self.dotSize / 2)
    }
    if windowMoved && animateWindow {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: place)
    } else {
      place()
    }

    // Names ride along at a fixed pitch: the current one centred, the
    // neighbours dimmer and fading into the capsule's edges.
    let p = min(max(position, 0), CGFloat(max(names.count - 1, 0)))
    for (i, label) in labels.enumerated() {
      let distance = CGFloat(i) - p
      label.center = CGPoint(x: namesView.bounds.midX + distance * Self.namePitch, y: namesView.bounds.midY)
      label.alpha = abs(distance) > 2 ? 0 : 1 - min(abs(distance), 1.4) / 1.4 * 0.7
    }

    let stripWidth = Self.dotSize + CGFloat(max(strip.dots.count - 1, 0)) * Self.pitch
    dotsView.frame = CGRect(x: ((Self.size.width - stripWidth) / 2).rounded(), y: 14, width: stripWidth, height: Self.dotSize)
    self.center = center
  }
}
