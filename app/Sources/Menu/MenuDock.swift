import SwiftUI
import UIKit

/// The menu's tabs as icons in a free strip of the screen (the iPhone Duo
/// inner display's status-bar band, left of the clock). Each icon opens the
/// panel out of itself; the open tab's icon is drawn in the accent.
@MainActor
final class MenuDock: UIView {
  var onTap: ((MenuTab) -> Void)?
  private var buttons: [MenuTab: UIButton] = [:]
  /// Counts on icons (the tmux tab: sessions whose agent stopped for him).
  private var badges: [MenuTab: UILabel] = [:]

  static let itemSize = CGSize(width: 44, height: 44)

  override init(frame: CGRect) {
    super.init(frame: frame)
    for tab in MenuTab.allCases {
      var config = UIButton.Configuration.plain()
      config.image = UIImage(systemName: tab.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
      config.baseForegroundColor = Chrome.UI.fg2
      config.contentInsets = .zero
      let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onTap?(tab) })
      button.accessibilityLabel = tab.title
      button.configurationUpdateHandler = { button in
        button.transform = button.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
      }
      addSubview(button)
      buttons[tab] = button
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var intrinsicContentSize: CGSize {
    CGSize(width: Self.itemSize.width * CGFloat(MenuTab.allCases.count), height: Self.itemSize.height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for (i, tab) in MenuTab.allCases.enumerated() {
      buttons[tab]?.frame = CGRect(origin: CGPoint(x: CGFloat(i) * Self.itemSize.width, y: 0), size: Self.itemSize)
    }
    for (tab, badge) in badges {
      guard let button = buttons[tab] else { continue }
      // On the glyph's top-right corner.
      let width = max(16, badge.intrinsicContentSize.width + 8)
      badge.frame = CGRect(x: button.frame.midX + 13 - width / 2, y: button.frame.midY - 17, width: width, height: 16)
    }
  }

  /// Shows `count` on `tab`'s icon; nothing at zero.
  func setBadge(_ count: Int, on tab: MenuTab) {
    buttons[tab]?.accessibilityValue = count > 0 ? "\(count) new" : nil
    guard count > 0 else {
      badges[tab]?.isHidden = true
      return
    }
    let badge = badges[tab] ?? {
      let label = UILabel()
      label.font = Chrome.uiFont(.caption, .semibold)
      label.textAlignment = .center
      label.layer.cornerRadius = 8
      label.clipsToBounds = true
      label.isUserInteractionEnabled = false
      addSubview(label)
      badges[tab] = label
      return label
    }()
    badge.backgroundColor = Chrome.UI.accent
    badge.textColor = UIColor(Chrome.onAccent)
    badge.text = "\(count)"
    badge.isHidden = false
    setNeedsLayout()
  }

  /// Draws `tab`'s icon in the accent (the open tab), the rest quiet.
  func setSelected(_ tab: MenuTab?) {
    for (t, button) in buttons {
      button.configuration?.baseForegroundColor = t == tab ? Chrome.UI.accent : Chrome.UI.fg2
    }
  }

  /// The icon's glyph area in `space`'s coordinates: where the panel grows from.
  func iconFrame(_ tab: MenuTab, in space: UIView) -> CGRect? {
    guard let button = buttons[tab], !isHidden, window != nil else { return nil }
    let glyph = CGRect(x: 0, y: 0, width: 34, height: 34)
    return button.convert(glyph.offsetBy(dx: (button.bounds.width - 34) / 2, dy: (button.bounds.height - 34) / 2), to: space)
  }
}
