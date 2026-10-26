import UIKit

/// The session switcher's position readout: a glass capsule in the middle
/// of the pane with one dot per session (the current one in the text
/// colour) and the sessions' names in a row under it, the current one
/// centred and its neighbours fading out to the sides. Dots and names follow
/// a swipe as it moves; the capsule dissolves after it settles.
@MainActor
final class SessionHUD: UIView {
  private let glass = GlassView()
  /// Dots and names, faded with the glass.
  private let content = UIView()
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
    bounds = CGRect(origin: .zero, size: Self.size)
    glass.frame = bounds
    glass.cornerConfiguration = .corners(radius: .fixed(Chrome.Radius.group))
    addSubview(glass)
    content.frame = bounds
    content.alpha = 0
    addSubview(content)

    content.addSubview(dotsView)
    highlight.backgroundColor = Chrome.UI.fg
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
    content.addSubview(namesView)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Shows the strip at `position` (a session index, fractional mid-swipe),
  /// centered on `center`.
  func track(names: [String], position: CGFloat, center: CGPoint) {
    hideTimer?.invalidate()
    hideTimer = nil
    setNames(names)
    layoutStrip(position: position, center: center, animateWindow: true)
    show()
  }

  /// The swipe ended on `index`: dots and names spring there, then the
  /// capsule fades out.
  func settle(names: [String], index: Int, center: CGPoint) {
    setNames(names)
    let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: Chrome.springTiming)
    animator.addAnimations { self.layoutStrip(position: CGFloat(index), center: center, animateWindow: false) }
    animator.startAnimation()
    show()
    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: Self.linger, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.fadeOut() }
    }
  }

  func hide() {
    hideTimer?.invalidate()
    hideTimer = nil
    UIView.performWithoutAnimation {
      glass.isGlassShown = false
      content.alpha = 0
    }
  }

  /// Glass materializes rather than fading: a fading superview breaks its effect.
  private func show() {
    guard !glass.isGlassShown else { return }
    UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
      self.glass.isGlassShown = true
      self.content.alpha = 1
    }
  }

  private func fadeOut() {
    hideTimer = nil
    UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
      self.glass.isGlassShown = false
      self.content.alpha = 0
    }
  }

  private func setNames(_ names: [String]) {
    guard names != self.names else { return }
    self.names = names
    firstShown = -1
    for label in labels { label.removeFromSuperview() }
    labels = names.map { name in
      let label = UILabel()
      label.text = name
      label.font = Chrome.uiMono(.secondary, .medium, size: .standard)  // fits the HUD's fixed 18 pt strip
      label.textColor = Chrome.UI.fg
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
      dot.backgroundColor = Chrome.UI.faint
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
