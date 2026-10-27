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

extension TerminalView {
    func installGestures() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)
    }

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
        if let pan = g as? UIPanGestureRecognizer {
            let v = pan.velocity(in: self)
            return abs(v.y) >= abs(v.x)
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { touchDownTime = touch.timestamp }
        if isCoasting {
            stopCoasting()
            touchStoppedCoasting = true
        }
        super.touchesBegan(touches, with: event)
    }

    // ------------------------------------------------------------ tap

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if touchStoppedCoasting {
            touchStoppedCoasting = false
            doubleTap.reset()
            return
        }
        if selection != nil {
            clearSelection()
            doubleTap.reset()
            return
        }
        let p = g.location(in: self)
        if let diagram = diagramOverlay.diagram(at: p) {
            doubleTap.reset()
            openDiagram(diagram)
            return
        }
        // The first tap has already acted; the second of a quick pair opens
        // Sessions instead of acting, so a program never sees a double-click.
        if doubleTap.tap(at: p, touch: touchDownTime, lift: ProcessInfo.processInfo.systemUptime),
           delegate?.terminalViewDoubleTapped(self) == true {
            return
        }
        guard isFirstResponder else {
            _ = becomeFirstResponder()
            return
        }
        if snapshot.has(TERM_MODE_MOUSE_TRACKING) {
            let c = cell(at: p)
            session.mouse(TERM_MOUSE_PRESS, TERM_MOUSE_LEFT, col: c.col, row: c.row)
            session.mouse(TERM_MOUSE_RELEASE, TERM_MOUSE_LEFT, col: c.col, row: c.row)
        }
    }

    // ------------------------------------------------------------ scroll

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            doubleTap.reset()
            touchStoppedCoasting = false
            stopCoasting()
            scrollRemainder = 0
            lastPanTranslation = 0
            scrollAnchor = cell(at: g.location(in: self))
        case .changed:
            let t = g.translation(in: self).y
            scroll(points: t - lastPanTranslation)
            lastPanTranslation = t
        case .ended:
            let v = g.velocity(in: self).y
            if abs(v) > 120 { startCoasting(velocity: v) }
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
            let button = lines > 0 ? TERM_MOUSE_WHEEL_UP : TERM_MOUSE_WHEEL_DOWN
            for _ in 0..<abs(lines) {
                session.mouse(TERM_MOUSE_PRESS, button, col: scrollAnchor.col, row: scrollAnchor.row)
            }
        } else if snapshot.has(TERM_MODE_ALT_SCREEN) {
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
