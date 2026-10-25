import UIKit

/// The quiet line at the top of a pane when a remote stops answering, with
/// Reconnect (mosh's "Last contact" bar, made actionable). The core reports
/// UNREACHABLE after 5 s of silence, so the banner shows as soon as it does.
final class StatusBanner: UIView {
  private let label = UILabel()
  private let button = UIButton(configuration: .plain())
  var onReconnect: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor(white: 0.12, alpha: 0.92)
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous

    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = UIColor(white: 0.85, alpha: 1)
    label.adjustsFontForContentSizeCategory = true

    var config = UIButton.Configuration.plain()
    config.title = "Reconnect"
    config.baseForegroundColor = .systemBlue
    config.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 8)
    button.configuration = config
    button.addAction(UIAction { [weak self] _ in self?.onReconnect?() }, for: .primaryActionTriggered)

    let stack = UIStackView(arrangedSubviews: [label, button])
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Shows the banner for `tab`; returns whether it is visible.
  @discardableResult
  func update(for tab: Tab) -> Bool {
    let text: String?
    if tab.reconnecting {
      text = "Reconnecting…"
    } else if tab.unreachable {
      text = "No contact for \(Self.duration(TimeInterval(tab.current.status.last_heard_ms) / 1000))"
    } else {
      text = nil
    }
    label.text = text
    button.isHidden = tab.reconnecting
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
