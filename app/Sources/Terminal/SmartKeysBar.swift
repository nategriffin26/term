import UIKit

/// The key bar above the software keyboard, after Blink's iPhone bar
/// (KBLayout.iPhone, KBSizes): borderless keys on the keyboard's own
/// background. Esc/Ctrl/Alt on the left; a scrolling middle of Tab, symbol
/// pairs and F-keys (pull a pair down for its upper symbol); the arrow
/// joystick, hide-keyboard and Cmd on the right. Cmd swaps the middle for
/// its own row: the system paste control, then photo, camera and file keys
/// that upload to the host and type the path.
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
    private var leftKeys: [KeyCap] = []
    private var rightKeys: [KeyCap] = []
    private var middleKeys: [KeyCap] = []
    private let scroller = HorizontalScroller()
    private let leftEdge = UIView()
    private let rightEdge = UIView()
    private let commandRow = UIView()
    private let pasteControl: UIPasteControl
    private var insertKeys: [KeyCap] = []
    private var lastCommandTap: CFTimeInterval = 0

    /// Blink's iPhone bar height; 38 pt where the phone is on its side.
    static let height: CGFloat = 44
    private var barHeight: CGFloat { traitCollection.verticalSizeClass == .compact ? 38 : SmartKeysBar.height }

    init(terminal: TerminalView, layout: Layout = .standard) {
        self.terminal = terminal
        self.layout = layout
        // The system's own paste button: reads the clipboard without the
        // "Allow Paste" prompt and hands it to the terminal's paste(itemProviders:).
        let paste = UIPasteControl.Configuration()
        paste.displayMode = .iconOnly
        paste.cornerStyle = .fixed
        paste.cornerRadius = 4
        paste.baseForegroundColor = .white
        paste.baseBackgroundColor = UIColor(white: 0.36, alpha: 1)
        pasteControl = UIPasteControl(configuration: paste)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: SmartKeysBar.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.delaysContentTouches = false
        scroller.canCancelContentTouches = true
        scroller.alwaysBounceHorizontal = true
        scroller.delegate = self
        addSubview(scroller)
        for edge in [leftEdge, rightEdge] {
            edge.backgroundColor = .separator
            edge.isUserInteractionEnabled = false
            addSubview(edge)
        }
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
        commandRow.clipsToBounds = true
        commandRow.isHidden = true
        commandRow.alpha = 0
        addSubview(commandRow)
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (bar: SmartKeysBar, _: UITraitCollection) in
            bar.invalidateIntrinsicContentSize()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: barHeight) }

    // ------------------------------------------------------------ layout

    /// Slot widths: Blink's iPhone key (33) and wide key (39); a wide bar
    /// (iPhone Duo's inner display) gets roomier slots.
    private func width(of key: Key) -> CGFloat {
        let roomy = bounds.width >= 600
        switch key {
        case .arrows, .command: return roomy ? 60 : 39
        default: return roomy ? 46 : 33
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        var x = safeAreaInsets.left
        for (key, view) in zip(layout.left, leftKeys) {
            view.frame = CGRect(x: x, y: 0, width: width(of: key), height: h)
            x += view.frame.width
        }
        let middleStart = x
        var right = bounds.width - safeAreaInsets.right
        for (key, view) in zip(layout.right, rightKeys).reversed() {
            right -= width(of: key)
            view.frame = CGRect(x: right, y: 0, width: width(of: key), height: h)
        }
        scroller.frame = CGRect(x: middleStart, y: 0, width: max(0, right - middleStart), height: h)
        var mx: CGFloat = 0
        for (key, view) in zip(layout.middle, middleKeys) {
            view.frame = CGRect(x: mx, y: 0, width: width(of: key), height: h)
            mx += view.frame.width
        }
        scroller.contentSize = CGSize(width: mx, height: h)
        commandRow.frame = scroller.frame
        let slots = CGFloat(1 + insertKeys.count)
        let slot = min(bounds.width >= 600 ? 56 : 44, commandRow.bounds.width / slots).rounded(.down)
        pasteControl.frame = CGRect(x: 0, y: 0, width: slot, height: h).inset(by: KeyCap.plateInsets)
        for (i, cap) in insertKeys.enumerated() {
            cap.frame = CGRect(x: slot * CGFloat(i + 1), y: 0, width: slot, height: h)
        }
        leftEdge.frame = CGRect(x: middleStart - 0.5, y: 9, width: 1 / max(traitCollection.displayScale, 1), height: h - 18)
        rightEdge.frame = CGRect(x: right - 0.5, y: 9, width: leftEdge.frame.width, height: h - 18)
        updateEdges()
    }

    /// A hairline marks each side of the middle that has keys scrolled out of view.
    fileprivate func updateEdges() {
        let offset = scroller.contentOffset.x
        leftEdge.isHidden = command || offset <= 0
        rightEdge.isHidden = command || scroller.contentSize.width - offset <= scroller.bounds.width + 0.5
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
            cap.onArrow = { [weak self] direction in
                guard let self else { return }
                let keys: [TermKey] = command
                    ? [TERM_KEY_HOME, TERM_KEY_PAGE_DOWN, TERM_KEY_PAGE_UP, TERM_KEY_END]
                    : [TERM_KEY_LEFT, TERM_KEY_DOWN, TERM_KEY_UP, TERM_KEY_RIGHT]
                emit(.key(keys[direction]))
            }
        case .hideKeyboard:
            cap.configure(symbol: "keyboard.chevron.compact.down")
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
            self.scroller.alpha = row ? 0 : 1
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

/// One key, drawn like Blink's: a label on the bar, a rounded plate only
/// while pressed or while a modifier is on. Reports taps, holds, pair picks
/// and joystick directions.
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
    var alternateArrows = false { didSet { updateArrowSymbols() } }

    private let plate = UIView()
    private let title = UILabel()
    private let upper = UILabel()
    private let lockBar = UIView()
    private var icons: [UIImageView] = []
    private var pressed = false { didSet { updateLook() } }
    private var holdTimer: Timer?
    private var held = false
    private var startY: CGFloat = 0
    /// Pull-down progress for pairs, 0...1.
    private var progress: CGFloat = 0
    private var direction: Int?
    private let repeater = KeyRepeater()

    /// Blink's small-key insets: the plate sits 3 pt below the bar top, 1 pt from the rest.
    static let plateInsets = UIEdgeInsets(top: 3, left: 1, bottom: 1, right: 1)

    init() {
        super.init(frame: .zero)
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        plate.layer.cornerRadius = 4
        plate.layer.cornerCurve = .continuous
        plate.isUserInteractionEnabled = false
        addSubview(plate)
        let font = UIFont.systemFont(ofSize: 15, weight: .medium)
        for label in [upper, title] {
            label.textAlignment = .center
            label.font = font
            label.textColor = .white
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        lockBar.backgroundColor = .black
        lockBar.layer.cornerRadius = 1
        lockBar.isHidden = true
        addSubview(lockBar)
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

    func configure(symbol: String) {
        let icon = UIImageView(image: UIImage(systemName: symbol,
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)))
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        icons = [icon]
        addSubview(icon)
        updateLook()
    }

    func configureArrows() {
        icons = (0..<4).map { _ in
            let v = UIImageView()
            v.contentMode = .center
            v.isUserInteractionEnabled = false
            addSubview(v)
            return v
        }
        updateArrowSymbols()
        updateLook()
    }

    private func updateArrowSymbols() {
        guard icons.count == 4 else { return }
        let names = alternateArrows
            ? ["arrow.left.to.line", "arrow.down.to.line", "arrow.up.to.line", "arrow.right.to.line"]
            : ["arrow.left", "arrow.down", "arrow.up", "arrow.right"]
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        for (v, name) in zip(icons, names) { v.image = UIImage(systemName: name, withConfiguration: config) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let key = bounds.inset(by: KeyCap.plateInsets)
        plate.frame = key
        let center = CGPoint(x: key.midX, y: key.midY)
        // Blink's pair key: the upper symbol rides above, small and faint,
        // and slides into place as the finger pulls down.
        let p = progress
        title.bounds = CGRect(x: 0, y: 0, width: key.width, height: 20)
        title.center = center
        upper.bounds = title.bounds
        upper.center = center
        if upper.text != nil {
            let lift = key.height * 0.3
            let major = max(1 - p, 0.001)
            title.transform = CGAffineTransform(translationX: 0, y: 4 + 14 * p).scaledBy(x: major, y: major)
            title.alpha = 1 - 0.5 * p
            let minor = 0.55 + 0.45 * p
            upper.transform = CGAffineTransform(translationX: 0, y: -lift + lift * p).scaledBy(x: minor, y: minor)
            upper.alpha = 0.3 + 0.7 * p
        } else {
            title.transform = .identity
            title.alpha = 1
        }
        lockBar.frame = CGRect(x: key.midX - 7, y: key.maxY - 5, width: 14, height: 2)
        if icons.count == 4 {
            // Blink's joystick: four small arrows around the middle.
            let offsets = [CGPoint(x: -key.width * 0.27, y: 0), CGPoint(x: 0, y: key.height * 0.22),
                           CGPoint(x: 0, y: -key.height * 0.22), CGPoint(x: key.width * 0.27, y: 0)]
            for (v, o) in zip(icons, offsets) {
                v.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
                v.center = CGPoint(x: center.x + o.x, y: center.y + o.y)
            }
        } else {
            icons.first?.frame = key
        }
    }

    private func updateLook() {
        let on = modifier != .off
        plate.backgroundColor = on ? .white : pressed && icons.count != 4 ? UIColor(white: 1, alpha: 0.22) : .clear
        let fg: UIColor = on ? .black : .white
        title.textColor = fg
        upper.textColor = fg
        lockBar.isHidden = modifier != .locked
        for (i, v) in icons.enumerated() {
            let lit = icons.count != 4 || direction == nil || direction == i
            v.tintColor = fg.withAlphaComponent(lit ? 1 : 0.35)
        }
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
        let key = bounds.inset(by: KeyCap.plateInsets)
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
