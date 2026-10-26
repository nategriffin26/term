import UIKit

/// Screens' iPhone toolbar (spec §7) in Term's glass: one row of buttons
/// floating over the bottom of the picture in portrait, a column along the
/// left edge in landscape (Keyboard at the bottom). The Modifiers,
/// Navigation and Edit buttons open a second row above the buttons (right
/// of them in landscape).
@MainActor
final class ScreenToolbar: UIView {
  static let thickness: CGFloat = 50

  /// A column on the left edge rather than a row at the bottom.
  var vertical = false {
    didSet { if vertical != oldValue { setNeedsLayout() } }
  }
  /// A swipe inward that starts on the toolbar: the pointer to that edge of the Mac.
  var onEdgeSwipe: ((ScreenArrangement.Edges) -> Void)?

  private enum Item: CaseIterable {
    case keyboard, escape, modifiers, navigation, edit, commands, password, actions
  }

  private let session: ScreenSession
  private weak var input: ScreenKeyInput?
  private let glass = GlassView()
  private var buttons: [Item: UIButton] = [:]
  private let row = UIView()
  /// The open row's controls in order; nil leaves a gap.
  private var rowItems: [UIView?] = []
  private var shownRow: ScreenRow?
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

  /// Follows the session: the open row, the modifiers' states.
  func update() {
    let open = session.openRow
    for (item, button) in buttons {
      let rowItem: ScreenRow? = switch item {
      case .modifiers: .modifiers
      case .navigation: .navigation
      case .edit: .edit
      default: nil
      }
      button.configuration?.baseForegroundColor = rowItem != nil && rowItem == open ? Chrome.UI.accent : Chrome.UI.fg
    }
    if open != shownRow {
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
    var elements: [UIMenuElement] = []
    if session.sharing != .live, session.phase == .live {
      elements.append(qualityMenu())
    }
    elements.append(clipboard)
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

  /// The host's picture quality: Adaptive follows the connection; the
  /// others hold. Adaptive says which level is in force now.
  private func qualityMenu() -> UIMenu {
    let chosen = session.settings.quality
    let now = session.quality.flatMap { $0.mode == .adaptive ? $0.level.rawValue.capitalized : nil }
    let modes: [(ScreenWire.QualityMode, String)] = [(.adaptive, "Adaptive"), (.high, "High"), (.medium, "Medium"), (.low, "Low")]
    let summary = chosen == .adaptive ? ["Adaptive", now.map { "now \($0)" }].compactMap { $0 }.joined(separator: " · ")
      : modes.first { $0.0 == chosen }?.1
    let menu = UIMenu(title: "Quality", image: UIImage(systemName: "dial.medium"), children: modes.map { mode, title in
      UIAction(title: title, subtitle: mode == .adaptive ? now.map { "Now \($0)" } : nil,
               state: chosen == mode ? .on : .off) { [weak self] _ in
        self?.session.setQuality(mode)
      }
    })
    menu.subtitle = summary
    return menu
  }

  // MARK: Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds
    let t = Self.thickness
    let items = Item.allCases
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
        let size = item == nil ? .zero : CGSize(width: target, height: target)
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
        let size = item == nil ? .zero : CGSize(width: target, height: target)
        item?.frame = CGRect(x: (CGFloat(i) + 0.5) * rowSlot - size.width / 2, y: (t - size.height) / 2,
                             width: size.width, height: size.height)
      }
    }
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
