import UIKit

/// Points per centimetre of the screen Term runs on, from its model's real pixel density.
enum ScreenDensity {
  /// Pixels per inch by model identifier, from Apple's device profiles
  /// (CoreSimulator's iPhone Duo: main-screen-pitch 460, both displays, 3x).
  static let pixelsPerInch: [String: CGFloat] = ["iPhone19,4": 460]
  /// A model not listed: 163 points per inch, the densest any iPhone's points
  /// are, so a length in centimetres is never short.
  static let fallbackPointsPerInch: CGFloat = 163

  static func pointsPerCentimetre(model: String, scale: CGFloat) -> CGFloat {
    (pixelsPerInch[model].map { $0 / max(scale, 1) } ?? fallbackPointsPerInch) / 2.54
  }

  /// The device's model identifier ("iPhone19,4"), the simulated one on the simulator.
  static let model: String = {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
    var machine = utsname()
    uname(&machine)
    return withUnsafeBytes(of: machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }()
}

/// Where the rail sits on a terminal and where its marks go: pure, so it is tested on its own.
struct RailLayout: Equatable {
  /// The pane's rows on the terminal.
  var paneTop: CGFloat
  var paneBottom: CGFloat
  /// The terminal's right edge.
  var right: CGFloat
  /// Points per centimetre of the screen.
  var pointsPerCentimetre: CGFloat

  /// The strip at the right edge that takes the rail's touches.
  static let stripWidth: CGFloat = 24
  /// The newest mark stays at least this far above the pane's bottom, easy to see and press.
  static let bottomGap: CGFloat = 1.5
  /// Marks closer than this merge into one.
  static let mergeDistance: CGFloat = 5
  /// A tap this close to a mark takes it.
  static let tapReach: CGFloat = 22
  /// Dots sit this far in from the right edge (their centres).
  static let inset: CGFloat = 5

  /// Where the oldest line maps (its top) and the newest (its bottom).
  var trackTop: CGFloat { paneTop + 4 }
  var trackBottom: CGFloat { max(trackTop, paneBottom - (Self.bottomGap * pointsPerCentimetre).rounded(.up)) }
  /// The strip's touch area.
  var strip: CGRect { CGRect(x: right - Self.stripWidth, y: paneTop, width: Self.stripWidth, height: max(0, paneBottom - paneTop)) }
  /// Below the track: a tap or a slide that ends there goes back to live.
  func isLive(_ y: CGFloat) -> Bool { y > trackBottom + Self.mergeDistance && y <= paneBottom }

  /// A line `fraction` of the way down the history (0 the oldest, 1 the bottom of the screen).
  func y(_ fraction: Double) -> CGFloat {
    trackTop + CGFloat(min(max(fraction, 0), 1)) * (trackBottom - trackTop)
  }

  /// What one dot stands for.
  struct Group: Equatable {
    enum Kind: Equatable { case read, unread, needsYou(unread: Bool) }
    var y: CGFloat
    var kind: Kind
    /// Its messages' ids, oldest first.
    var ids: [String]
    /// What a tap on it opens: the newest unread message, else the newest.
    var target: String
  }

  struct Dot: Equatable {
    var id: String
    var y: CGFloat
    var unread: Bool
    var needsYou: Bool
  }

  /// Dots closer than `mergeDistance` to the first of a run merge: needs
  /// you shows over unread over read, and sits where that message does.
  static func groups(_ dots: [Dot]) -> [Group] {
    var runs: [[Dot]] = []
    for dot in dots.sorted(by: { $0.y < $1.y }) {
      if let first = runs.last?.first, dot.y - first.y < mergeDistance { runs[runs.count - 1].append(dot) } else { runs.append([dot]) }
    }
    return runs.map { run in
      let needs = run.first(where: \.needsYou)
      let unread = run.last(where: \.unread)
      let shown = needs ?? unread ?? run[run.count - 1]
      let kind: Group.Kind = needs != nil ? .needsYou(unread: run.contains(where: \.unread)) : unread != nil ? .unread : .read
      return Group(y: shown.y, kind: kind, ids: run.map(\.id), target: (unread ?? run[run.count - 1]).id)
    }
  }

  /// The group a tap at `y` takes: the nearest within reach.
  static func group(at y: CGFloat, in groups: [Group], reach: CGFloat = tapReach) -> Group? {
    groups.filter { abs($0.y - y) <= reach }.min { abs($0.y - y) < abs($1.y - y) }
  }
}

/// The message rail (the Scrubber): a dot at the right edge of an omp tmux
/// tab for each agent message, where it starts in the pane's history; read
/// 3 pt in the text colour at 30 %, unread 4 pt in the accent, the message
/// the stopped agent waits on a 6 pt ring. Pressing and sliding along the
/// edge shows a glass column with the message under the finger (its first
/// line and age); lifting there, or a tap on a dot, scrolls tmux to it with
/// its first line on the pane's second row. Below the track is live.
/// Touches reach it through the terminal (`owns`, `tap`, `press`); it draws only.
@MainActor
final class MessageRailView: UIView {
  private unowned let terminal: TerminalView
  private(set) var rail: MessageRail?
  private var dots: [CALayer] = []
  private let bracket = CALayer()
  private let column = GlassView()
  private let bigDots = UIView()
  private let ghost = UIView()
  private let callout = GlassView()
  private let age = UILabel()
  private let line = UILabel()
  private let flash = UIView()
  private let flashEdge = CALayer()
  private var viewedTimer: Timer?
  private var settledRefresh: Task<Void, Never>?
  private var scrubbing: String?
  private var scrubLive = false

  private(set) var layout: RailLayout?
  private(set) var groups: [RailLayout.Group] = []

  init(terminal: TerminalView) {
    self.terminal = terminal
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    bracket.cornerRadius = 1
    layer.addSublayer(bracket)

    column.cornerConfiguration = .capsule()
    column.isUserInteractionEnabled = false
    addSubview(column)
    bigDots.isUserInteractionEnabled = false
    addSubview(bigDots)
    ghost.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
    ghost.layer.cornerRadius = 22
    ghost.layer.borderWidth = 1
    addSubview(ghost)
    callout.cornerConfiguration = .corners(radius: .fixed(14))
    callout.isUserInteractionEnabled = false
    addSubview(callout)
    age.font = Chrome.uiFont(.caption)
    age.textColor = Chrome.UI.fg2
    line.font = Chrome.uiFont(.secondary)
    line.textColor = Chrome.UI.fg
    line.numberOfLines = 3
    callout.contentView.addSubview(age)
    callout.contentView.addSubview(line)
    hideScrub(animated: false)

    flash.isUserInteractionEnabled = false
    flash.alpha = 0
    flash.layer.addSublayer(flashEdge)
    addSubview(flash)
    registerForTraitChanges([AppThemeTrait.self]) { (view: MessageRailView, _: UITraitCollection) in view.redraw() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// The rail of the session the terminal shows (nil: none there).
  func bind(_ rail: MessageRail?) {
    guard rail !== self.rail else { return }
    self.rail?.onChange = nil
    self.rail?.isShown = false
    self.rail = rail
    rail?.onChange = { [weak self] in self?.redraw() }
    hideScrub(animated: false)
    shownChanged()
  }

  /// The terminal joined or left a window, or the setting changed. Showing
  /// reads the rail now and again once settled: attaching resizes the tmux
  /// window to this terminal, and omp then rewrites its history.
  func shownChanged() {
    let shown = window != nil && terminal.showsMessageRail
    if let rail, shown != rail.isShown {
      rail.isShown = shown
      if shown {
        rail.refresh(force: true)
        refreshWhenSettled()
      }
    }
    redraw()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    shownChanged()
  }

  /// The terminal's grid changed size: omp rewrites its history for the new
  /// width (resizeScrollback rebuild), so the rail reads it again once that has settled.
  func gridSized() {
    redraw()
    refreshWhenSettled()
  }

  private func refreshWhenSettled() {
    settledRefresh?.cancel()
    settledRefresh = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard let self, !Task.isCancelled, let rail, rail.isShown else { return }
      rail.refresh(force: true)
    }
  }

  /// Whether the rail shows and takes its strip's touches.
  var isActive: Bool { !isHidden && layout != nil && !groups.isEmpty }

  /// Whether a touch at `p` (terminal coordinates) is the rail's.
  func owns(_ p: CGPoint) -> Bool { isActive && layout?.strip.contains(p) == true }

  // MARK: - Drawing

  /// Places everything again: marks, read state, the pane or the terminal's geometry changed.
  func redraw() {
    frame = terminal.bounds
    guard let rail, terminal.showsMessageRail, let pane = rail.pane, !rail.marks.isEmpty, pane.lines > 0 else {
      isHidden = true
      layout = nil
      groups = []
      updateViewedTimer()
      return
    }
    isHidden = false
    let rows = max(terminal.session.rows, 1)
    let first = min(pane.top, rows - 1), last = min(pane.top + pane.height, rows)
    let layout = RailLayout(
      paneTop: terminal.rect(col: 0, row: first).minY, paneBottom: terminal.rect(col: 0, row: max(last - 1, first)).maxY,
      right: bounds.maxX - safeAreaInsets.right,
      pointsPerCentimetre: ScreenDensity.pointsPerCentimetre(model: ScreenDensity.model, scale: traitCollection.displayScale))
    self.layout = layout
    let newest = rail.messages.last?.id
    groups = RailLayout.groups(rail.marks.map { mark in
      RailLayout.Dot(id: mark.message.id, y: layout.y(Double(mark.line - 1) / Double(pane.lines)),
                     unread: !rail.isRead(mark.message.id), needsYou: rail.agentStopped && mark.message.id == newest)
    })
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drawDots(layout)
    drawBracket(layout, pane: pane)
    CATransaction.commit()
    if let scrubbing { showScrub(on: scrubbing, live: scrubLive) }
    updateViewedTimer()
  }

  private func drawDots(_ layout: RailLayout) {
    while dots.count < groups.count {
      let dot = CALayer()
      layer.insertSublayer(dot, below: column.layer)
      dots.append(dot)
    }
    for (i, dot) in dots.enumerated() {
      guard i < groups.count else { dot.isHidden = true; continue }
      dot.isHidden = false
      style(dot, groups[i], at: CGPoint(x: layout.right - RailLayout.inset, y: groups[i].y), scale: 1)
    }
  }

  /// A dot's look: read 3 pt in the text colour at 30 %, unread 4 pt in the
  /// accent, needs you a 6 pt ring (accent while unread, else the text colour at 60 %).
  private func style(_ dot: CALayer, _ group: RailLayout.Group, at center: CGPoint, scale: CGFloat) {
    let fg = Chrome.UI.fg.resolvedColor(with: traitCollection)
    let accent = Chrome.UI.accent.resolvedColor(with: traitCollection)
    let size: CGFloat
    switch group.kind {
    case .read:
      size = 3
      dot.backgroundColor = fg.withAlphaComponent(0.3).cgColor
      dot.borderWidth = 0
    case .unread:
      size = 4
      dot.backgroundColor = accent.cgColor
      dot.borderWidth = 0
    case .needsYou(let unread):
      size = 6
      dot.backgroundColor = UIColor.clear.cgColor
      dot.borderWidth = 1.5 * scale
      dot.borderColor = (unread ? accent : fg.withAlphaComponent(0.6)).cgColor
    }
    let d = size * scale
    dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
    dot.cornerRadius = d / 2
    dot.position = center
  }

  /// In copy mode: a hairline at the edge spanning what the screen shows.
  private func drawBracket(_ layout: RailLayout, pane: MessageRail.Pane) {
    bracket.isHidden = !pane.inCopyMode
    guard pane.inCopyMode else { return }
    let top = Double(pane.historySize - pane.scrollPosition) / Double(pane.lines)
    let y0 = layout.y(top), y1 = layout.y(top + Double(pane.height) / Double(pane.lines))
    bracket.backgroundColor = Chrome.UI.fg.resolvedColor(with: traitCollection).withAlphaComponent(0.18).cgColor
    bracket.frame = CGRect(x: layout.right - 2, y: y0, width: 2, height: max(y1 - y0, 2))
  }

  // MARK: - Touches

  /// A tap in the strip: the mark under it opens; below the track goes back to live.
  func tap(at p: CGPoint) {
    guard let layout else { return }
    if let group = RailLayout.group(at: p.y, in: groups) {
      jump(to: group.target, source: "tap")
    } else if layout.isLive(p.y) {
      DiagnosticLog.record(.rail, "live", "source=tap")
      rail?.backToLive()
    }
  }

  /// Press and slide in the strip: the glass column follows the finger, and lifting opens what it shows.
  func press(_ g: UILongPressGestureRecognizer) {
    guard let layout else { return }
    let y = g.location(in: self).y
    switch g.state {
    case .began, .changed:
      let live = layout.isLive(y)
      let target = live ? nil : RailLayout.group(at: y, in: groups, reach: .infinity)?.target
      if target != scrubbing || live != scrubLive || g.state == .began {
        if g.state != .began { Haptics.selection() }
        scrubbing = target
        scrubLive = live
      }
      showScrub(on: target, live: live, finger: y)
    case .ended:
      let target = scrubbing, live = scrubLive
      hideScrub(animated: true)
      if let target {
        jump(to: target, source: "slide")
      } else if live {
        DiagnosticLog.record(.rail, "live", "source=slide")
        rail?.backToLive()
      }
    default:
      hideScrub(animated: true)
    }
  }

  private func jump(to id: String, source: String) {
    guard let rail else { return }
    let started = CACurrentMediaTime()
    Task { [weak self] in
      let result = await rail.jump(to: id)
      DiagnosticLog.record(.rail, "jump", "source=\(source) result=\(result) seconds=\(DiagnosticLog.seconds(CACurrentMediaTime() - started))")
      guard let self, case .shown(let row) = result, let pane = rail.pane else { return }
      showFlash(row: pane.top + row)
    }
  }

  // MARK: - The scrub column

  private func showScrub(on id: String?, live: Bool, finger: CGFloat? = nil) {
    guard let layout, let rail else { return }
    let right = layout.right
    column.frame = CGRect(x: right - 32, y: layout.paneTop, width: 30, height: layout.paneBottom - layout.paneTop)
    bigDots.frame = bounds
    bigDots.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    for group in groups {
      let dot = CALayer()
      let on = id.map(group.ids.contains) == true
      style(dot, group, at: CGPoint(x: right - 17, y: group.y), scale: on ? 1.6 * 1.4 : 1.6)
      bigDots.layer.addSublayer(dot)
    }
    let shown = id.flatMap { id in groups.first { $0.ids.contains(id) } }
    let y = shown?.y ?? finger ?? layout.trackBottom
    let fg = Chrome.UI.fg.resolvedColor(with: traitCollection)
    ghost.backgroundColor = fg.withAlphaComponent(0.1)
    ghost.layer.borderColor = fg.withAlphaComponent(0.22).cgColor
    ghost.center = CGPoint(x: right - 15, y: finger ?? y)
    if let mark = id.flatMap({ id in rail.marks.first { $0.message.id == id } }) {
      let since = TmuxList.age(mark.message.time, now: .now)
      age.text = since == "now" ? since : since + " ago"
      line.text = mark.text
    } else {
      age.text = nil
      line.text = live ? "Back to live" : nil
    }
    layoutCallout(centerY: y, layout: layout)
    if column.alpha == 0 {
      UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
        self.column.isGlassShown = true
        self.callout.isGlassShown = true
        self.column.alpha = 1
        self.callout.alpha = 1
        self.bigDots.alpha = 1
        self.ghost.alpha = 1
      }
    }
    for dot in dots { dot.opacity = 0 }
  }

  private func layoutCallout(centerY: CGFloat, layout: RailLayout) {
    let width = min(190, layout.right - 40 - 12)
    let inner = width - 24
    let ageHeight: CGFloat = age.text == nil ? 0 : ceil(age.font.lineHeight) + 2
    let lineHeight = line.text == nil ? 0 : ceil(line.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
    let height = 18 + ageHeight + lineHeight
    let y = min(max(centerY - height / 2, layout.paneTop), max(layout.paneTop, layout.paneBottom - height))
    callout.frame = CGRect(x: layout.right - 40 - width, y: y, width: width, height: height)
    age.frame = CGRect(x: 12, y: 9, width: inner, height: ageHeight)
    line.frame = CGRect(x: 12, y: 9 + ageHeight, width: inner, height: lineHeight)
  }

  private func hideScrub(animated: Bool) {
    scrubbing = nil
    scrubLive = false
    let hide = {
      self.column.isGlassShown = false
      self.callout.isGlassShown = false
      self.column.alpha = 0
      self.callout.alpha = 0
      self.bigDots.alpha = 0
      self.ghost.alpha = 0
    }
    if animated {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: hide)
    } else {
      UIView.performWithoutAnimation(hide)
    }
    for dot in dots { dot.opacity = 1 }
  }

  // MARK: - Flash

  /// The jumped-to line, washed in the accent with an accent edge, fading out.
  private func showFlash(row: Int) {
    let r = terminal.rect(col: 0, row: row)
    let accent = Chrome.UI.accent.resolvedColor(with: traitCollection)
    flash.frame = CGRect(x: 0, y: r.minY, width: bounds.width, height: r.height)
    flash.backgroundColor = accent.withAlphaComponent(0.12)
    flashEdge.backgroundColor = accent.cgColor
    flashEdge.frame = CGRect(x: 0, y: 0, width: 3, height: r.height)
    flash.layer.removeAllAnimations()
    flash.alpha = 1
    UIView.animate(withDuration: 1.6, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { self.flash.alpha = 0 }
  }

  // MARK: - Reading

  /// While unread messages exist and the user is reading this terminal,
  /// its pane rows are looked at twice a second.
  private func updateViewedTimer() {
    let needed = window != nil && rail?.unread.isEmpty == false && !isHidden
    if needed, viewedTimer == nil {
      let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.lookAtScreen() }
      }
      timer.tolerance = 0.1
      RunLoop.main.add(timer, forMode: .common)
      viewedTimer = timer
    } else if !needed, let timer = viewedTimer {
      timer.invalidate()
      viewedTimer = nil
    }
  }

  private func lookAtScreen() {
    guard let rail, let pane = rail.pane, SpaceController.isFocusedInFront(terminal) else { return }
    let snapshot = terminal.snapshot
    let base = snapshot.historyRows - snapshot.viewportOffset
    let rows = terminal.session.rows
    let first = min(pane.top, rows - 1), last = min(pane.top + pane.height, rows) - 1
    guard last >= first else { return }
    let screen = terminal.session.text(fromCol: 0, row: base + first, toCol: max(terminal.session.cols - 1, 0), row: base + last)
    let read = rail.saw(screen)
    if !read.isEmpty { DiagnosticLog.record(.rail, "viewed", "count=\(read.count)") }
  }
}
