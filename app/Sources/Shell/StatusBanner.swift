import UIKit

/// The glass line at the top of a pane when a remote stops answering, with
/// Reconnect (mosh's "Last contact" bar, made actionable). The core reports
/// UNREACHABLE after 5 s of silence, so the banner shows as soon as it does.
/// Otherwise it carries the tab's notice: an upload's progress (a ring and
/// the percent) or why it failed (a dot in the failure colour).
final class StatusBanner: UIView {
  private let glass = GlassView()
  private let label = UILabel()
  private let percent = UILabel()
  private let ring = RingView()
  private let dot = UIView()
  private let button = UIButton(configuration: .plain())
  private var trailing: NSLayoutConstraint!
  var onReconnect: (() -> Void)?

  static let height: CGFloat = 44

  override init(frame: CGRect) {
    super.init(frame: frame)
    glass.isGlassShown = true
    glass.cornerConfiguration = .corners(radius: .fixed(Self.height / 2))
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)

    label.textColor = Chrome.UI.fg
    label.numberOfLines = 3
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)

    percent.textColor = Chrome.UI.muted
    percent.setContentHuggingPriority(.required, for: .horizontal)
    percent.setContentCompressionResistancePriority(.required, for: .horizontal)

    dot.backgroundColor = Chrome.UI.bad
    dot.layer.cornerRadius = 3.5

    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = Chrome.UI.fg
    config.background.backgroundColor = Chrome.UI.fill3
    config.cornerStyle = .capsule
    config.contentInsets = .init(top: 0, leading: Chrome.Space.m, bottom: 0, trailing: Chrome.Space.m)
    button.configuration = config
    button.addAction(UIAction { [weak self] _ in self?.onReconnect?() }, for: .primaryActionTriggered)
    applyFonts()
    registerForTraitChanges([ChromeStyleTrait.self]) { (self: Self, _) in self.applyFonts() }

    let stack = UIStackView(arrangedSubviews: [ring, dot, label, percent, button])
    stack.alignment = .center
    stack.spacing = Chrome.Space.s
    stack.setCustomSpacing(Chrome.Space.m, after: percent)
    stack.setCustomSpacing(Chrome.Space.m, after: label)
    stack.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(stack)
    trailing = stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Chrome.Space.l)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      ring.widthAnchor.constraint(equalToConstant: RingView.side),
      ring.heightAnchor.constraint(equalToConstant: RingView.side),
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),
      button.heightAnchor.constraint(equalToConstant: Self.height - 2 * 6),
      stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Chrome.Space.l),
      trailing,
      stack.topAnchor.constraint(greaterThanOrEqualTo: glass.contentView.topAnchor, constant: 6),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: glass.contentView.bottomAnchor, constant: -6),
      stack.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
      heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Text at the Text Size setting; again when it changes.
  private func applyFonts() {
    label.font = Chrome.uiFont(.secondary, .medium)
    percent.font = Chrome.uiMono(.secondary)
    button.configuration?.attributedTitle = AttributedString(
      "Reconnect", attributes: AttributeContainer([.font: Chrome.uiFont(.secondary, .semibold)]))
  }

  /// Shows the banner for `tab`; returns whether it is visible.
  @discardableResult
  func update(for tab: Tab) -> Bool {
    let text: String?
    var notice: Notice?
    if tab.reconnecting {
      text = "Reconnecting…"
    } else if tab.unreachable {
      text = "No contact for \(Self.duration(TimeInterval(tab.current.status.last_heard_ms) / 1000))"
    } else {
      notice = tab.notice
      text = notice?.text
    }
    label.text = text
    dot.isHidden = notice?.failed != true
    button.isHidden = tab.reconnecting || !tab.unreachable
    // The button sits closer to the capsule's end, as concentric as its corners.
    trailing.constant = button.isHidden ? -Chrome.Space.l : -6
    let uploading = notice?.progress != nil
    ring.isHidden = !tab.reconnecting && !uploading
    ring.fraction = tab.reconnecting ? nil : notice?.progress
    percent.isHidden = !uploading
    percent.text = notice?.progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
    isHidden = text == nil
    return !isHidden
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600) h"
  }
}

/// Working, after Controls' ProgressRing: a ring in the text colour filled
/// to the fraction done; with no fraction, an arc that turns.
final class RingView: UIView {
  static let side: CGFloat = 15
  private let track = CAShapeLayer()
  let arc = CAShapeLayer()

  override var isHidden: Bool {
    didSet { update() }
  }

  var fraction: Double? {
    didSet { update() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    for shape in [track, arc] {
      shape.fillColor = nil
      shape.lineWidth = 2
      shape.lineCap = .round
      layer.addSublayer(shape)
    }
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in self.updateColours() }
    updateColours()
    update()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: (min(bounds.width, bounds.height) - 2) / 2,
                            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
    for shape in [track, arc] {
      shape.frame = bounds
      shape.path = path
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    update()
  }

  /// A layer's CGColor does not follow the app theme by itself.
  private func updateColours() {
    track.strokeColor = Chrome.UI.fill3.resolvedColor(with: traitCollection).cgColor
    arc.strokeColor = Chrome.UI.fg.resolvedColor(with: traitCollection).cgColor
  }

  private func update() {
    CATransaction.begin()
    CATransaction.setDisableActions(fraction == nil)
    arc.strokeEnd = max(fraction ?? 0.3, 0.04)
    CATransaction.commit()
    let turning = arc.animation(forKey: "turn") != nil
    let turns = fraction == nil && window != nil && !isHidden
    if turns, !turning {
      let turn = CABasicAnimation(keyPath: "transform.rotation.z")
      turn.byValue = 2 * Double.pi
      turn.duration = 1
      turn.repeatCount = .infinity
      arc.add(turn, forKey: "turn")
    } else if !turns, turning {
      arc.removeAnimation(forKey: "turn")
    }
  }
}
