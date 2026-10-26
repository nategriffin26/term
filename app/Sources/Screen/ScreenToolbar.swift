import UIKit

/// Screens' iPhone toolbar (spec §7) in Term's glass: one row of buttons
/// floating over the bottom of the picture in portrait, a column along the
/// left edge in landscape (Keyboard at the bottom). The Displays, Modifiers,
/// Navigation and Edit buttons open a second row above the buttons (right
/// of them in landscape).
@MainActor
final class ScreenToolbar: UIView {
  static let thickness: CGFloat = 50

  /// A column on the left edge rather than a row at the bottom.
  var vertical = false {
    didSet {
      guard vertical != oldValue else { return }
      // The Displays row's pictures are drawn for the toolbar's side.
      shownRow = nil
      update()
    }
  }
  /// A swipe inward that starts on the toolbar: the pointer to that edge of the Mac.
  var onEdgeSwipe: ((ScreenArrangement.Edges) -> Void)?

  private enum Item: CaseIterable {
    case keyboard, displays, escape, modifiers, navigation, edit, commands, password, actions
  }

  private let session: ScreenSession
  private weak var input: ScreenKeyInput?
  private let glass = GlassView()
  private var buttons: [Item: UIButton] = [:]
  private let row = UIView()
  /// The open row's controls in order; nil leaves a gap.
  private var rowItems: [UIView?] = []
  private var shownRow: ScreenRow?
  private var shownDisplays: [ScreenWire.Display] = []
  private var shownDisplay: UInt32?
  private var modifierButtons: [(ScreenWire.Modifiers, UIButton, UIView)] = []
  private let repeater = KeyRepeater()
  private var swipeFired = false

  init(session: ScreenSession, input: ScreenKeyInput) {
    self.session = session
    self.input = input
    super.init(frame: .zero)
    glass.cornerConfiguration = .corners(radius: .fixed(Self.thickness / 2))
    glass.isGlassShown = true
    glass.isUserInteractionEnabled = false
    addSubview(glass)
    row.clipsToBounds = true
    addSubview(row)
    makeButtons()
    let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
    swipe.maximumNumberOfTouches = 1
    addGestureRecognizer(swipe)
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in self.restyle() }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  // MARK: Main row

  private func makeButtons() {
    func button(_ item: Item, _ symbol: String, _ label: String, action: (() -> Void)?) -> UIButton {
      let button = Self.symbolButton(symbol, label: label)
      if let action { button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered) }
      buttons[item] = button
      addSubview(button)
      return button
    }
    _ = button(.keyboard, "keyboard", "Keyboard") { [weak self] in self?.session.keyboardUp.toggle() }
    _ = button(.displays, "display.2", "Displays") { [weak self] in self?.toggle(.displays) }
    _ = button(.escape, "escape", "Escape") { [weak self] in
      Haptics.keyDown()
      self?.session.press(MacKey.escape)
    }
    _ = button(.modifiers, "command", "Modifiers") { [weak self] in self?.toggle(.modifiers) }
    _ = button(.navigation, "arrow.up.and.down.and.arrow.left.and.right", "Navigation") { [weak self] in self?.toggle(.navigation) }
    _ = button(.edit, "scissors", "Edit") { [weak self] in self?.toggle(.edit) }

    let commands = button(.commands, "keyboard.badge.ellipsis", "Commands", action: nil)
    commands.menu = commandsMenu()
    commands.showsMenuAsPrimaryAction = true
    commands.preferredMenuElementOrder = .fixed

    let password = button(.password, "key.radiowaves.forward", "Type User Password") { [weak self] in
      self?.session.typePassword(withReturn: true)
    }
    // Touch and hold types it without Return (Screens 5.9.2).
    password.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(passwordHeld(_:))))

    let actions = button(.actions, "slider.horizontal.3", "Actions", action: nil)
    actions.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.actionsMenu() ?? []) }])
    actions.showsMenuAsPrimaryAction = true
    actions.preferredMenuElementOrder = .fixed
  }

  @objc private func passwordHeld(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began else { return }
    Haptics.firm()
    session.typePassword(withReturn: false)
  }

  private func toggle(_ row: ScreenRow) {
    Haptics.selection()
    session.openRow = session.openRow == row ? nil : row
  }

  /// The items on the main row, leading (bottom in landscape) first.
  private var mainItems: [Item] {
    Item.allCases.filter { $0 != .displays || session.displays.count > 1 }
  }

  /// Follows the session: the open row, the modifiers' states, the displays.
  func update() {
    let open = session.openRow
    for (item, button) in buttons {
      let rowItem: ScreenRow? = switch item {
      case .displays: .displays
      case .modifiers: .modifiers
      case .navigation: .navigation
      case .edit: .edit
      default: nil
      }
      button.configuration?.baseForegroundColor = rowItem != nil && rowItem == open ? Chrome.UI.accent : Chrome.UI.fg
    }
    buttons[.displays]?.isHidden = session.displays.count < 2
    if open != shownRow || (open == .displays && (session.displays != shownDisplays || session.settings.display != shownDisplay)) {
      buildRow(open)
    }
    for (key, button, underline) in modifierButtons {
      let state = session.modifiers.state(key)
      let on = state != .off || session.modifiers.hardware.contains(key)
      button.configuration?.baseForegroundColor = on ? Chrome.UI.accent : Chrome.UI.fg
      underline.isHidden = state != .locked
      button.accessibilityValue = switch state {
      case .off: nil
      case .once: "On for the next key"
      case .locked: "Locked"
      }
    }
    setNeedsLayout()
  }

  private func restyle() {
    for (_, button) in buttons { button.setNeedsUpdateConfiguration() }
    shownRow = nil
    update()
  }

  // MARK: Second row

  private func buildRow(_ which: ScreenRow?) {
    for item in rowItems { item?.removeFromSuperview() }
    modifierButtons = []
    shownRow = which
    shownDisplays = session.displays
    shownDisplay = session.settings.display
    rowItems = switch which {
    case nil: []
    case .modifiers:
      [key(MacKey.tab, "arrow.right.to.line", "Tab", repeats: true),
       key(MacKey.returnKey, "return", "Return", repeats: true),
       nil,
       modifier(.shift, "shift", "Shift"),
       modifier(.control, "control", "Control"),
       modifier(.option, "option", "Option"),
       modifier(.command, "command", "Command"),
       modifier(.function, "globe", "Function")]
    case .navigation:
      [key(MacKey.upArrow, "arrow.up", "Up Arrow", repeats: true),
       key(MacKey.downArrow, "arrow.down", "Down Arrow", repeats: true),
       key(MacKey.leftArrow, "arrow.left", "Left Arrow", repeats: true),
       key(MacKey.rightArrow, "arrow.right", "Right Arrow", repeats: true),
       key(MacKey.home, "arrow.left.to.line", "Home", repeats: false),
       key(MacKey.end, "arrow.right.to.line", "End", repeats: false),
       key(MacKey.pageUp, "arrow.up.doc", "Page Up", repeats: true),
       key(MacKey.pageDown, "arrow.down.doc", "Page Down", repeats: true)]
    case .edit:
      [shortcut(MacKey.z, [.command], "arrow.uturn.backward", "Undo"),
       shortcut(MacKey.z, [.command, .shift], "arrow.uturn.forward", "Redo"),
       nil,
       shortcut(MacKey.x, [.command], "scissors", "Cut"),
       shortcut(MacKey.c, [.command], "doc.on.doc", "Copy"),
       pasteControl(),
       nil,
       shortcut(MacKey.a, [.command], "character.textbox", "Select All")]
    case .displays:
      [displayOption(nil)] + session.displays.map { displayOption($0.id) }
    }
    for item in rowItems.compactMap({ $0 }) { row.addSubview(item) }
  }

  private func key(_ code: UInt16, _ symbol: String, _ label: String, repeats: Bool) -> UIView {
    let button = Self.symbolButton(symbol, label: label)
    button.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      Haptics.keyDown()
      session.press(code, consume: false)
      if repeats { repeater.start { [weak self] in self?.session.press(code, consume: false) } }
    }, for: .touchDown)
    button.addAction(UIAction { [weak self] _ in
      self?.repeater.stop()
      self?.session.consumeOnce()
    }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    return button
  }

  private func shortcut(_ code: UInt16, _ modifiers: ScreenWire.Modifiers, _ symbol: String, _ label: String) -> UIView {
    let button = Self.symbolButton(symbol, label: label)
    button.addAction(UIAction { [weak self] _ in
      Haptics.keyDown()
      self?.session.press(code, with: modifiers)
    }, for: .primaryActionTriggered)
    return button
  }

  private func modifier(_ key: ScreenWire.Modifiers, _ symbol: String, _ label: String) -> UIView {
    let button = Self.symbolButton(symbol, label: label)
    button.addAction(UIAction { [weak self] _ in self?.session.tapModifier(key) }, for: .touchDown)
    // A locked key is underlined (§4).
    let underline = UIView()
    underline.backgroundColor = Chrome.UI.accent
    underline.layer.cornerRadius = 1
    underline.isUserInteractionEnabled = false
    underline.isHidden = true
    underline.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(underline)
    NSLayoutConstraint.activate([
      underline.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      underline.widthAnchor.constraint(equalToConstant: 16),
      underline.heightAnchor.constraint(equalToConstant: 2),
      underline.topAnchor.constraint(equalTo: button.centerYAnchor, constant: 13),
    ])
    modifierButtons.append((key, button, underline))
    return button
  }

  /// Apple's paste button: reading the phone's clipboard through it never asks (§6).
  private func pasteControl() -> UIView {
    let config = UIPasteControl.Configuration()
    config.displayMode = .iconOnly
    config.cornerStyle = .capsule
    config.baseForegroundColor = Chrome.UI.fg.resolvedColor(with: traitCollection)
    // The system draws a secure control only on an opaque background.
    config.baseBackgroundColor = Chrome.UI.raised.resolvedColor(with: traitCollection)
    let control = UIPasteControl(configuration: config)
    control.target = input
    return control
  }

  private func displayOption(_ id: UInt32?) -> UIView {
    let chosen = session.settings.display == id
      || (id == nil && !session.displays.contains { $0.id == session.settings.display })
    let display = id.flatMap { id in session.displays.first { $0.id == id } }
    let box = vertical ? CGSize(width: 42, height: 18) : CGSize(width: 64, height: 26)
    let option = DisplayOption(picture: arrangementImage(showing: id, in: box),
                               name: display.map(Self.shortName) ?? "All", chosen: chosen)
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
    let frames = session.displays.map { ($0.id, $0.frame.cg) }
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

  // MARK: Menus

  private func commandsMenu() -> UIMenu {
    func command(_ title: String, _ code: UInt16, _ modifiers: ScreenWire.Modifiers) -> UIAction {
      UIAction(title: title) { [weak self] _ in self?.session.press(code, with: modifiers) }
    }
    let functionKeys = (0..<12).map { i in
      UIAction(title: "F\(i + 1)") { [weak self] _ in self?.session.press(MacKey.functionKeys[i]) }
    }
    return UIMenu(children: [
      command("Mission Control", MacKey.upArrow, .control),
      command("App Windows", MacKey.downArrow, .control),
      command("Spotlight", MacKey.space, .command),
      command("App Switcher", MacKey.tab, .command),
      command("Quit App", MacKey.q, .command),
      command("Force Quit…", MacKey.escape, [.command, .option]),
      UIMenu(title: "Function Keys", children: functionKeys),
    ])
  }

  private func actionsMenu() -> [UIMenuElement] {
    let s = session.settings
    let clipboard = UIMenu(title: "Clipboard", image: UIImage(systemName: "doc.on.clipboard"), children: [
      UIAction(title: "Use Shared Clipboard", state: s.sharedClipboard ? .on : .off) { [weak self] _ in
        self?.session.setSharedClipboard(!s.sharedClipboard)
      },
      UIAction(title: "Send Clipboard") { [weak self] _ in self?.session.sendClipboard() },
      UIAction(title: "Get Clipboard", attributes: session.macClipboard == nil ? .disabled : []) { [weak self] _ in
        self?.session.getClipboard()
      },
    ])
    let cursor = UIMenu(title: "Cursor", image: UIImage(systemName: "cursorarrow"), children: [
      UIAction(title: "Trackpad", state: s.cursorMode == .trackpad ? .on : .off) { [weak self] _ in self?.session.setCursorMode(.trackpad) },
      UIAction(title: "Touch", state: s.cursorMode == .touch ? .on : .off) { [weak self] _ in self?.session.setCursorMode(.touch) },
      UIMenu(title: "Tracking Speed", children: ScreenSettings.speeds.map { speed in
        UIAction(title: speed.formatted() + "×", state: s.trackingSpeed == speed ? .on : .off) { [weak self] _ in
          self?.session.setTrackingSpeed(speed)
        }
      }),
    ])
    var elements: [UIMenuElement] = [clipboard]
    if session.displays.count > 1 {
      let current = session.shownDisplays.count == 1 ? session.shownDisplays.first?.id : nil
      elements.append(UIMenu(title: "Display", image: UIImage(systemName: "display.2"), children:
        [UIAction(title: "All Displays", state: current == nil ? .on : .off) { [weak self] _ in self?.session.showDisplay(nil) }]
        + session.displays.map { display in
          UIAction(title: display.name, state: current == display.id ? .on : .off) { [weak self] _ in
            self?.session.showDisplay(display.id)
          }
        }))
    }
    elements += [
      cursor,
      UIAction(title: "Type User Password", image: UIImage(systemName: "key.radiowaves.forward")) { [weak self] _ in
        self?.session.typePassword(withReturn: true)
      },
      UIMenu(options: .displayInline, children: [
        UIAction(title: "Disconnect", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
          self?.session.disconnect()
        },
      ]),
    ]
    return elements
  }

  // MARK: Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds
    let t = Self.thickness
    let items = mainItems
    let target = Chrome.Size.target
    if vertical {
      let slot = bounds.height / CGFloat(max(items.count, 1))
      for (i, item) in items.enumerated() {
        let y = bounds.height - (CGFloat(i) + 0.5) * slot
        buttons[item]?.frame = CGRect(x: (t - target) / 2, y: y - target / 2, width: target, height: target)
      }
      row.frame = CGRect(x: t, y: 0, width: max(0, bounds.width - t), height: bounds.height)
      let rowSlot = row.bounds.height / CGFloat(max(rowItems.count, 1))
      for (i, item) in rowItems.enumerated() {
        let size = item.map { slotSize($0) } ?? .zero
        item?.frame = CGRect(x: (t - size.width) / 2, y: (CGFloat(i) + 0.5) * rowSlot - size.height / 2,
                             width: size.width, height: size.height)
      }
    } else {
      let slot = bounds.width / CGFloat(max(items.count, 1))
      for (i, item) in items.enumerated() {
        let x = (CGFloat(i) + 0.5) * slot
        buttons[item]?.frame = CGRect(x: x - target / 2, y: bounds.height - t + (t - target) / 2, width: target, height: target)
      }
      row.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - t))
      let rowSlot = row.bounds.width / CGFloat(max(rowItems.count, 1))
      for (i, item) in rowItems.enumerated() {
        let size = item.map { slotSize($0) } ?? .zero
        item?.frame = CGRect(x: (CGFloat(i) + 0.5) * rowSlot - size.width / 2, y: (t - size.height) / 2,
                             width: size.width, height: size.height)
      }
    }
  }

  private func slotSize(_ view: UIView) -> CGSize {
    guard shownRow == .displays else { return CGSize(width: Chrome.Size.target, height: Chrome.Size.target) }
    if vertical { return CGSize(width: Self.thickness - 2, height: Self.thickness - 2) }
    let slot = row.bounds.width / CGFloat(max(rowItems.count, 1))
    return CGSize(width: min(84, slot - Chrome.Space.xs), height: Self.thickness - 2)
  }

  @objc private func swiped(_ g: UIPanGestureRecognizer) {
    if g.state == .began { swipeFired = false }
    guard g.state == .changed, !swipeFired else { return }
    let t = g.translation(in: self)
    if vertical, t.x > 24, t.x > abs(t.y) {
      swipeFired = true
      onEdgeSwipe?(.left)
    } else if !vertical, t.y < -24, -t.y > abs(t.x) {
      swipeFired = true
      onEdgeSwipe?(.bottom)
    }
  }

  // MARK: Buttons

  private static func symbolButton(_ symbol: String, label: String) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.contentInsets = .zero
    config.image = UIImage(systemName: symbol, withConfiguration: Chrome.uiSymbol(.dock, size: .standard))
    config.baseForegroundColor = Chrome.UI.fg
    let button = UIButton(configuration: config)
    button.accessibilityLabel = label
    button.configurationUpdateHandler = { button in
      button.transform = button.isHighlighted ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
    }
    return button
  }
}

/// One choice in the Displays row: the arrangement in miniature with the
/// choice's displays filled, its short name under it. The current choice sits on a fill.
@MainActor
private final class DisplayOption: UIControl {
  private let picture = UIImageView()
  private let label = UILabel()

  init(picture image: UIImage, name: String, chosen: Bool) {
    super.init(frame: .zero)
    backgroundColor = chosen ? Chrome.UI.fill2 : nil
    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    picture.image = image
    picture.contentMode = .center
    label.text = name
    // Pinned like the toolbar's symbols: the row's height does not follow Text Size.
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
    let gap: CGFloat = 3
    let pictureHeight = picture.image?.size.height ?? 0
    let labelHeight = label.font.lineHeight.rounded(.up)
    let top = ((bounds.height - pictureHeight - gap - labelHeight) / 2).rounded()
    picture.frame = CGRect(x: 0, y: top, width: bounds.width, height: pictureHeight)
    label.frame = CGRect(x: 3, y: top + pictureHeight + gap, width: bounds.width - 6, height: labelHeight)
  }
}
