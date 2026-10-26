import UIKit

/// The quiet line at the top of a pane when a remote stops answering, with
/// Reconnect (mosh's "Last contact" bar, made actionable). The core reports
/// UNREACHABLE after 5 s of silence, so the banner shows as soon as it does.
/// Otherwise it carries the tab's notice: an upload's progress (an accent
/// line along its bottom edge) or why it failed (a red dot).
final class StatusBanner: UIView {
  private let label = UILabel()
  private let percent = UILabel()
  private let dot = UIView()
  private let button = UIButton(configuration: .plain())
  private let bar = UIView()
  private var progress: Double?
  private lazy var progressWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
  var onReconnect: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Chrome.UI.raised.withAlphaComponent(0.96)
    layer.cornerRadius = 9
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    clipsToBounds = true
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in self.updateBorder() }
    updateBorder()

    label.font = Chrome.uiFont(.secondary, .medium)
    label.textColor = Chrome.UI.fg2
    label.numberOfLines = 3
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)

    percent.font = Chrome.uiMono(.secondary)
    percent.textColor = Chrome.UI.muted
    percent.setContentHuggingPriority(.required, for: .horizontal)
    percent.setContentCompressionResistancePriority(.required, for: .horizontal)

    dot.backgroundColor = Chrome.UI.bad
    dot.layer.cornerRadius = 3.5
    dot.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString("Reconnect", attributes: AttributeContainer([.font: Chrome.uiFont(.secondary, .medium)]))
    config.baseForegroundColor = Chrome.UI.accent
    config.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 0)
    button.configuration = config
    button.addAction(UIAction { [weak self] _ in self?.onReconnect?() }, for: .primaryActionTriggered)

    bar.backgroundColor = Chrome.UI.accent
    addSubview(bar)

    let stack = UIStackView(arrangedSubviews: [dot, label, percent, button])
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// A layer's CGColor does not follow the app theme by itself.
  private func updateBorder() {
    layer.borderColor = Chrome.UI.line2.resolvedColor(with: traitCollection).cgColor
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let fraction = CGFloat(min(max(progress ?? 0, 0), 1))
    bar.frame = CGRect(x: 0, y: bounds.height - 2, width: bounds.width * fraction, height: 2)
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
    label.textColor = notice?.failed == true ? Chrome.UI.fg : Chrome.UI.fg2
    dot.isHidden = notice?.failed != true
    button.isHidden = tab.reconnecting || !tab.unreachable
    bar.isHidden = notice?.progress == nil
    percent.isHidden = notice?.progress == nil
    percent.text = notice?.progress.map { "\(Int(($0 * 100).rounded(.down)))%" }
    progressWidth.isActive = notice?.progress != nil
    if progress != notice?.progress {
      progress = notice?.progress
      setNeedsLayout()
    }
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
