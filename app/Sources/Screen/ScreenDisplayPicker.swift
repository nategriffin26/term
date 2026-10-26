import UIKit

/// Which of the Mac's displays the picture shows, always in view while the
/// Mac has more than one: All, then each display, as the arrangement in
/// miniature with its name; one tap switches, the current one sits on a fill.
@MainActor
final class ScreenDisplayPicker: UIView {
  static let height: CGFloat = 52
  private static let optionWidth: CGFloat = 76
  private static let padding: CGFloat = 3

  private let session: ScreenSession
  private let glass = GlassView()
  private var options: [DisplayOption] = []
  private var shown: (displays: [ScreenWire.Display], choice: UInt32?)?

  init(session: ScreenSession) {
    self.session = session
    super.init(frame: .zero)
    glass.cornerConfiguration = .corners(radius: .fixed(Self.height / 2))
    glass.isGlassShown = true
    glass.isUserInteractionEnabled = false
    addSubview(glass)
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in
      self.shown = nil
      self.update()
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Wide enough for every option.
  var width: CGFloat { CGFloat(session.hostDisplays.count + 1) * Self.optionWidth + 2 * Self.padding }

  /// Follows the session: its displays and the choice.
  func update() {
    let displays = session.hostDisplays, choice = session.displayChoice
    if let shown, shown.displays == displays, shown.choice == choice { return }
    shown = (displays, choice)
    for option in options { option.removeFromSuperview() }
    options = ([nil] + displays.map(\.id)).map { option($0, choice: choice) }
    for option in options { addSubview(option) }
    setNeedsLayout()
  }

  private func option(_ id: UInt32?, choice: UInt32?) -> DisplayOption {
    let display = id.flatMap { id in session.hostDisplays.first { $0.id == id } }
    let option = DisplayOption(picture: arrangementImage(showing: id, in: CGSize(width: 54, height: 22)),
                               name: display.map(Self.shortName) ?? "All", chosen: id == choice)
    option.addAction(UIAction { [weak self] _ in
      Haptics.selection()
      self?.session.showDisplay(id)
    }, for: .touchUpInside)
    option.accessibilityLabel = display?.name ?? "All Displays"
    return option
  }

  /// "Built-in" for the Mac's own screen ("Built-in Retina Display"), else the name System Settings gives it.
  private static func shortName(_ display: ScreenWire.Display) -> String {
    display.name.hasPrefix("Built-in") ? "Built-in" : display.name
  }

  /// The Mac's displays in their real arrangement and proportions, fitted
  /// to `box`: the ones this option shows filled in the accent, the others outlined.
  private func arrangementImage(showing id: UInt32?, in box: CGSize) -> UIImage {
    let frames = session.hostDisplays.map { ($0.id, $0.frame.cg) }
    let union = frames.map(\.1).reduce(CGRect.null) { $0.union($1) }
    let scale = min(box.width / max(union.width, 1), box.height / max(union.height, 1))
    let size = CGSize(width: (union.width * scale).rounded(.up), height: (union.height * scale).rounded(.up))
    let fill = Chrome.UI.accent.resolvedColor(with: traitCollection)
    let outline = Chrome.UI.fg2.resolvedColor(with: traitCollection)
    return UIGraphicsImageRenderer(size: size).image { _ in
      for (display, frame) in frames {
        // Inset so neighbouring displays keep a gap between them.
        let r = CGRect(x: (frame.minX - union.minX) * scale, y: (frame.minY - union.minY) * scale,
                       width: frame.width * scale, height: frame.height * scale).insetBy(dx: 1, dy: 1)
        if id == nil || id == display {
          fill.setFill()
          UIBezierPath(roundedRect: r, cornerRadius: 2.5).fill()
        } else {
          // Stroked inside its outline, so a shown and a hidden display read the same size.
          let path = UIBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 2)
          path.lineWidth = 1.5
          outline.setStroke()
          path.stroke()
        }
      }
    }.withRenderingMode(.alwaysOriginal)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds
    let p = Self.padding
    let slot = (bounds.width - 2 * p) / CGFloat(max(options.count, 1))
    for (i, option) in options.enumerated() {
      option.frame = CGRect(x: p + CGFloat(i) * slot, y: p, width: slot, height: bounds.height - 2 * p)
      option.layer.cornerRadius = option.frame.height / 2
    }
  }
}

/// One choice: the arrangement in miniature with the choice's displays
/// filled, its short name under it. The current choice sits on a fill.
@MainActor
private final class DisplayOption: UIControl {
  private let picture = UIImageView()
  private let label = UILabel()

  init(picture image: UIImage, name: String, chosen: Bool) {
    super.init(frame: .zero)
    backgroundColor = chosen ? Chrome.UI.fill2 : nil
    layer.cornerCurve = .continuous
    picture.image = image
    picture.contentMode = .center
    label.text = name
    // Pinned like the toolbar's symbols: the picker's height does not follow Text Size.
    label.font = Chrome.uiFont(.caption, chosen ? .semibold : .medium, size: .standard)
    label.textColor = chosen ? Chrome.UI.fg : Chrome.UI.fg2
    label.textAlignment = .center
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.7
    label.lineBreakMode = .byTruncatingTail
    for view in [picture, label] as [UIView] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    isAccessibilityElement = true
    accessibilityTraits = chosen ? [.button, .selected] : .button
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var isHighlighted: Bool {
    didSet { transform = isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let gap: CGFloat = 2
    let pictureHeight = picture.image?.size.height ?? 0
    let labelHeight = label.font.lineHeight.rounded(.up)
    let top = ((bounds.height - pictureHeight - gap - labelHeight) / 2).rounded()
    picture.frame = CGRect(x: 0, y: top, width: bounds.width, height: pictureHeight)
    label.frame = CGRect(x: 6, y: top + pictureHeight + gap, width: bounds.width - 12, height: labelHeight)
  }
}
