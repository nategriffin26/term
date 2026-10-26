import SwiftUI
import UIKit

/// The menu's tabs as icons in a free strip of the screen (the iPhone Duo
/// inner display's status-bar band, left of the clock). Each icon opens the
/// panel out of itself; while the panel is open the icons sit on a glass
/// capsule and the open tab's icon is filled in the accent.
@MainActor
final class MenuDock: UIView {
  var onTap: ((MenuTab) -> Void)?
  private let glass = GlassView()
  private var buttons: [MenuTab: UIButton] = [:]
  /// Counts on icons (the tmux tab: sessions whose agent stopped for him).
  private var badges: [MenuTab: DockBadge] = [:]
  private var selected: MenuTab?

  static let itemSize = CGSize(width: Chrome.Size.target, height: Chrome.Size.target)

  override init(frame: CGRect) {
    super.init(frame: frame)
    glass.cornerConfiguration = .capsule()
    glass.isUserInteractionEnabled = false
    addSubview(glass)
    for tab in MenuTab.allCases {
      var config = UIButton.Configuration.plain()
      config.contentInsets = .zero
      let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onTap?(tab) })
      button.accessibilityLabel = tab.title
      button.configurationUpdateHandler = { button in
        button.transform = button.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
      }
      addSubview(button)
      buttons[tab] = button
    }
    drawIcons()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var intrinsicContentSize: CGSize {
    CGSize(width: Self.itemSize.width * CGFloat(MenuTab.allCases.count), height: Self.itemSize.height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds.insetBy(dx: 0, dy: (Chrome.Size.target - Chrome.Size.circle) / 2)
    for (i, tab) in MenuTab.allCases.enumerated() {
      buttons[tab]?.frame = CGRect(origin: CGPoint(x: CGFloat(i) * Self.itemSize.width, y: 0), size: Self.itemSize)
    }
    for (tab, badge) in badges {
      guard let button = buttons[tab] else { continue }
      // On the glyph's top-right corner, its top on the capsule's.
      let size = badge.intrinsicContentSize
      badge.frame = CGRect(x: button.frame.midX + 11 - size.width / 2, y: glass.frame.minY, width: size.width, height: size.height)
    }
  }

  /// Shows `count` on `tab`'s icon; nothing at zero.
  func setBadge(_ count: Int, on tab: MenuTab) {
    buttons[tab]?.accessibilityValue = count > 0 ? "\(count) new" : nil
    let badge = badges[tab] ?? {
      let badge = DockBadge()
      addSubview(badge)
      badges[tab] = badge
      return badge
    }()
    badge.count = count
    setNeedsLayout()
  }

  /// The open tab (nil when the panel is closed): its icon filled in the
  /// accent, the glass under the icons while the panel is open.
  func setSelected(_ tab: MenuTab?) {
    guard tab != selected else { return }
    let opened = (selected == nil) != (tab == nil)
    selected = tab
    drawIcons()
    guard opened else { return }
    let animator = UIViewPropertyAnimator(duration: Chrome.springDuration, timingParameters: Chrome.springTiming)
    animator.addAnimations { self.glass.isGlassShown = tab != nil }
    animator.startAnimation()
  }

  private func drawIcons() {
    for (tab, button) in buttons {
      let on = tab == selected
      button.configuration?.image = UIImage(systemName: on ? tab.selectedSymbol : tab.symbol, withConfiguration: Chrome.uiSymbol(.dock))
      button.configuration?.baseForegroundColor = on ? Chrome.UI.accent : Chrome.UI.fg
      button.accessibilityTraits = on ? [.button, .selected] : .button
    }
  }

  /// The icon's glyph area in `space`'s coordinates: where the panel grows from.
  func iconFrame(_ tab: MenuTab, in space: UIView) -> CGRect? {
    guard let button = buttons[tab], !isHidden, window != nil else { return nil }
    let glyph = CGRect(x: 0, y: 0, width: 34, height: 34)
    return button.convert(glyph.offsetBy(dx: (button.bounds.width - 34) / 2, dy: (button.bounds.height - 34) / 2), to: space)
  }
}

/// The count on a dock icon: sessions whose agent stopped for him.
@MainActor
final class DockBadge: UILabel {
  var count = 0 {
    didSet {
      text = "\(count)"
      isHidden = count == 0
      invalidateIntrinsicContentSize()
    }
  }

  init() {
    super.init(frame: .zero)
    font = Chrome.uiFont(.caption, .bold, size: .standard)  // sized to the dock's glyphs, which stay put
    textAlignment = .center
    backgroundColor = Chrome.UI.accent
    textColor = Chrome.UI.onAccent
    layer.cornerRadius = 8
    clipsToBounds = true
    isUserInteractionEnabled = false
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var intrinsicContentSize: CGSize {
    CGSize(width: max(18, super.intrinsicContentSize.width + 10), height: 16)
  }
}
