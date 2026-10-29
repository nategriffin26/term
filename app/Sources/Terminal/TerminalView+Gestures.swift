import UIKit

/// A cell position whose row counts from the top of scrollback, so a
/// selection stays on its text while the viewport scrolls.
struct GridPoint: Comparable {
    var row: Int
    var col: Int

    static func < (a: GridPoint, b: GridPoint) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }
}

/// Start state and routed lines for one pan, including its momentum.
struct ScrollGesture {
    let branch: String
    let historyRows: Int
    let viewportOffset: Int
    let alternateScreen: Bool
    let mouseTracking: Bool
    var lines = 0
}

/// Opens a tapped link in the default browser; tests replace `open`.
@MainActor
enum LinkOpener {
    static var open: @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) }
}

extension TerminalView {
    func installGestures() {
        let tap = TimedTapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        doubleTap.touchDown = { [weak tap] in tap?.touchingSince }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)

        // Press and slide along the message rail; quicker than word selection, which it replaces there.
        let railPress = UILongPressGestureRecognizer(target: self, action: #selector(handleRailPress(_:)))
        railPress.minimumPressDuration = 0.2
        railPress.name = Self.railPressName
        addGestureRecognizer(railPress)
    }

    private static let railPressName = "rail-press"

    func installHandleGestures() {
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragHandle(_:))))
        }
    }

    // Vertical pans scroll; horizontal ones are left to the pager around
    // us. Touches that land on a selection handle belong to the handle.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g.view === self else { return super.gestureRecognizerShouldBegin(g) }
        let p = g.location(in: self)
        for handle in [startHandle, endHandle] where !handle.isHidden && handle.frame.contains(p) {
            return false
        }
        // The rail's strip: its own press, never word selection.
        let inRail = railView.owns(p)
        if g.name == Self.railPressName { return inRail }
        if inRail, g is UILongPressGestureRecognizer { return false }
        if let pan = g as? UIPanGestureRecognizer {
            let v = pan.velocity(in: self)
            return abs(v.y) >= abs(v.x)
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isCoasting {
            stopCoasting()
            touchStoppedCoasting = true
        }
        super.touchesBegan(touches, with: event)
    }

    // ------------------------------------------------------------ tap

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if touchStoppedCoasting {
            touchStoppedCoasting = false
            doubleTap.reset()
            recordTap("stopped-coasting", at: p, g)
            return
        }
        if selection != nil {
            clearSelection()
            doubleTap.reset()
            recordTap("cleared-selection", at: p, g)
            return
        }
        if railView.owns(p) {
            // A tap on the rail comes after the one held in the band; the keyboard stays as it is.
            doubleTap.release()
            recordTap("rail", at: p, g)
            railView.tap(at: p)
            return
        }
        if let diagram = diagramOverlay.diagram(at: p) {
            doubleTap.release()
            recordTap("diagram", at: p, g)
            openDiagram(diagram)
            return
        }
        let edgeBand = delegate?.terminalViewHasEdgeBand(self) == true
        if edgeBand, DoubleTap.band(in: bounds).contains(p), let timed = g as? TimedTapGestureRecognizer {
            bandTap(at: p, touch: timed.touchTime, lift: timed.liftTime, g)
            return
        }
        // A tap elsewhere comes after the one held in the band.
        doubleTap.release()
        // A link opens instead of focusing or clicking.
        if let link = link(at: p) {
            open(link, tapFields(at: p, g))
            return
        }
        guard isFirstResponder else {
            recordTap("focus", at: p, g)
            _ = becomeFirstResponder()
            return
        }
        recordTap("click", at: p, g)
        click(cell(at: p))
    }

    /// A tap in the right edge band never moves the keyboard: a second one
    /// inside the window opens Sessions, and a lone one, once the window has
    /// passed, opens the link under it or is one click (nothing when the
    /// program does not track the mouse).
    private func bandTap(at p: CGPoint, touch: TimeInterval, lift: TimeInterval, _ g: UITapGestureRecognizer) {
        if doubleTap.pairs(at: p, touch: touch) {
            if delegate?.terminalViewDoubleTapped(self) == true {
                recordTap("band-pair-sessions", at: p, g)
                doubleTap.reset()
                return
            }
            recordTap("band-pair-declined", at: p, g)
        } else if let heldLift = doubleTap.heldLift {
            // A tap still held that did not pair: how long after its lift this one touched.
            recordTap("band-hold", at: p, g, "sinceHeldLift=\(DiagnosticLog.seconds(touch - heldLift))")
        } else if let last = doubleTap.lastRelease, touch >= last.lift, touch - last.lift <= DoubleTap.interval {
            // Inside the window of a tap already released: this pair was lost, and here is to what.
            recordTap("band-hold", at: p, g, "missedPair=released-by-\(last.byTimer ? "timer" : "tap")"
                + " sinceReleasedLift=\(DiagnosticLog.seconds(touch - last.lift))")
        } else {
            recordTap("band-hold", at: p, g)
        }
        let c = cell(at: p)
        let link = link(at: p)
        let fields = tapFields(at: p, g)
        doubleTap.hold(at: p, lift: lift) { [weak self] in
            guard let self else { return }
            if let link { open(link, fields) } else { click(c) }
        }
    }

    /// The web link under `p`: an OSC 8 hyperlink or a URL in the text.
    private func link(at p: CGPoint) -> (url: URL, kind: String)? {
        let q = gridPoint(at: p)
        guard let link = session.link(col: q.col, row: q.row), let url = URL(string: link.uri) else { return nil }
        return (url, link.hyperlink ? "osc8" : "text")
    }

    /// Opens a tapped link and logs its kind, scheme and whether it opened (never the URL).
    private func open(_ link: (url: URL, kind: String), _ fields: String) {
        Task { @MainActor in
            let opened = await LinkOpener.open(link.url)
            DiagnosticLog.record(.tap, "link", fields + " kind=\(link.kind)"
                + " scheme=\(link.url.scheme?.lowercased() ?? "none") result=\(opened ? "opened" : "failed")")
        }
    }

    private func recordTap(_ decision: String, at p: CGPoint, _ g: UITapGestureRecognizer, _ extra: String = "") {
        let fields = tapFields(at: p, g)
        DiagnosticLog.record(.tap, decision, extra.isEmpty ? fields : fields + " " + extra)
    }

    /// One line per tap: what it did, where (as a fraction of the terminal),
    /// whether the edge band is on (posture) and the tap inside it, its touch
    /// and lift times, how long after the lift the handler ran (uptime − lift;
    /// UITouch times count on the uptime clock), and the clocks themselves.
    private func tapFields(at p: CGPoint, _ g: UITapGestureRecognizer) -> String {
        var fields = "x=\(DiagnosticLog.fraction(p.x / max(bounds.width, 1))) y=\(DiagnosticLog.fraction(p.y / max(bounds.height, 1)))"
            + " edgeBand=\(delegate?.terminalViewHasEdgeBand(self) == true) inBand=\(DoubleTap.band(in: bounds).contains(p))"
        if let timed = g as? TimedTapGestureRecognizer {
            fields += " touch=\(DiagnosticLog.seconds(timed.touchTime)) lift=\(DiagnosticLog.seconds(timed.liftTime))"
                + " latency=\(DiagnosticLog.seconds(ProcessInfo.processInfo.systemUptime - timed.liftTime))"
        }
        return fields + " " + DiagnosticLog.clocks + " focused=\(isFirstResponder)"
    }

    private func click(_ c: (col: Int, row: Int)) {
        guard snapshot.has(TERM_MODE_MOUSE_TRACKING) else { return }
        session.mouse(TERM_MOUSE_PRESS, TERM_MOUSE_LEFT, col: c.col, row: c.row)
        session.mouse(TERM_MOUSE_RELEASE, TERM_MOUSE_LEFT, col: c.col, row: c.row)
    }

    // ------------------------------------------------------------ rail

    @objc private func handleRailPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began {
            doubleTap.reset()
            stopCoasting()
        }
        railView.press(g)
    }

    // ------------------------------------------------------------ scroll

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            doubleTap.reset()
            touchStoppedCoasting = false
            stopCoasting()
            isScrollDragging = true
            let mouse = snapshot.has(TERM_MODE_MOUSE_TRACKING)
            let alternate = snapshot.has(TERM_MODE_ALT_SCREEN)
            scrollGesture = ScrollGesture(branch: mouse ? "wheel" : alternate ? "arrows" : "scrollback",
                historyRows: snapshot.historyRows, viewportOffset: snapshot.viewportOffset,
                alternateScreen: alternate, mouseTracking: mouse)
            scrollRemainder = 0
            lastPanTranslation = 0
            scrollAnchor = cell(at: g.location(in: self))
        case .changed:
            let t = g.translation(in: self).y
            scroll(points: t - lastPanTranslation)
            lastPanTranslation = t
        case .ended:
            isScrollDragging = false
            let v = g.velocity(in: self).y
            if abs(v) > 120 { startCoasting(velocity: v) }
            else { finishScrollGesture() }
        case .cancelled, .failed:
            isScrollDragging = false
            stopCoasting()
        default:
            break
        }
    }

    /// Finger travel in points; one line per cell height, remainder kept.
    func scroll(points dy: CGFloat) {
        let line = cellSizePoints.height
        scrollRemainder += dy
        let lines = Int((scrollRemainder / line).rounded(.towardZero))
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines) * line
        scroll(lines: lines)
    }

    /// Positive = toward older output (finger moving down).
    /// Mouse-tracking apps (tmux with mouse on) get one wheel event per
    /// line; the alt screen without mouse gets arrow keys; otherwise the
    /// local scrollback moves.
    private func scroll(lines: Int) {
        if snapshot.has(TERM_MODE_MOUSE_TRACKING) {
            scrollGesture?.lines += lines
            let button = lines > 0 ? TERM_MOUSE_WHEEL_UP : TERM_MOUSE_WHEEL_DOWN
            for _ in 0..<abs(lines) {
                session.mouse(TERM_MOUSE_PRESS, button, col: scrollAnchor.col, row: scrollAnchor.row)
            }
        } else if snapshot.has(TERM_MODE_ALT_SCREEN) {
            scrollGesture?.lines += lines
            let key = lines > 0 ? TERM_KEY_UP : TERM_KEY_DOWN
            for _ in 0..<abs(lines) { session.key(key) }
        } else {
            if lines > 0, snapshot.viewportOffset >= snapshot.historyRows {
                stopCoasting()
                return
            }
            if lines < 0, snapshot.viewportOffset == 0 {
                stopCoasting()
                return
            }
            session.scroll(by: Int32(lines))
            scrollGesture?.lines += lines
            updateScrollIndicator()
        }
    }

    /// Momentum after a flick, decaying like UIScrollView's normal rate.
    private func startCoasting(velocity: CGFloat) {
        momentumVelocity = velocity
        momentumTime = CACurrentMediaTime()
        isCoasting = true
        setNeedsRender(build: false)
    }

    func stopCoasting() {
        isCoasting = false
        momentumVelocity = 0
        if !isScrollDragging { finishScrollGesture() }
    }

    func coast(to time: CFTimeInterval) {
        let dt = max(0, time - momentumTime)
        momentumTime = time
        let k = log(0.998) * 1000  // per second
        let decay = exp(k * dt)
        let distance = momentumVelocity * CGFloat((decay - 1) / k)
        momentumVelocity *= CGFloat(decay)
        scroll(points: distance)
        if abs(momentumVelocity) < 15 { stopCoasting() }
    }

    private func finishScrollGesture() {
        guard let gesture = scrollGesture else { return }
        scrollGesture = nil
        // Scrolling tmux moves its copy mode view: the rail's viewport line follows.
        if gesture.branch == "wheel", railView.isActive { railView.rail?.followViewport() }
        var frame = TermFrame()
        let offset = session.frame(after: .max, into: &frame) ? Int(frame.viewport_offset) : snapshot.viewportOffset
        let moved = gesture.branch == "scrollback" ? offset - gesture.viewportOffset : gesture.lines
        DiagnosticLog.record(.scroll, gesture.branch,
            "terminal=\(DiagnosticLog.name(diagnosticName())) historyRows=\(gesture.historyRows)"
            + " viewportOffset=\(gesture.viewportOffset) alternateScreen=\(gesture.alternateScreen)"
            + " mouseTracking=\(gesture.mouseTracking) lines=\(gesture.lines) linesMoved=\(moved)"
            + " endOffset=\(offset) endHistoryRows=\(frame.history_rows)")
    }

    // ------------------------------------------------------------ pinch

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let range = FontSet.pointSizeRange
        switch g.state {
        case .began:
            doubleTap.reset()
            stopCoasting()
            pinchBaseSize = fontSize
            isPinching = true
            let p = g.location(in: self)
            zoomCenter = CGPoint(x: p.x * scale, y: p.y * scale)
            setNeedsRender(build: false)
        case .changed:
            zoom = min(max(g.scale, range.lowerBound / pinchBaseSize), range.upperBound / pinchBaseSize)
            setNeedsRender(build: false)
        case .ended:
            let size = (pinchBaseSize * zoom * 2).rounded() / 2
            isPinching = false
            zoom = 1
            userSetFontSize(size)
            layoutGrid()
            setNeedsRender()
        default:
            isPinching = false
            zoom = 1
            setNeedsRender(build: false)
        }
    }

    // ------------------------------------------------------------ selection

    /// Rows above the viewport top, in the scrollback-relative row space.
    private var viewportTop: Int { snapshot.historyRows - snapshot.viewportOffset }

    private func gridPoint(at p: CGPoint) -> GridPoint {
        let c = cell(at: p)
        return GridPoint(row: viewportTop + c.row, col: c.col)
    }

    var selectionSpan: SelectionSpan? {
        guard let s = selection else { return nil }
        let top = viewportTop
        return SelectionSpan(startRow: s.start.row - top, startCol: s.start.col,
                             endRow: s.end.row - top, endCol: s.end.col)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            doubleTap.reset()
            stopCoasting()
            if let diagram = diagramOverlay.diagram(at: p) {
                diagramOverlay.menuTarget = diagram
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: DiagramOverlay.menuID, sourcePoint: p))
                return
            }
            let word = wordRange(at: gridPoint(at: p))
            selectionAnchor = word
            selection = word
            UISelectionFeedbackGenerator().selectionChanged()
            editMenu.dismissMenu()
            selectionLoupe.arm(at: p)
            selectionChanged()
        case .changed:
            guard let anchor = selectionAnchor else { return }
            let q = gridPoint(at: p)
            selection = q < anchor.start ? (q, anchor.end) : (anchor.start, max(q, anchor.end))
            selectionLoupe.move(to: loupePoint(x: p.x, cell: q), caret: caretRect(cell: q, leading: q < anchor.start), in: self)
            selectionChanged()
        case .ended:
            selectionLoupe.end()
            showEditMenu()
        case .cancelled, .failed:
            selectionLoupe.end()
        default:
            break
        }
    }

    @objc private func handleDragHandle(_ g: UIPanGestureRecognizer) {
        guard let s = selection, let handle = g.view as? SelectionHandle else { return }
        // Aim at the text the handle points to, not the finger.
        var p = g.location(in: self)
        p.y += handle.isStart ? cellSizePoints.height * 0.5 : -cellSizePoints.height * 0.5
        let q = gridPoint(at: p)
        switch g.state {
        case .began:
            editMenu.dismissMenu()
            selectionLoupe.move(to: loupePoint(x: p.x, cell: q), caret: caretRect(cell: q, leading: handle.isStart ? q <= s.end : q < s.start), widget: handle, in: self)
        case .changed:
            if handle.isStart {
                selection = q <= s.end ? (q, s.end) : (s.end, q)
            } else {
                selection = q >= s.start ? (s.start, q) : (q, s.start)
            }
            selectionLoupe.move(to: loupePoint(x: p.x, cell: q), caret: caretRect(cell: q, leading: handle.isStart ? q <= s.end : q < s.start), widget: handle, in: self)
            selectionChanged()
        case .ended:
            selectionLoupe.end()
            showEditMenu()
        case .cancelled, .failed:
            selectionLoupe.end()
        default:
            break
        }
    }

    /// The selection edge being placed: the left edge of `q` when the drag
    /// makes it the start, else its right edge.
    private func caretRect(cell q: GridPoint, leading: Bool) -> CGRect {
        let r = rect(col: q.col, row: q.row - viewportTop)
        return CGRect(x: leading ? r.minX : r.maxX - 2, y: r.minY, width: 2, height: r.height)
    }

    /// Where the loupe looks: under the finger horizontally, on the middle
    /// of the line being aimed at vertically, as iOS text views do.
    private func loupePoint(x: CGFloat, cell q: GridPoint) -> CGPoint {
        CGPoint(x: x, y: rect(col: q.col, row: q.row - viewportTop).midY)
    }

    private func selectionChanged() {
        updateHandles()
        setNeedsRender()
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        selectionAnchor = nil
        selectionLoupe.end()
        editMenu.dismissMenu()
        selectionChanged()
    }

    /// The word (or run of non-space) around a point; a blank cell selects itself.
    private func wordRange(at p: GridPoint) -> (start: GridPoint, end: GridPoint) {
        let row = p.row - viewportTop
        let cols = snapshot.cols
        guard row >= 0, row < snapshot.rows, cols > 0 else { return (p, p) }
        func isWord(_ col: Int) -> Bool {
            let c = snapshot.cells[row * cols + col]
            if c.flags & UInt16(TERM_CELL_SPACER) != 0 { return true }
            guard c.ch > 32, let s = Unicode.Scalar(c.ch) else { return false }
            return !"()[]{}<>\"'`|,;".unicodeScalars.contains(s)
        }
        guard isWord(p.col) else { return (p, p) }
        var a = p.col, b = p.col
        while a > 0, isWord(a - 1) { a -= 1 }
        while b < cols - 1, isWord(b + 1) { b += 1 }
        return (GridPoint(row: p.row, col: a), GridPoint(row: p.row, col: b))
    }

    /// Selected text, including rows scrolled out of view; a drawn diagram
    /// reads as its Mermaid source.
    var selectedText: String {
        guard let s = selection else { return "" }
        return DiagramCopy.text(from: s.start, to: s.end, cols: snapshot.cols, drawings: diagramOverlay.drawings) { a, b in
            session.text(fromCol: a.col, row: a.row, toCol: b.col, row: b.row)
        }
    }

    func updateHandles() {
        guard let span = selectionSpan else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let visible = 0..<max(snapshot.rows, 1)
        startHandle.isHidden = !visible.contains(span.startRow)
        endHandle.isHidden = !visible.contains(span.endRow)
        let a = rect(col: span.startCol, row: span.startRow)
        let b = rect(col: span.endCol, row: span.endRow)
        startHandle.place(at: CGPoint(x: a.minX, y: a.minY), lineHeight: a.height, color: tintColor)
        endHandle.place(at: CGPoint(x: b.maxX, y: b.maxY), lineHeight: b.height, color: tintColor)
    }

    private func showEditMenu() {
        guard let span = selectionSpan else { return }
        let a = rect(col: span.startCol, row: max(span.startRow, 0))
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: a.midX, y: a.minY)))
    }
}

extension TerminalView: @preconcurrency UIEditMenuInteractionDelegate {
    /// The system's own Copy and Paste (from canPerformAction): a paste
    /// invoked from them reads the pasteboard without the "Allow Paste"
    /// prompt a custom action triggers.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        if configuration.identifier as? NSString == DiagramOverlay.menuID { return diagramMenu() }
        return suggestedActions.isEmpty ? nil : UIMenu(children: suggestedActions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        if configuration.identifier as? NSString == DiagramOverlay.menuID {
            return CGRect(origin: configuration.sourcePoint, size: .zero).insetBy(dx: -1, dy: -1)
        }
        guard let span = selectionSpan else { return .zero }
        let a = rect(col: span.startCol, row: max(span.startRow, 0))
        let b = rect(col: span.endCol, row: min(span.endRow, max(snapshot.rows - 1, 0)))
        return a.union(b)
    }
}

/// An iOS-style selection handle: a stem along the selection edge with a knob.
final class SelectionHandle: UIView {
    let isStart: Bool
    private let stem = UIView()
    private let knob = UIView()

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        addSubview(stem)
        addSubview(knob)
        knob.layer.cornerRadius = 5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A short selection puts the two frames over each other; each takes the
    /// half its knob is in, so the start handle stays grabbable.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && (isStart ? point.y < bounds.midY : point.y >= bounds.midY)
    }

    /// `corner` is the selection's top-left (start) or bottom-right (end).
    func place(at corner: CGPoint, lineHeight: CGFloat, color: UIColor) {
        let width: CGFloat = 44
        let height = lineHeight + 30
        frame = CGRect(x: corner.x - width / 2, y: isStart ? corner.y - 15 : corner.y - lineHeight - 15,
                       width: width, height: height)
        stem.backgroundColor = color
        knob.backgroundColor = color
        stem.frame = CGRect(x: width / 2 - 1, y: 15, width: 2, height: lineHeight)
        knob.frame = CGRect(x: width / 2 - 5, y: isStart ? 6 : 15 + lineHeight - 1, width: 10, height: 10)
    }
}
