import GameController
import UIKit
import UniformTypeIdentifiers

@MainActor
protocol TerminalViewDelegate: AnyObject {
    /// The user changed the font size (pinch or Cmd +/−/0); persist it.
    func terminalView(_ view: TerminalView, didChangeFontSize pointSize: CGFloat)
    /// A paste here (⌘V, the edit menu, Smart Keys): true when the delegate
    /// took it (Files in front, or images and files to upload); false
    /// leaves the text for the shell.
    func terminalView(_ view: TerminalView, paste clip: Clip) -> Bool
    /// Smart Keys' photo, camera and file keys.
    func terminalView(_ view: TerminalView, insertFrom source: InsertSource)
}

/// A terminal surface: renders a Session with Metal, sizes its grid to
/// the visible area, and turns touches and keys into terminal input.
@MainActor
final class TerminalView: UIView {
    static func registerFonts() { FontSet.registerFonts() }

    weak var delegate: TerminalViewDelegate?

    /// Font family; the bundled Nerd Font unless Appearance picks another.
    var fontFamily: String = FontSet.family {
        didSet { if fontFamily != oldValue { reloadFonts() } }
    }

    /// iOS's three-finger edit gestures would steal the shell's three-finger tap.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }


    var session: Session {
        didSet {
            guard session !== oldValue else { return }
            oldValue.onFrame = nil
            attach()
        }
    }

    /// Point size of the terminal font; changes re-lay the grid.
    var fontSize: CGFloat {
        didSet {
            fontSize = min(max(fontSize, FontSet.pointSizeRange.lowerBound), FontSet.pointSizeRange.upperBound)
            if fontSize != oldValue { reloadFonts() }
        }
    }

    var cursorBlinkEnabled = true {
        didSet { updateBlinkTimer(); setNeedsRender() }
    }
    var showsSmartKeysWithHardwareKeyboard = false {
        didSet { if showsSmartKeysWithHardwareKeyboard != oldValue { updateAccessory() } }
    }
    var keyClicksEnabled = true
    /// A page to read (tmux history): no keyboard, no paste.
    var isReadOnly = false

    /// Current grid size in cells.
    var gridSize: (cols: Int, rows: Int) { (session.cols, session.rows) }

    // ------------------------------------------------------------ state

    var renderer: Renderer?
    var snapshot = FrameSnapshot()
    private var haveGeneration: UInt64 = .max
    private var needsBuild = true
    private var needsDraw = true
    private var displayLink: CADisplayLink?
    var scale: CGFloat = 1

    /// Grid top-left in drawable pixels.
    var gridOrigin = CGPoint.zero
    var zoom: CGFloat = 1
    var zoomCenter = CGPoint.zero
    var isPinching = false

    var blinkOn = true
    private var blinkTimer: Timer?

    var selection: (start: GridPoint, end: GridPoint)?
    let keyboardSpacer = UIView()
    /// The safe area as a hidden view, so UIKit can say how far its corners
    /// must pull in to clear rounded display corners.
    private let safeRegion = UIView()
    let scrollIndicator = UIView()
    lazy var smartKeys = SmartKeysBar(terminal: self)
    lazy var editMenu = UIEditMenuInteraction(delegate: self)
    let startHandle = SelectionHandle(isStart: true)
    let endHandle = SelectionHandle(isStart: false)

    // Gesture state (TerminalView+Gestures).
    var scrollRemainder: CGFloat = 0
    var scrollAnchor = (col: 0, row: 0)
    var lastPanTranslation: CGFloat = 0
    var momentumVelocity: CGFloat = 0
    var momentumTime: CFTimeInterval = 0
    var isCoasting = false
    var touchStoppedCoasting = false
    var pinchBaseSize: CGFloat = 0
    var selectionAnchor: (start: GridPoint, end: GridPoint)?
    var scrollIndicatorHide: Timer?

    // Input state (TerminalView+Input).
    let repeater = KeyRepeater()
    let deletePacer = HeldDeletePacer()
    var repeatingKey: UIKeyboardHIDUsage?
    var markedText = ""
    weak var inputDelegate: UITextInputDelegate?

    // UITextInputTraits.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(session: Session, fontSize: CGFloat = FontSet.defaultPointSize) {
        self.session = session
        self.fontSize = fontSize
        super.init(frame: .zero)
        isOpaque = true
        isMultipleTouchEnabled = true
        backgroundColor = .black

        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3

        keyboardSpacer.isHidden = true
        keyboardSpacer.isUserInteractionEnabled = false
        keyboardSpacer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardSpacer)
        keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            keyboardSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardSpacer.widthAnchor.constraint(equalToConstant: 1),
            keyboardSpacer.topAnchor.constraint(equalTo: topAnchor),
            keyboardSpacer.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
        safeRegion.isHidden = true
        safeRegion.isUserInteractionEnabled = false
        addSubview(safeRegion)

        scrollIndicator.backgroundColor = UIColor(white: 0.6, alpha: 0.8)
        scrollIndicator.layer.cornerRadius = 1.5
        scrollIndicator.alpha = 0
        scrollIndicator.isUserInteractionEnabled = false
        addSubview(scrollIndicator)

        addInteraction(editMenu)
        // What Smart Keys' paste control (and a drop) hands paste(itemProviders:).
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.item.identifier])
        installGestures()
        addSubview(startHandle)
        addSubview(endHandle)
        installHandleGestures()

        registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalView, _: UITraitCollection) in
            view.reloadFonts()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged),
                                               name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged),
                                               name: .GCKeyboardDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        attach()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func attach() {
        session.onFrame = { [weak self] in self?.setNeedsRender(build: false) }
        haveGeneration = .max
        sessionSized = false
        resizeTask?.cancel()
        selection = nil
        updateHandles()
        setNeedsLayout()
        setNeedsRender()
    }

    // ------------------------------------------------------------ layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        reloadFonts()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = traitCollection.displayScale
        if s != scale || renderer == nil { reloadFonts() }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        layoutGrid()
        updateHandles()
        setNeedsRender(build: false)
    }

    /// Fits the grid inside the safe area, clear of rounded display corners
    /// and above the keyboard, then tells the session once the size settles:
    /// keyboard and rotation animations pass through in-between sizes, and
    /// each resize would make the remote (tmux) redraw.
    func layoutGrid() {
        guard let m = renderer?.fonts.metrics, bounds.width > 0, bounds.height > 0 else { return }
        // Corner adaptation of the safe area itself, so a corner already under
        // a bar costs nothing. One axis alone stops at the corner's 45° point,
        // which still clips the first cell; both together clear it.
        safeRegion.frame = bounds.inset(by: safeAreaInsets)
        let h = safeRegion.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
        let v = safeRegion.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
        var area = safeRegion.frame.inset(by: UIEdgeInsets(top: max(h.top, v.top), left: max(h.left, v.left),
                                                           bottom: max(h.bottom, v.bottom), right: max(h.right, v.right)))
        let keyboardTop = keyboardSpacer.frame.maxY
        if keyboardTop > area.minY, keyboardTop < area.maxY { area.size.height = keyboardTop - area.minY }
        let x0 = (area.minX * scale).rounded(.up), y0 = (area.minY * scale).rounded(.up)
        let x1 = (area.maxX * scale).rounded(.down), y1 = (area.maxY * scale).rounded(.down)
        let widthPx = max(0, Int(x1 - x0)), heightPx = max(0, Int(y1 - y0))
        let cols = max(1, widthPx / m.width), rows = max(1, heightPx / m.height)
        gridOrigin = CGPoint(x: x0 + CGFloat(max(0, widthPx - cols * m.width) / 2), y: y0)
        if !isPinching {
            let size = (cols: cols, rows: rows, w: m.width, h: m.height)
            resizeTask?.cancel()
            if !sessionSized {
                sessionSized = true
                session.resize(cols: size.cols, rows: size.rows, cellWidth: size.w, cellHeight: size.h)
            } else {
                resizeTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, let self else { return }
                    self.session.resize(cols: size.cols, rows: size.rows, cellWidth: size.w, cellHeight: size.h)
                }
            }
        }
    }

    /// The first size goes out at once so a new session starts at the right
    /// size; later ones wait for layout to settle.
    private var sessionSized = false
    private var resizeTask: Task<Void, Never>?

    /// Rebuilds the font set for the current size and display scale.
    func reloadFonts() {
        let s = traitCollection.displayScale
        guard window != nil, s > 0 else { return }
        scale = s
        let fonts = FontSet(family: fontFamily, pointSize: fontSize, scale: scale)
        if let renderer {
            let old = renderer.fonts
            if old.family == fonts.family, old.pointSize == fonts.pointSize, old.scale == fonts.scale { return }
            renderer.setFonts(fonts)
        } else {
            renderer = Renderer(fonts: fonts)
        }
        setNeedsLayout()
        setNeedsRender()
    }

    /// A font size change the user made; tells the delegate.
    func userSetFontSize(_ size: CGFloat) {
        let old = fontSize
        fontSize = size
        if fontSize != old { delegate?.terminalView(self, didChangeFontSize: fontSize) }
    }

    // ------------------------------------------------------------ geometry

    var cellSizePoints: CGSize {
        guard let m = renderer?.fonts.metrics else { return CGSize(width: 6, height: 13) }
        return CGSize(width: CGFloat(m.width) / scale, height: CGFloat(m.height) / scale)
    }

    /// The viewport cell under a point in view coordinates, clamped to the grid.
    func cell(at p: CGPoint) -> (col: Int, row: Int) {
        let c = cellSizePoints
        let col = Int(((p.x - gridOrigin.x / scale) / c.width).rounded(.down))
        let row = Int(((p.y - gridOrigin.y / scale) / c.height).rounded(.down))
        return (min(max(col, 0), max(session.cols - 1, 0)), min(max(row, 0), max(session.rows - 1, 0)))
    }

    /// The rect of a viewport cell in view coordinates.
    func rect(col: Int, row: Int, span: Int = 1) -> CGRect {
        let c = cellSizePoints
        return CGRect(x: gridOrigin.x / scale + CGFloat(col) * c.width, y: gridOrigin.y / scale + CGFloat(row) * c.height,
                      width: c.width * CGFloat(span), height: c.height)
    }

    // ------------------------------------------------------------ rendering

    /// Schedules a draw on the next display refresh. `build` re-derives
    /// GPU data from the last frame (selection, cursor and blink changes).
    func setNeedsRender(build: Bool = true) {
        if build { needsBuild = true }
        needsDraw = true
        displayLink?.isPaused = false
    }

    var isAnimating: Bool { isCoasting || isPinching }

    fileprivate func tick(_ link: CADisplayLink) {
        if isCoasting { coast(to: link.targetTimestamp) }
        render()
        if !isAnimating && !needsDraw { link.isPaused = true }
    }

    func render() {
        guard let renderer, window != nil else { return }
        var frame = TermFrame()
        if session.frame(after: haveGeneration, into: &frame) {
            haveGeneration = frame.generation
            let oldModes = snapshot.modes
            snapshot.load(frame)
            needsBuild = true
            frameDidChange(oldModes: oldModes)
        }
        if needsBuild {
            renderer.build(snapshot, overlay: overlay)
            needsBuild = false
            needsDraw = true
            if renderer.hasBlinkingText != (blinkTimer != nil) { updateBlinkTimer() }
        }
        guard needsDraw, metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return }
        needsDraw = false
        guard let drawable = metalLayer.nextDrawable(),
              let cb = renderer.encode(into: drawable.texture, placement: placement) else { return }
        cb.present(drawable)
        cb.commit()
    }

    var placement: Renderer.Placement {
        Renderer.Placement(
            viewport: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            origin: SIMD2(Float(gridOrigin.x), Float(gridOrigin.y)),
            zoom: Float(zoom),
            zoomCenter: SIMD2(Float(zoomCenter.x), Float(zoomCenter.y)))
    }

    var overlay: Renderer.Overlay {
        var o = Renderer.Overlay()
        o.focused = isFirstResponder
        o.cursorOn = blinkOn || !cursorBlinkEnabled
        o.blinkOn = blinkOn
        o.selection = selectionSpan
        o.selectionColor = tintColor.argb
        return o
    }

    private func frameDidChange(oldModes: UInt32) {
        backgroundColor = UIColor(argb: snapshot.bg)
        let focusEvents = UInt32(TERM_MODE_FOCUS_EVENTS)
        if snapshot.modes & focusEvents != 0, oldModes & focusEvents == 0 {
            reportFocus(isFirstResponder)
        }
        if snapshot.viewportOffset > 0 || scrollIndicator.alpha > 0 { updateScrollIndicator() }
        updateHandles()
        updateBlinkTimer()
    }

    // ------------------------------------------------------------ blink

    func updateBlinkTimer() {
        let cursorBlinks = snapshot.cursorBlink && cursorBlinkEnabled && isFirstResponder && snapshot.cursorVisible
        let wants = cursorBlinks || (renderer?.hasBlinkingText ?? false)
        if wants, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.setNeedsRender()
                }
            }
        } else if !wants, let t = blinkTimer {
            t.invalidate()
            blinkTimer = nil
            if !blinkOn { blinkOn = true; setNeedsRender() }
        }
    }

    /// Shows the cursor solid again (after input) and restarts its phase.
    func restartBlink() {
        guard blinkTimer != nil else { return }
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        updateBlinkTimer()
        setNeedsRender()
    }

    // ------------------------------------------------------------ focus

    override var canBecomeFirstResponder: Bool { !isReadOnly }

    /// The terminal that last took the keyboard. Each window keeps its own
    /// first responder, so without this a terminal in a second window would
    /// still look focused (cursor, Smart Keys) while the keys go elsewhere.
    private static weak var keyboardOwner: TerminalView?

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        guard ok else { return false }
        if let previous = Self.keyboardOwner, previous !== self, previous.isFirstResponder {
            previous.resignFirstResponder()
        }
        Self.keyboardOwner = self
        focusChanged(true)
        return true
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusChanged(false) }
        return ok
    }

    private func focusChanged(_ focused: Bool) {
        if snapshot.has(TERM_MODE_FOCUS_EVENTS) { reportFocus(focused) }
        updateBlinkTimer()
        setNeedsRender()
    }

    private func reportFocus(_ focused: Bool) {
        session.write(Data((focused ? "\u{1B}[I" : "\u{1B}[O").utf8))
    }

    // ------------------------------------------------------------ smart keys

    var hardwareKeyboardAttached: Bool { GCKeyboard.coalesced != nil }

    /// Whether the software keyboard was on screen at the last keyboard frame
    /// change; nil until one arrives (then a connected keyboard is the guess).
    /// The simulator, and an iPhone whose keyboard is asleep, can show the
    /// software keyboard while a GCKeyboard is connected.
    private var softwareKeyboardShown: Bool?

    override var inputAccessoryView: UIView? {
        let software = softwareKeyboardShown ?? !hardwareKeyboardAttached
        return software || showsSmartKeysWithHardwareKeyboard ? smartKeys : nil
    }

    @objc private func keyboardsChanged() {
        softwareKeyboardShown = nil
        updateAccessory()
    }

    /// A software keyboard is far taller than the bar; with a hardware
    /// keyboard the frame holds only the bar, or nothing.
    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard isFirstResponder, let window,
              let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let frame = window.convert(end, from: window.screen.coordinateSpace).intersection(window.bounds)
        guard !frame.isNull, frame.height > 0 else { return }
        let had = inputAccessoryView != nil
        softwareKeyboardShown = frame.height > SmartKeysBar.height + 80
        guard (inputAccessoryView != nil) != had else { return }
        DispatchQueue.main.async { [weak self] in self?.updateAccessory() }
    }

    func updateAccessory() {
        if isFirstResponder { reloadInputViews() }
    }

    // ------------------------------------------------------------ scroll indicator

    func updateScrollIndicator() {
        let history = snapshot.historyRows
        guard history > 0, !snapshot.has(TERM_MODE_ALT_SCREEN) else {
            hideScrollIndicator()
            return
        }
        let gridTop = gridOrigin.y / scale
        let gridHeight = CGFloat(snapshot.rows) * cellSizePoints.height
        let total = CGFloat(history + snapshot.rows)
        let h = max(24, gridHeight * CGFloat(snapshot.rows) / total)
        let fraction = CGFloat(history - snapshot.viewportOffset) / CGFloat(history)
        let x = bounds.width - safeAreaInsets.right - 5
        scrollIndicator.frame = CGRect(x: x, y: gridTop + (gridHeight - h) * fraction, width: 3, height: h)
        scrollIndicator.alpha = 1
        scrollIndicatorHide?.invalidate()
        scrollIndicatorHide = Timer.scheduledTimer(withTimeInterval: snapshot.viewportOffset > 0 ? 1.6 : 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideScrollIndicator() }
        }
    }

    private func hideScrollIndicator() {
        scrollIndicatorHide?.invalidate()
        scrollIndicatorHide = nil
        guard scrollIndicator.alpha > 0 else { return }
        UIView.animate(withDuration: 0.3) { self.scrollIndicator.alpha = 0 }
    }
}

/// Breaks the CADisplayLink → target retain cycle.
private final class DisplayLinkTarget: NSObject {
    weak var view: TerminalView?
    init(_ view: TerminalView) { self.view = view }
    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.tick(link)
    }
}

extension UIColor {
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                  blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat(argb >> 24) / 255)
    }

    var argb: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(a) << 24 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
