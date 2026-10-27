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
    let duration = tab != nil ? Chrome.Panel.open : Chrome.Panel.close
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: Chrome.Panel.spring(duration))
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

/// The count on an item of the system's vertical bar (the tmux icon). The bar
/// draws an item's own badge only when it builds the bar, so the count is a
/// label laid over the bar on the icon's corner. The bar moves and springs its
/// items itself (rotation, keyboard, overflow) and says nothing, so the label
/// reads the icon's position on every frame until the icon has come to rest.
@MainActor
final class BarBadge {
  let label = DockBadge()
  private let host: () -> UIView?
  private let itemFrame: (UIView) -> CGRect?
  private var link: CADisplayLink?
  private var lastItem: CGRect?
  private var framesAtRest = 0
  private static let restFrames = 15

  /// True while it is reading the icon's position every frame.
  var isFollowing: Bool { link != nil }

  var count: Int {
    get { label.count }
    set {
      label.count = newValue
      follow()
    }
  }

  /// `host` is the view the label lies over (nil while the bar is not shown);
  /// `itemFrame` is the icon's frame in it (nil while the bar has none).
  init(host: @escaping () -> UIView?, itemFrame: @escaping (UIView) -> CGRect?) {
    self.host = host
    self.itemFrame = itemFrame
    // Above the bar however UIKit orders the bar's views.
    label.layer.zPosition = 1000
  }

  isolated deinit { link?.invalidate() }

  /// On the glyph's top-right corner, its top just above the icon's.
  static func frame(onCornerOf item: CGRect, size: CGSize) -> CGRect {
    CGRect(x: item.midX + 11 - size.width / 2, y: item.minY - 2, width: size.width, height: size.height)
  }

  /// The bar may have moved its items: place the label now and keep placing it until they stop.
  func follow() {
    framesAtRest = 0
    lastItem = place()
    guard link == nil, label.count > 0 else { return }
    let ticker = Ticker { [weak self] in self?.tick() }
    let link = CADisplayLink(target: ticker, selector: #selector(Ticker.fire))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func tick() {
    let item = place()
    if item == lastItem { framesAtRest += 1 } else { framesAtRest = 0 }
    lastItem = item
    if framesAtRest >= Self.restFrames || label.count == 0 {
      link?.invalidate()
      link = nil
    }
  }

  /// Puts the label on the icon, or hides it while there is no icon to put it on. Returns the icon's frame.
  private func place() -> CGRect? {
    guard label.count > 0, let host = host(), let item = itemFrame(host), item.width > 0 else {
      label.isHidden = true
      return nil
    }
    if label.superview !== host { host.addSubview(label) }
    label.frame = Self.frame(onCornerOf: item, size: label.intrinsicContentSize)
    label.isHidden = false
    return item
  }

  private final class Ticker: NSObject {
    let onFire: () -> Void
    init(_ onFire: @escaping () -> Void) { self.onFire = onFire }
    @objc func fire() { onFire() }
  }
}
