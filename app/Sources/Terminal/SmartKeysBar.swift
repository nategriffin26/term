import UIKit

/// The key bar above the software keyboard: a glass capsule over the
/// terminal, after Blink's iPhone bar (KBLayout.iPhone). Esc/Ctrl/Alt on the
/// left; a scrolling middle of Tab, symbol pairs and F-keys (pull a pair
/// down for its upper symbol); the arrow joystick, hide-keyboard and Cmd on
/// the right. Cmd swaps the middle for its own row: the system paste
/// control, then photo, camera and file keys that upload to the host and
/// type the path.
@MainActor
final class SmartKeysBar: UIInputView, UIInputViewAudioFeedback {
    enum Action {
        case key(TermKey)
        case text(String)
        case hideKeyboard
        case insert(InsertSource)
    }

    enum Key {
        case escape, tab
        case ctrl, alt
        case pair(String, String)       // tap: first, pull down: second
        case function(Int, Int)         // tap: F first, pull down: F second
        case arrows
        case hideKeyboard
        case command
    }

    struct Layout {
        var left: [Key]
        var middle: [Key]
        var right: [Key]

        static let standard = Layout(
            left: [.escape, .ctrl, .alt],
            middle: [.tab]
                + [("`", "~"), ("@", "#"), ("$", "^"), (";", ":"), ("-", "_"), ("=", "+"), ("[", "{"), ("]", "}"),
                   ("\\", "|"), ("<", "*"), (">", "\""), ("/", "?"), (".", "!"), (",", "%")].map { Key.pair($0.0, $0.1) }
                + (1...6).map { Key.function($0, $0 + 6) },
            right: [.arrows, .hideKeyboard, .command])
    }

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
    private let layout: Layout
    private let glass = GlassView()
    private var leftKeys: [KeyCap] = []
    private var rightKeys: [KeyCap] = []
    private var middleKeys: [KeyCap] = []
    /// Holds the scroller; its mask fades the keys out at a side with more keys past it.
    private let middle = UIView()
    private let edgeFade = CAGradientLayer()
    private let scroller = HorizontalScroller()
    private let commandRow = UIView()
    private var pasteControl: UIPasteControl
    private var insertKeys: [KeyCap] = []
    private var lastCommandTap: CFTimeInterval = 0

    /// The bar's height: the glass capsule plus a margin above and below it.
    static let height: CGFloat = 52
    /// Where the phone is on its side.
    private static let compactHeight: CGFloat = 46
    private var barHeight: CGFloat { traitCollection.verticalSizeClass == .compact ? Self.compactHeight : Self.height }
    /// The capsule's inset from the bar's edges.
    private static let capsuleInset = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    init(terminal: TerminalView, layout: Layout = .standard) {
        self.terminal = terminal
        self.layout = layout
        pasteControl = Self.makePasteControl(for: UITraitCollection.current)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: SmartKeysBar.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        glass.isGlassShown = true
        glass.cornerConfiguration = .capsule()
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        scroller.showsHorizontalScrollIndicator = false
        scroller.delaysContentTouches = false
        scroller.canCancelContentTouches = true
        scroller.alwaysBounceHorizontal = true
        scroller.delegate = self
        middle.addSubview(scroller)
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        middle.layer.mask = edgeFade
        addSubview(middle)
        leftKeys = layout.left.map(makeKey)
        middleKeys = layout.middle.map(makeKey)
        rightKeys = layout.right.map(makeKey)
        leftKeys.forEach(addSubview)
        rightKeys.forEach(addSubview)
        middleKeys.forEach(scroller.addSubview)
        pasteControl.target = terminal
        commandRow.addSubview(pasteControl)
        insertKeys = [("photo", "Insert Photo", InsertSource.photos), ("camera", "Insert from Camera", .camera),
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
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: barHeight) }

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
    /// inner display) gets roomier slots.
    private func width(of key: Key) -> CGFloat {
        let roomy = bounds.width >= 600
        switch key {
        case .arrows, .hideKeyboard, .command: return roomy ? 60 : 40
        case .escape, .ctrl, .alt: return roomy ? 46 : 40
        case .tab: return roomy ? 46 : 36
        case .pair, .function: return roomy ? 46 : 33
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
        for (key, view) in zip(layout.left, leftKeys) {
            view.frame = CGRect(x: x, y: 0, width: width(of: key), height: h)
            x += view.frame.width
        }
        let middleStart = x
        var right = capsule.maxX - Chrome.Space.s
        for (key, view) in zip(layout.right, rightKeys).reversed() {
            right -= width(of: key)
            view.frame = CGRect(x: right, y: 0, width: width(of: key), height: h)
        }
        middle.frame = CGRect(x: middleStart, y: 0, width: max(0, right - middleStart), height: h)
        scroller.frame = middle.bounds
        var mx: CGFloat = 0
        for (key, view) in zip(layout.middle, middleKeys) {
            view.frame = CGRect(x: mx, y: 0, width: width(of: key), height: h)
            mx += view.frame.width
        }
        scroller.contentSize = CGSize(width: mx, height: h)
        commandRow.frame = middle.frame
        let slots = CGFloat(1 + insertKeys.count)
        let slot = min(bounds.width >= 600 ? 56 : 44, commandRow.bounds.width / slots).rounded(.down)
        // A circle button; the system won't draw its paste control much smaller.
        let side = min(Chrome.Size.circle, h - 12)
        pasteControl.frame = CGRect(x: (slot - side) / 2, y: (h - side) / 2, width: side, height: side)
        for (i, cap) in insertKeys.enumerated() {
            cap.frame = CGRect(x: slot * CGFloat(i + 1), y: 0, width: slot, height: h)
        }
        updateEdges()
    }

    /// Keys fade out at each side of the middle that has more keys scrolled past it.
    fileprivate func updateEdges() {
        let offset = scroller.contentOffset.x
        let more = (left: !command && offset > 0,
                    right: !command && scroller.contentSize.width - offset > scroller.bounds.width + 0.5)
        let fade = min(20 / max(middle.bounds.width, 1), 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = middle.bounds
        edgeFade.colors = [more.left ? UIColor.clear : .black, .black, .black, more.right ? .clear : .black].map(\.cgColor)
        edgeFade.locations = [0, fade, 1 - fade, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
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
        case .pair(let a, let b):
            cap.configure(title: a, alternate: b)
            cap.repeats = true
            cap.onPick = { [weak self] second in self?.emit(.text(second ? b : a)) }
        case .function(let a, let b):
            cap.configure(title: "F\(a)", alternate: "F\(b)")
            cap.repeats = true
            cap.onPick = { [weak self] second in self?.emit(.key(SmartKeysBar.functionKey(second ? b : a))) }
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
            cap.configure(symbol: "keyboard", secondary: true)
            cap.accessibilityLabel = "Hide Keyboard"
            cap.onTap = { [weak self] in self?.emit(.hideKeyboard) }
        case .command:
            cap.configure(symbol: "command")
            cap.accessibilityLabel = "Command"
            cap.onTap = { [weak self] in self?.commandTapped() }
        }
        return cap
    }

    private static func functionKey(_ n: Int) -> TermKey {
        TermKey(rawValue: TERM_KEY_F1.rawValue + UInt32(n - 1))
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

    private func refresh() {
        for (key, view) in zip(layout.left + layout.right, leftKeys + rightKeys) {
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
        scroller.isUserInteractionEnabled = !row
        commandRow.isHidden = false
        updateEdges()
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

extension SmartKeysBar: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateEdges() }
}

/// Lets vertical drags reach the keys (pull-down alternates) instead of the scroller.
private final class HorizontalScroller: UIScrollView {
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer {
            let v = panGestureRecognizer.velocity(in: self)
            return abs(v.x) > abs(v.y)
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// One key: a label on the glass, a capsule plate only while pressed (a
/// wash) or while a modifier is on (the text colour, the label in the
/// ground). Reports taps, holds, pair picks and joystick directions.
private final class KeyCap: UIView {
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    /// Pairs: false = the main symbol, true = the upper one (pulled down).
    var onPick: ((_ second: Bool) -> Void)?
    /// Holding the key repeats it at the Key Repeat settings (the joystick always does).
    var repeats = false
    /// Joystick: 0 left, 1 down, 2 up, 3 right.
    var onArrow: ((Int) -> Void)?

    var modifier = SmartKeysBar.Modifier.off { didSet { updateLook() } }
    var alternateArrows = false { didSet { updateArms() } }

    private let plate = UIView()
    private let title = UILabel()
    private let upper = UILabel()
    private let lockBar = UIView()
    private var icon: UIImageView?
    private var secondary = false
    /// The joystick's four arms (left, down, up, right), drawn like the
    /// design's arrows glyph so each can light on its own.
    private var arms: [CAShapeLayer] = []
    private var pressed = false { didSet { updateLook() } }
    private var holdTimer: Timer?
    private var held = false
    private var startY: CGFloat = 0
    /// Pull-down progress for pairs, 0...1.
    private var progress: CGFloat = 0
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
        for label in [upper, title] {
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        lockBar.layer.cornerRadius = 1
        lockBar.isHidden = true
        addSubview(lockBar)
        registerForTraitChanges([AppThemeTrait.self]) { (cap: KeyCap, _: UITraitCollection) in cap.updateLook() }
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title text: String, alternate: String? = nil) {
        title.text = text
        accessibilityLabel = text
        upper.text = alternate
        upper.isHidden = alternate == nil
        setNeedsLayout()
    }

    /// `secondary`: drawn in the second text colour (hide-keyboard, which leaves the terminal be).
    func configure(symbol: String, secondary: Bool = false) {
        let view = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Chrome.uiSymbol(.control)))
        view.contentMode = .center
        view.isUserInteractionEnabled = false
        icon = view
        self.secondary = secondary
        addSubview(view)
        updateLook()
    }

    func configureArrows() {
        arms = (0..<4).map { _ in
            let arm = CAShapeLayer()
            arm.fillColor = nil
            arm.lineWidth = 1.7
            arm.lineCap = .round
            arm.lineJoin = .round
            layer.addSublayer(arm)
            return arm
        }
        updateArms()
        updateLook()
    }

    /// One arm pointing up in the glyph's 20-unit box: a shaft from the
    /// middle and a head, or with Cmd a head against a bar (Home/PgUp/…).
    private func updateArms() {
        guard arms.count == 4 else { return }
        let up = UIBezierPath()
        up.move(to: CGPoint(x: 10, y: 10))
        if alternateArrows {
            up.addLine(to: CGPoint(x: 10, y: 4.5))
            up.move(to: CGPoint(x: 7.5, y: 7))
            up.addLine(to: CGPoint(x: 10, y: 4.5))
            up.addLine(to: CGPoint(x: 12.5, y: 7))
            up.move(to: CGPoint(x: 7, y: 2.5))
            up.addLine(to: CGPoint(x: 13, y: 2.5))
        } else {
            up.addLine(to: CGPoint(x: 10, y: 2.5))
            up.move(to: CGPoint(x: 7.5, y: 5))
            up.addLine(to: CGPoint(x: 10, y: 2.5))
            up.addLine(to: CGPoint(x: 12.5, y: 5))
        }
        // left, down, up, right: the up arm turned about the middle.
        let turns: [CGFloat] = [-.pi / 2, .pi, 0, .pi / 2]
        let scale: CGFloat = 22 / 20
        for (arm, turn) in zip(arms, turns) {
            let path = up.copy() as! UIBezierPath
            path.apply(CGAffineTransform(translationX: -10, y: -10))
            path.apply(CGAffineTransform(rotationAngle: turn))
            path.apply(CGAffineTransform(scaleX: scale, y: scale))
            arm.path = path.cgPath
        }
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
        // The pair's upper symbol waits above, unseen, and slides into place
        // as the finger pulls down.
        let p = progress
        title.bounds = CGRect(x: 0, y: 0, width: max(bounds.width, plateWidth), height: 22)
        title.center = center
        upper.bounds = title.bounds
        upper.center = center
        if upper.text != nil {
            let lift = bounds.height * 0.3
            let major = max(1 - p, 0.001)
            title.transform = CGAffineTransform(translationX: 0, y: 14 * p).scaledBy(x: major, y: major)
            title.alpha = 1 - 0.5 * p
            let minor = 0.55 + 0.45 * p
            upper.transform = CGAffineTransform(translationX: 0, y: -lift + lift * p).scaledBy(x: minor, y: minor)
            upper.alpha = p
        } else {
            title.transform = .identity
            title.alpha = 1
        }
        lockBar.frame = CGRect(x: center.x - 6, y: plate.frame.maxY - 5, width: 12, height: 2)
        icon?.frame = CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for arm in arms {
            arm.position = center
        }
        CATransaction.commit()
    }

    private func updateLook() {
        let on = modifier != .off
        let traits = traitCollection
        plate.backgroundColor = on ? Chrome.UI.fg : pressed && arms.isEmpty ? Chrome.UI.fill3 : .clear
        let ink = on ? Chrome.UI.bg : Chrome.UI.fg
        let font = Chrome.uiFont(.title, on ? .semibold : .regular)
        for label in [title, upper] {
            label.textColor = ink
            label.font = font
        }
        lockBar.backgroundColor = Chrome.UI.bg
        lockBar.isHidden = modifier != .locked
        icon?.tintColor = on ? ink : secondary ? Chrome.UI.fg2 : Chrome.UI.fg
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, arm) in arms.enumerated() {
            let lit = direction == nil || direction == i
            arm.strokeColor = Chrome.UI.fg.resolvedColor(with: traits).withAlphaComponent(lit ? 1 : 0.35).cgColor
        }
        CATransaction.commit()
        setNeedsLayout()
    }

    // ------------------------------------------------------------ touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        pressed = true
        held = false
        progress = 0
        startY = t.location(in: self).y
        UIDevice.current.playInputClick()
        if onArrow != nil {
            aim(at: t.location(in: self))
        } else if onHold != nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.held = true
                    UIDevice.current.playInputClick()
                    self.onHold?()
                }
            }
        } else if repeats {
            repeater.start { [weak self] in
                guard let self else { return }
                UIDevice.current.playInputClick()
                if let onPick = self.onPick { onPick(self.progress >= 0.75) } else { self.onTap?() }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if onArrow != nil {
            aim(at: p)
        } else if onPick != nil {
            let full = bounds.height - 10
            progress = min(max(p.y - startY, 0), full) / full
            UIView.performWithoutAnimation { layoutSubviews() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let picked = progress >= 0.75
        let arrow = direction
        let fired = repeater.hasFired
        finish()
        if let onArrow {
            if let arrow, !fired { onArrow(arrow) }
        } else if let onPick {
            if !fired { onPick(picked) }
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
        progress = 0
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
