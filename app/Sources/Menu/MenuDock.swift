import UIKit

/// The menu's tabs as icons in a free strip of the screen (the iPhone Duo
/// inner display's status-bar band, left of the clock). Each icon opens the
/// panel out of itself; the open tab's icon is drawn in the accent.
@MainActor
final class MenuDock: UIView {
  var onTap: ((MenuTab) -> Void)?
  private var buttons: [MenuTab: UIButton] = [:]

  static let itemSize = CGSize(width: 44, height: 44)

  override init(frame: CGRect) {
    super.init(frame: frame)
    for tab in MenuTab.allCases {
      var config = UIButton.Configuration.plain()
      config.image = UIImage(systemName: tab.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
      config.baseForegroundColor = Helm.UI.fg2
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
  }

  /// Draws `tab`'s icon in the accent (the open tab), the rest quiet.
  func setSelected(_ tab: MenuTab?) {
    for (t, button) in buttons {
      button.configuration?.baseForegroundColor = t == tab ? Helm.UI.accent : Helm.UI.fg2
    }
  }

  /// The icon's glyph area in `space`'s coordinates: where the panel grows from.
  func iconFrame(_ tab: MenuTab, in space: UIView) -> CGRect? {
    guard let button = buttons[tab], !isHidden, window != nil else { return nil }
    let glyph = CGRect(x: 0, y: 0, width: 34, height: 34)
    return button.convert(glyph.offsetBy(dx: (button.bounds.width - 34) / 2, dy: (button.bounds.height - 34) / 2), to: space)
  }
}
