import UIKit

/// The key bar above the software keyboard: a glass capsule over the
/// terminal, after Blink's iPhone bar (KBLayout.iPhone). Esc, Ctrl, Alt,
/// Tab and the mic on the left (the mic away from the arrows, so a thumb on
/// them never starts dictation); the arrow joystick, hide-keyboard and Cmd
/// on the right. The middle shows the voice strip while dictation is busy.
/// Cmd swaps Tab, the mic and the middle for its own row: the system paste
/// control, then photo, camera and file keys that upload to the host and
/// type the path.
@MainActor
final class SmartKeysBar: UIInputView, UIInputViewAudioFeedback {
    enum Action {
        case key(TermKey)
        case hideKeyboard
        case insert(InsertSource)
        case voice
    }

    enum Key {
        case escape, tab
        case ctrl, alt
        case arrows
        case hideKeyboard
        case command
    }

    private static let left: [Key] = [.escape, .ctrl, .alt]
    /// Give way to the Cmd row while Cmd is on, with the voice strip after them.
    private static let middle: [Key] = [.tab]
    private static let right: [Key] = [.arrows, .hideKeyboard, .command]

    enum Modifier { case off, armed, locked }

    private(set) var ctrl = Modifier.off { didSet { refresh() } }
    private(set) var alt = Modifier.off { didSet { refresh() } }
    /// Cmd swaps the arrow joystick for Home / PgDn / PgUp / End, and the
    /// middle for the Cmd row; v and c on the keyboard paste and copy.
    private(set) var command = false { didSet { refresh() } }

    var activeMods: UInt32 {
        (ctrl != .off ? UInt32(TERM_MOD_CTRL) : 0) | (alt != .off ? UInt32(TERM_MOD_ALT) : 0)
    }

    /// Releases one-shot modifiers after a key used them; locked ones stay.
    func consumeModifiers() {
        if ctrl == .armed { ctrl = .off }
        if alt == .armed { alt = .off }
    }

    /// After a Cmd shortcut, as a one-shot modifier would.
    func releaseCommand() {
        if command { command = false }
    }

    private weak var terminal: TerminalView?
    var enableInputClicksWhenVisible: Bool { terminal?.keyClicksEnabled ?? true }
    private let glass = GlassView()
    private var leftKeys: [KeyCap] = []
    private var rightKeys: [KeyCap] = []
    /// Tab and the voice strip (which holds the mic key); faded out for the Cmd row.
    private let middle = UIView()
    private var middleKeys: [KeyCap] = []
    private let strip = VoiceStripView()
    private let commandRow = UIView()
    private var pasteControl: UIPasteControl
    private var insertKeys: [KeyCap] = []
    private var lastCommandTap: CFTimeInterval = 0

    /// The bar's height: the glass capsule plus a margin above and below it.
    static let height: CGFloat = 52
    /// Where the phone is on its side.
    private static let compactHeight: CGFloat = 46
    static func height(for traits: UITraitCollection) -> CGFloat {
        traits.verticalSizeClass == .compact ? compactHeight : height
    }
    /// The capsule's inset from the bar's edges.
    private static let capsuleInset = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    init(terminal: TerminalView) {
        self.terminal = terminal
        pasteControl = Self.makePasteControl(for: UITraitCollection.current)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: SmartKeysBar.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        glass.isGlassShown = true
        glass.cornerConfiguration = .capsule()
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        leftKeys = Self.left.map(makeKey)
        middleKeys = Self.middle.map(makeKey)
        rightKeys = Self.right.map(makeKey)
        leftKeys.forEach(addSubview)
        rightKeys.forEach(addSubview)
        middleKeys.forEach(middle.addSubview)
        strip.onMic = { [weak self] in self?.emit(.voice) }
        strip.onRetry = { Dictation.shared.retry() }
        strip.onOpenSettings = { [weak terminal] in terminal?.dictationNeedsSettings() }
        strip.onDiscard = { Dictation.shared.discard() }
        middle.addSubview(strip)
        addSubview(middle)
        pasteControl.target = terminal
        commandRow.addSubview(pasteControl)
        insertKeys = [("photo", "Insert Photo or Video", InsertSource.photos), ("camera", "Insert from Camera", .camera),
                      ("folder", "Insert File", .files)]
            .filter { $0.2 != .camera || Inserter.hasCamera }
            .map { symbol, label, source in
                let cap = KeyCap()
                cap.configure(symbol: symbol)
                cap.accessibilityLabel = label
                cap.onTap = { [weak self] in
                    self?.command = false
                    self?.emit(.insert(source))
                }
                return cap
            }
        insertKeys.forEach(commandRow.addSubview)
        commandRow.isHidden = true
        commandRow.alpha = 0
        addSubview(commandRow)
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (bar: SmartKeysBar, _: UITraitCollection) in
            bar.invalidateIntrinsicContentSize()
        }
        registerForTraitChanges([AppThemeTrait.self]) { (bar: SmartKeysBar, _: UITraitCollection) in
            bar.replacePasteControl()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(voiceChanged), name: .voiceStateChanged, object: nil)
        refresh()
        voiceChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height(for: traitCollection))
    }

    /// The system's own paste button: reads the clipboard without the
    /// "Allow Paste" prompt and hands it to the terminal's paste(itemProviders:).
    /// Its colours are fixed when it is made, so a new theme gets a new one,
    /// and the system draws it only on an opaque ground: the wash laid over the theme's.
    private static func makePasteControl(for traits: UITraitCollection) -> UIPasteControl {
        var g = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0)), w = g
        Chrome.UI.bg.resolvedColor(with: traits).getRed(&g.r, green: &g.g, blue: &g.b, alpha: &g.a)
        Chrome.UI.fill3.resolvedColor(with: traits).getRed(&w.r, green: &w.g, blue: &w.b, alpha: &w.a)
        func over(_ x: CGFloat, _ y: CGFloat) -> CGFloat { y + (x - y) * w.a }
        let paste = UIPasteControl.Configuration()
        paste.displayMode = .iconOnly
        paste.cornerStyle = .capsule
        paste.baseForegroundColor = Chrome.UI.fg.resolvedColor(with: traits)
        paste.baseBackgroundColor = UIColor(red: over(w.r, g.r), green: over(w.g, g.g), blue: over(w.b, g.b), alpha: 1)
        return UIPasteControl(configuration: paste)
    }

    private func replacePasteControl() {
        let next = Self.makePasteControl(for: traitCollection)
        next.target = terminal
        next.frame = pasteControl.frame
        commandRow.insertSubview(next, aboveSubview: pasteControl)
        pasteControl.removeFromSuperview()
        pasteControl = next
    }

    // ------------------------------------------------------------ layout

    /// Slot widths, each key's whole touch target; a wide bar (iPhone Duo's
    /// inner display, a phone on its side) gets roomier slots.
    private func width(of key: Key) -> CGFloat {
        let roomy = bounds.width >= 600
        switch key {
        case .arrows, .hideKeyboard, .command: return roomy ? 60 : 40
        case .escape, .ctrl, .alt: return roomy ? 46 : 40
        case .tab: return roomy ? 46 : 36
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let capsule = bounds.inset(by: UIEdgeInsets(top: Self.capsuleInset.top, left: safeAreaInsets.left + Self.capsuleInset.left,
                                                    bottom: Self.capsuleInset.bottom, right: safeAreaInsets.right + Self.capsuleInset.right))
        glass.frame = capsule
        // Keys keep the bar's full height as their target; the outer ones
        // start a little inside the capsule's rounded ends.
        var x = capsule.minX + Chrome.Space.s
        for (key, view) in zip(Self.left, leftKeys) {
            view.frame = CGRect(x: x, y: 0, width: width(of: key), height: h)
            x += view.frame.width
        }
        let middleStart = x
        var right = capsule.maxX - Chrome.Space.s
        for (key, view) in zip(Self.right, rightKeys).reversed() {
            right -= width(of: key)
            view.frame = CGRect(x: right, y: 0, width: width(of: key), height: h)
        }
        middle.frame = CGRect(x: middleStart, y: 0, width: max(0, right - middleStart), height: h)
        var mx: CGFloat = 0
        for (key, view) in zip(Self.middle, middleKeys) {
            view.frame = CGRect(x: mx, y: 0, width: width(of: key), height: h)
            mx += view.frame.width
        }
        // The mic key, drawn by the strip, is as wide as esc.
        strip.micWidth = width(of: .escape)
        strip.frame = CGRect(x: mx, y: 0, width: max(0, middle.bounds.width - mx), height: h)
        commandRow.frame = middle.frame
        let slots = CGFloat(1 + insertKeys.count)
        let slot = min(bounds.width >= 600 ? 56 : 44, commandRow.bounds.width / slots).rounded(.down)
        // A circle button; the system won't draw its paste control much smaller.
        let side = min(Chrome.Size.circle, h - 12)
        pasteControl.frame = CGRect(x: (slot - side) / 2, y: (h - side) / 2, width: side, height: side)
        for (i, cap) in insertKeys.enumerated() {
            cap.frame = CGRect(x: slot * CGFloat(i + 1), y: 0, width: slot, height: h)
        }
    }

    // ------------------------------------------------------------ keys

    private func makeKey(_ key: Key) -> KeyCap {
        let cap = KeyCap()
        switch key {
        case .escape:
            cap.configure(title: "esc")
            cap.repeats = true
            cap.onTap = { [weak self] in self?.emit(.key(TERM_KEY_ESCAPE)) }
        case .tab:
            cap.configure(title: "tab")
            cap.repeats = true
            cap.onTap = { [weak self] in self?.emit(.key(TERM_KEY_TAB)) }
        case .ctrl:
            cap.configure(title: "ctrl")
            cap.onTap = { [weak self] in self?.ctrl = self?.ctrl == .off ? .armed : .off }
            cap.onHold = { [weak self] in self?.ctrl = .locked }
        case .alt:
            cap.configure(title: "alt")
            cap.onTap = { [weak self] in self?.alt = self?.alt == .off ? .armed : .off }
            cap.onHold = { [weak self] in self?.alt = .locked }
        case .arrows:
            cap.configureArrows()
            cap.accessibilityLabel = "Arrows"
            cap.onArrow = { [weak self] direction in
                guard let self else { return }
                let keys: [TermKey] = command
                    ? [TERM_KEY_HOME, TERM_KEY_PAGE_DOWN, TERM_KEY_PAGE_UP, TERM_KEY_END]
                    : [TERM_KEY_LEFT, TERM_KEY_DOWN, TERM_KEY_UP, TERM_KEY_RIGHT]
                emit(.key(keys[direction]))
            }
        case .hideKeyboard:
            cap.configure(symbol: "keyboard.chevron.compact.down",
                          configuration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            cap.accessibilityLabel = "Hide Keyboard"
            cap.onTap = { [weak self] in self?.emit(.hideKeyboard) }
        case .command:
            cap.configure(symbol: "command")
            cap.accessibilityLabel = "Command"
            cap.onTap = { [weak self] in self?.commandTapped() }
        }
        return cap
    }

    private func emit(_ action: Action) {
        terminal?.smartKey(action)
    }

    /// One tap toggles the alternate cursor keys; a double tap toggles the
    /// menu panel (Blink's double-Cmd).
    private func commandTapped() {
        let now = CACurrentMediaTime()
        command.toggle()
        if now - lastCommandTap < 0.35 {
            lastCommandTap = 0
            UIApplication.shared.sendAction(Selector(("toggleMenu:")), to: nil, from: self, for: nil)
        } else {
            lastCommandTap = now
        }
    }

    /// The strip (and its mic key) follows dictation.
    @objc private func voiceChanged() {
        strip.state = Dictation.shared.state
        strip.note = Dictation.shared.note
    }

    private func refresh() {
        for (key, view) in zip(Self.left + Self.right, leftKeys + rightKeys) {
            switch key {
            case .ctrl: view.modifier = ctrl
            case .alt: view.modifier = alt
            case .command: view.modifier = command ? .armed : .off
            case .arrows: view.alternateArrows = command
            default: break
            }
        }
        let row = command
        guard commandRow.isHidden == row else { return }
        middle.isUserInteractionEnabled = !row
        commandRow.isHidden = false
        UIView.animate(withDuration: 0.12) {
            self.middle.alpha = row ? 0 : 1
            self.commandRow.alpha = row ? 1 : 0
        } completion: { _ in
            self.commandRow.isHidden = !self.command
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Modifiers armed before the keyboard went away should not linger.
        if window == nil {
            ctrl = .off
            alt = .off
        }
    }
}

/// One key: a label on the glass, a capsule plate only while pressed (a
/// wash) or while a modifier is on (the text colour, the label in the
/// ground). Reports taps, holds and joystick directions.
final class KeyCap: UIView {
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    /// Holding the key repeats it at the Key Repeat settings (the joystick always does).
    var repeats = false
    /// Joystick: 0 left, 1 down, 2 up, 3 right.
    var onArrow: ((Int) -> Void)?

    var modifier = SmartKeysBar.Modifier.off { didSet { updateLook() } }
    var alternateArrows = false { didSet { updateArrowSymbols() } }

    private let plate = UIView()
    private let title = UILabel()
    private let lockBar = UIView()
    private var icon: UIImageView?
    /// The joystick's four arrows (left, down, up, right), each lit on its own.
    private var arrows: [UIImageView] = []
    private var pressed = false { didSet { updateLook() } }
    private var holdTimer: Timer?
    private var held = false
    private var direction: Int?
    private let repeater = KeyRepeater()

    /// The plate's height in a bar `height` tall: 32 in portrait, 26 on its side.
    static func plateHeight(in height: CGFloat) -> CGFloat { height - 20 }

    init() {
        super.init(frame: .zero)
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        plate.layer.cornerCurve = .continuous
        plate.isUserInteractionEnabled = false
        addSubview(plate)
        title.textAlignment = .center
        title.isUserInteractionEnabled = false
        addSubview(title)
        lockBar.layer.cornerRadius = 1
        lockBar.isHidden = true
        addSubview(lockBar)
        registerForTraitChanges([AppThemeTrait.self]) { (cap: KeyCap, _: UITraitCollection) in cap.updateLook() }
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title text: String) {
        title.text = text
        accessibilityLabel = text
        setNeedsLayout()
    }

    /// `configuration` replaces the bar's symbol size (hide-keyboard keeps Blink's 16 pt glyph).
    func configure(symbol: String, configuration: UIImage.SymbolConfiguration? = nil) {
        let view = UIImageView(image: UIImage(systemName: symbol,
                                              withConfiguration: configuration ?? Chrome.uiSymbol(.control, size: .standard)))
        view.contentMode = .center
        view.isUserInteractionEnabled = false
        icon = view
        addSubview(view)
        updateLook()
    }

    /// Swaps a symbol key's glyph (the mic fills while it listens).
    func setSymbol(_ symbol: String) {
        icon?.image = UIImage(systemName: symbol, withConfiguration: Chrome.uiSymbol(.control, size: .standard))
    }

    func configureArrows() {
        arrows = (0..<4).map { _ in
            let view = UIImageView()
            view.contentMode = .center
            view.isUserInteractionEnabled = false
            addSubview(view)
            return view
        }
        updateArrowSymbols()
        updateLook()
    }

    /// Blink's joystick: four small arrows, or with Cmd arrows against a bar (Home/PgUp/…).
    private func updateArrowSymbols() {
        guard arrows.count == 4 else { return }
        let names = alternateArrows
            ? ["arrow.left.to.line", "arrow.down.to.line", "arrow.up.to.line", "arrow.right.to.line"]
            : ["arrow.left", "arrow.down", "arrow.up", "arrow.right"]
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        for (view, name) in zip(arrows, names) { view.image = UIImage(systemName: name, withConfiguration: config) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let plateHeight = KeyCap.plateHeight(in: bounds.height)
        let content: CGFloat = icon != nil ? Chrome.SymbolStep.control.rawValue : title.intrinsicContentSize.width
        let plateWidth = max(plateHeight, content + 2 * 9)
        plate.bounds = CGRect(x: 0, y: 0, width: plateWidth, height: plateHeight)
        plate.center = center
        plate.layer.cornerRadius = plateHeight / 2
        title.bounds = CGRect(x: 0, y: 0, width: max(bounds.width, plateWidth), height: 22)
        title.center = center
        lockBar.frame = CGRect(x: center.x - 6, y: plate.frame.maxY - 5, width: 12, height: 2)
        icon?.frame = CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)
        // Blink's joystick: four small arrows around the middle, spread as on its 40 pt key.
        let spread = CGPoint(x: (bounds.width - 2) * 0.27, y: 40 * 0.22)
        let offsets = [CGPoint(x: -spread.x, y: 0), CGPoint(x: 0, y: spread.y),
                       CGPoint(x: 0, y: -spread.y), CGPoint(x: spread.x, y: 0)]
        for (view, offset) in zip(arrows, offsets) {
            view.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
            view.center = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        }
    }

    private func updateLook() {
        let on = modifier != .off
        plate.backgroundColor = on ? Chrome.UI.fg : pressed && arrows.isEmpty ? Chrome.UI.fill3 : .clear
        let ink = on ? Chrome.UI.bg : Chrome.UI.fg
        title.textColor = ink
        title.font = Chrome.uiFont(.title, on ? .semibold : .regular, size: .standard)
        lockBar.backgroundColor = Chrome.UI.bg
        lockBar.isHidden = modifier != .locked
        icon?.tintColor = on ? ink : Chrome.UI.fg
        for (i, view) in arrows.enumerated() {
            let lit = direction == nil || direction == i
            view.tintColor = Chrome.UI.fg.withAlphaComponent(lit ? 1 : 0.35)
        }
        setNeedsLayout()
    }

    // ------------------------------------------------------------ touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        pressed = true
        held = false
        UIDevice.current.playInputClick()
        Haptics.keyDown()
        if onArrow != nil {
            aim(at: t.location(in: self))
        } else if onHold != nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.held = true
                    UIDevice.current.playInputClick()
                    Haptics.firm()
                    self.onHold?()
                }
            }
        } else if repeats {
            repeater.start { [weak self] in
                guard let self else { return }
                UIDevice.current.playInputClick()
                self.onTap?()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, onArrow != nil else { return }
        aim(at: t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let arrow = direction
        let fired = repeater.hasFired
        finish()
        if let onArrow {
            if let arrow, !fired { onArrow(arrow) }
        } else if !held, !fired {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish()
    }

    private func finish() {
        pressed = false
        holdTimer?.invalidate()
        holdTimer = nil
        repeater.stop()
        direction = nil
        updateLook()
        UIView.animate(withDuration: 0.15) { self.layoutSubviews() }
    }

    /// Blink's joystick: the direction from the key's middle picks the
    /// arrow (none in a small dead zone); holding repeats at the Key Repeat
    /// settings, faster the farther the finger travels.
    private func aim(at p: CGPoint) {
        let key = bounds
        let dx = p.x - key.midX, dy = p.y - key.midY
        let next: Int?
        if abs(dx) < key.width * 0.2 && abs(dy) < key.height * 0.15 {
            next = nil
        } else if abs(dx) > abs(dy) {
            next = dx < 0 ? 0 : 3
        } else {
            next = dy > 0 ? 1 : 2
        }
        var speed = 1.0
        if abs(dx) > key.width * 0.9 || abs(dy) > key.height * 3 { speed = 1.25 }
        if abs(dx) > key.width * 2 || abs(dy) > key.height * 4 { speed = 2 }
        repeater.speed = speed
        guard next != direction else { return }
        direction = next
        updateLook()
        repeater.stop()
        guard next != nil else { return }
        repeater.start { [weak self] in
            guard let self, let d = self.direction else { return }
            UIDevice.current.playInputClick()
            self.onArrow?(d)
        }
    }
}
