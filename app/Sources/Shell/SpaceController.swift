import SwiftUI
import UIKit

/// One window's shells (Blink's spaces): one or two panes, each showing a tab;
/// swipe a pane to page through tabs, two-finger tap for a new one. Layout
/// comes only from the view's bounds, safe area and the fold. The menu panel
/// (sessions overview, files, settings) floats over it.
@MainActor
final class SpaceController: UIViewController, UIGestureRecognizerDelegate, TabHost, TerminalViewDelegate {
  let sceneID: String
  private(set) var tabs: [Tab]
  private var panes: [Pane] = []
  private var lastFocusedPane = 0
  private var layout = SpaceLayout.single(.zero)
  private var foldActive = false
  private let divider = UIView()
  private let failureLabel = UILabel()
  private var drag: Drag?
  private var bannerTimer: Timer?
  private var settingsObserver: NSObjectProtocol?
  private let pager = UIPanGestureRecognizer()
  private let overviewSwipe = UIPanGestureRecognizer()
  private var overviewSwipeFired = false
  private let keyboardAccessory = TerminalInputAccessory()

  let menu = MenuModel()
  private lazy var panel = MenuPanel(model: menu)
  private let dock = MenuDock()
  private let hud = SessionHUD()
  private var dockItems: [MenuTab: UIBarButtonItem] = [:]
  private lazy var toolbarBadge = BarBadge(
    host: { [weak self] in
      guard let nav = self?.navigationController, !nav.isToolbarHidden else { return nil }
      return nav.view
    },
    itemFrame: { [weak self] host in self?.dockItems[.tmux]?.frame(in: host) })
  /// The terminal had the keyboard when the menu opened; it gets it back on close.
  private var menuRestoresFocus = false
  private lazy var inserter = Inserter(presenter: self)

  private struct WeakSpace { weak var space: SpaceController? }
  private static var liveSpaces: [WeakSpace] = []
  /// Every window's controller, oldest first.
  static var live: [SpaceController] { liveSpaces.compactMap(\.space) }
  private struct AttachmentTarget: Hashable {
    var server: String
    var session: String
  }
  private static var pendingAttachments: Set<AttachmentTarget> = []

  init(sceneID: String) {
    self.sceneID = sceneID
    tabs = SessionRegistry.shared.tabs(forScene: sceneID)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func loadView() {
    view = SpaceView(controller: self)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    Self.liveSpaces.removeAll { $0.space == nil }
    Self.liveSpaces.append(WeakSpace(space: self))
    view.backgroundColor = AppSettings.shared.theme.backgroundColor
    divider.backgroundColor = Chrome.UI.line2
    view.addSubview(divider)

    failureLabel.text = "The terminal core did not start."
    failureLabel.textColor = Chrome.UI.fg2
    failureLabel.isHidden = true
    view.addSubview(failureLabel)

    if tabs.isEmpty, let tab = Tab() {
      tabs = [tab]
      tab.start()
    }
    for tab in tabs { adopt(tab) }
    SessionRegistry.shared.setTabs(tabs, forScene: sceneID)

    view.addSubview(hud)
    menu.space = self
    menu.onChange = { [weak self] in self?.menuChanged() }
    addChild(panel)
    view.addSubview(panel.view)
    panel.didMove(toParent: self)
    panel.iconFrame = { [weak self] tab in self?.dockIconFrame(tab) }
    panel.willClose = { [weak self] in self?.menuWillClose() }
    panel.keyboardCrowds = { [weak self] in self?.keyboardCrowdsPanel() }
    dock.onTap = { [weak self] tab in self?.dockTapped(tab) }
    view.addSubview(dock)

    let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
    twoFingerTap.numberOfTouchesRequired = 2
    twoFingerTap.delegate = self
    view.addGestureRecognizer(twoFingerTap)
    let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(toggleMenu(_:)))
    threeFingerTap.numberOfTouchesRequired = 3
    threeFingerTap.delegate = self
    view.addGestureRecognizer(threeFingerTap)
    overviewSwipe.addTarget(self, action: #selector(overviewSwiped(_:)))
    overviewSwipe.minimumNumberOfTouches = 3
    overviewSwipe.maximumNumberOfTouches = 3
    overviewSwipe.delegate = self
    view.addGestureRecognizer(overviewSwipe)
    pager.addTarget(self, action: #selector(page(_:)))
    pager.maximumNumberOfTouches = 1
    pager.delegate = self
    view.addGestureRecognizer(pager)

    toolbarItems = makeToolbarItems()
    if #available(iOS 27.1, *) {
      registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (self: Self, _) in
        self.updateBars()
      }
      // Hinge motion only invalidates layout; the fold region decides it.
      view.addInteraction(UIHingeInteraction { [weak self] _, _ in
        self?.view.setNeedsLayout()
      })
    }
    registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
      self.view.setNeedsLayout()
    }
    settingsObserver = NotificationCenter.default.addObserver(
      forName: .termSettingsChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.settingsChanged() }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    updateBars()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if !panel.isOpen { focusedTab?.view.becomeFirstResponder() }
  }

  isolated deinit {
    if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    AppSettings.shared.theme.isDark ? .lightContent : .darkContent
  }

  override var prefersHomeIndicatorAutoHidden: Bool { true }

  // MARK: - Layout

  /// Called from the view's layoutSubviews so fold changes re-run it.
  fileprivate func layoutPanes() {
    let safe = view.bounds.inset(by: view.safeAreaInsets)
    var fold: CGRect?
    if #available(iOS 27.1, *) {
      fold = view.reservedRegions(kind: .division).first { $0.isActive }?.frame
    }
    let next = SpaceLayout.compute(
      bounds: view.bounds, safe: safe, division: fold, splitWhenFlat: AppSettings.shared.splitWhenFlat,
      regularWidth: traitCollection.horizontalSizeClass == .regular)
    if next != layout {
      if drag != nil { finishDrag(to: nil, animated: false) }
      layout = next
      foldActive = fold != nil
    }

    let frames = layout.panes
    reconcilePanes(count: frames.count)
    for (pane, frame) in zip(panes, frames) where pane.container.transform.isIdentity {
      pane.container.frame = frame
      if drag?.pane !== pane { pane.tab.view.frame = pane.container.bounds }
    }
    if case .sideBySide(let a, let b) = layout, !foldActive {
      // A hairline in the middle of the gap, between the bars rather than across the dock band.
      divider.isHidden = false
      divider.frame = CGRect(x: ((a.maxX + b.minX) / 2 - 0.5).rounded(), y: safe.minY, width: 1, height: safe.height)
    } else {
      divider.isHidden = true
    }
    failureLabel.isHidden = !panes.isEmpty
    failureLabel.sizeToFit()
    failureLabel.center = CGPoint(x: safe.midX, y: safe.midY)
    panel.view.frame = view.bounds
    layoutDock()
  }

  private func reconcilePanes(count: Int) {
    while panes.count > count {
      let pane = panes.removeLast()
      if pane.tab.view.isFirstResponder { panes.first?.tab.view.becomeFirstResponder() }
      pane.tab.view.removeFromSuperview()
      pane.container.removeFromSuperview()
      lastFocusedPane = min(lastFocusedPane, panes.count - 1)
    }
    while panes.count < count {
      let anchor = panes.last.flatMap { last in tabs.firstIndex { $0 === last.tab } } ?? -1
      let candidates = Array(tabs[(anchor + 1)...]) + Array(tabs[..<(anchor + 1)])
      guard let tab = candidates.first(where: { !isShown($0) }) ?? makeTab(at: tabs.count) else { return }
      let pane = Pane()
      view.insertSubview(pane.container, belowSubview: divider)
      panes.append(pane)
      show(tab, in: pane)
    }
  }

  private func isShown(_ tab: Tab) -> Bool {
    panes.contains { $0.tab === tab }
  }

  private func show(_ tab: Tab, in pane: Pane, focus: Bool = false) {
    let old = pane.tabIfSet
    let transfersFocus = focus || old?.view.isFirstResponder == true
    pane.tab = tab
    tab.view.frame = pane.container.bounds
    tab.view.transform = .identity
    pane.container.insertSubview(tab.view, belowSubview: pane.banner)
    // Removing a first responder dismisses the keyboard before its replacement
    // can take it. Hand it directly to the incoming terminal while both are
    // still in the window; the keyboard and every tab's grid stay unchanged.
    if transfersFocus { tab.view.becomeFirstResponder() }
    if let old, old !== tab, old.view.superview === pane.container {
      old.view.removeFromSuperview()
    }
    pane.banner.onReconnect = { [weak tab] in tab?.reconnect() }
    pane.banner.onCancel = { [weak tab] in tab?.upload?.cancel() }
    pane.banner.update(for: tab)
    if pane === focusedPane { view.window?.windowScene?.title = tab.displayTitle }
    Self.tabsChanged()
  }

  // MARK: - Tabs

  private var focusedPane: Pane? {
    if let i = panes.firstIndex(where: { $0.tab.view.isFirstResponder }) { lastFocusedPane = i }
    return panes.indices.contains(lastFocusedPane) ? panes[lastFocusedPane] : panes.first
  }

  var focusedTab: Tab? { focusedPane?.tab }

  private func adopt(_ tab: Tab) {
    tab.host = self
    tab.view.delegate = self
    tab.view.keyboardAccessory = keyboardAccessory
  }

  private func makeTab(at index: Int) -> Tab? {
    guard let tab = Tab() else { return nil }
    adopt(tab)
    tabs.insert(tab, at: min(index, tabs.count))
    tab.start()
    SessionRegistry.shared.setTabs(tabs, forScene: sceneID)
    Self.tabsChanged()
    return tab
  }

  /// Opens a new shell after the one in `pane` and shows it there.
  func newTab(in pane: Pane? = nil) {
    guard let pane = pane ?? focusedPane else { return }
    let index = (tabs.firstIndex { $0 === pane.tab } ?? tabs.count - 1) + 1
    guard let tab = makeTab(at: index) else { return }
    show(tab, in: pane, focus: true)
  }

  /// Shows `tab` in the focused pane, or focuses the pane already showing it.
  func select(_ tab: Tab, focus: Bool = true) {
    if let i = panes.firstIndex(where: { $0.tab === tab }) {
      lastFocusedPane = i
      if focus { tab.view.becomeFirstResponder() }
      Self.tabsChanged()
      return
    }
    guard let pane = focusedPane else { return }
    show(tab, in: pane, focus: focus)
  }

  func close(_ tab: Tab) {
    guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
    tab.disconnect()
    tabs.remove(at: index)
    if let pane = panes.first(where: { $0.tab === tab }) {
      let before = tabs[..<min(index, tabs.count)].reversed()
      let after = tabs[min(index, tabs.count)...]
      let replacement = (Array(before) + Array(after)).first { !isShown($0) } ?? makeTab(at: index)
      if let replacement {
        show(replacement, in: pane)
      } else {
        tab.view.removeFromSuperview()
      }
    }
    keyboardAccessory.remove(tab.view.smartKeys)
    SessionRegistry.shared.setTabs(tabs, forScene: sceneID)
    Self.tabsChanged()
  }

  /// Puts `tab` at `index` of the swipe order (a drop on the overview); the
  /// panes keep the tabs they show.
  func move(_ tab: Tab, to index: Int) {
    guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
    let to = min(max(index, 0), tabs.count - 1)
    guard to != from else { return }
    tabs.insert(tabs.remove(at: from), at: to)
    SessionRegistry.shared.setTabs(tabs, forScene: sceneID)
    Self.tabsChanged()
  }

  /// Whether the window shows two panes (Two Panes on the Duo's inner display, flat).
  var showsTwoPanes: Bool { panes.count == 2 }

  /// With Two Panes, the pane showing `tab`: 0 left, 1 right.
  func paneIndex(showing tab: Tab) -> Int? {
    guard showsTwoPanes else { return nil }
    return panes.firstIndex { $0.tab === tab }
  }

  /// With Two Panes, shows `tab` in pane `index`; when the other pane shows
  /// it, the two swap.
  func place(_ tab: Tab, inPane index: Int) {
    guard showsTwoPanes, panes.indices.contains(index), tabs.contains(where: { $0 === tab }) else { return }
    let pane = panes[index]
    guard pane.tab !== tab else { return }
    if let other = panes.first(where: { $0.tab === tab }) { show(pane.tab, in: other) }
    show(tab, in: pane)
  }

  /// Opens `host` in the focused tab when it sits at the prompt, else in a new tab.
  func open(_ host: Host) {
    closeMenu()
    let tab = promptTab(focus: true)
    tab?.enter("\(host.transport.rawValue) \(host.alias)")
    tab?.connect(host)
  }

  /// The focused tab when it sits at the prompt, else a new tab after it.
  private func promptTab(focus: Bool) -> Tab? {
    if let focused = focusedTab, !focused.isConnected, focused.connecting == nil {
      if focus { focused.view.becomeFirstResponder() }
      return focused
    }
    guard let pane = focusedPane else { return nil }
    let index = (tabs.firstIndex { $0 === pane.tab } ?? tabs.count - 1) + 1
    guard let tab = makeTab(at: index) else { return nil }
    show(tab, in: pane, focus: focus)
    // Connecting sends the tab's grid size: laid out now, it is the pane's
    // instead of a fresh terminal's 80x24, which tmux would first draw at.
    pane.container.layoutIfNeeded()
    return tab
  }

  /// Goes into tmux session `name` on `host`: the tab already attached to it
  /// comes forward (from any window); otherwise a tab attaches to it,
  /// showing `preview` (the session's last captured screen) until it draws.
  func attach(_ host: Host, session name: String, preview: Data? = nil) async {
    if let open = Self.live.lazy.flatMap(\.tabs).first(where: {
      $0.tmuxSession == name && $0.target.map { TmuxStore.shared.sameServer($0, host) } == true
    }) {
      zoom(into: open, fromTile: false)
      return
    }
    let selection = AttachmentTarget(server: host.serverKey, session: name)
    guard Self.pendingAttachments.insert(selection).inserted else { return }
    defer { Self.pendingAttachments.remove(selection) }
    let candidates = Self.live.flatMap(\.tabs).filter {
      $0.target.map { TmuxStore.shared.sameServer($0, host) } == true
    }
    await TmuxAttachment.refresh(candidates, timeout: .seconds(3))
    if let open = Self.live.flatMap(\.tabs).first(where: { $0.tmuxSession == name && $0.target.map { TmuxStore.shared.sameServer($0, host) } == true }) {
      zoom(into: open, fromTile: false)
      return
    }
    let focus = menuRestoresFocus
    menuRestoresFocus = false
    let tab = promptTab(focus: focus)
    closeMenu()
    guard let tab else { return }
    var target = host
    target.startupCommand = Tmux.attachCommand(name)
    tab.enter("tmux \(host.alias) \(name)")
    tab.connect(target, tmuxSession: name, preview: preview)
  }

  /// A new local shell from the menu's + page.
  func newTabFromMenu() {
    menuRestoresFocus = false
    closeMenu()
    newTab()
  }

  /// What a Files pane (`pane`, a MenuModel.filesPanes id) may do to this window's terminals.
  func filesContext(pane: String, spec: ConnectSpec?, tmuxSession: String?) -> FilesContext {
    FilesContext(
      spec: spec, tmuxSession: tmuxSession,
      insertIntoTerminal: { [weak self] text in self?.focusedTab?.current.write(Data(text.utf8)) },
      openTerminal: { [weak self] spec, directory in self?.openTerminal(spec, in: directory) },
      dismiss: { [weak self] in self?.closeMenu() },
      browserReady: { [weak self] browser in self?.menu.register(browser, forPane: pane) })
  }

  /// Files' "Open Terminal Here": a login shell on the browsed host in `directory`.
  private func openTerminal(_ spec: ConnectSpec, in directory: String) {
    let focused = focusedTab?.target
    let same = { (h: Host) in h.knownHostsKey == spec.knownHostsKey && h.user == spec.user }
    var host = focused.flatMap { same($0) ? $0 : nil }
      ?? ConfigStore.shared.hosts.first { same($0) && $0.alias == spec.label }
      ?? ConfigStore.shared.hosts.first(where: same)
      ?? Host(alias: spec.label, hostname: spec.hostname, port: spec.port, user: spec.user, transport: spec.transport)
    // mosh-server execs its command without a shell, so the cd needs one.
    host.startupCommand = "sh -c " + Command.shellQuote("cd \(Command.shellQuote(directory)) && exec \"$SHELL\" -l")
    menuRestoresFocus = false
    open(host)
  }

  /// Every window's overview follows tab and name changes; a session he
  /// has just entered has nothing new for him.
  static func tabsChanged() {
    for space in live { space.menu.revision &+= 1 }
    TmuxStore.shared.seeViewed()
  }

  /// The tmux sessions he is looking at: the focused tab of each window in
  /// front, by its host.
  static var viewedTmuxSessions: [(Host, String)] {
    live.compactMap { space in
      guard space.view.window?.windowScene?.activationState == .foregroundActive,
            let tab = space.focusedTab, let host = tab.target, let name = tab.tmuxSession else { return nil }
      return (host, name)
    }
  }

  /// The tmux icons' badge: sessions whose agent stopped for him. UIKit runs
  /// this again whenever the count changes.
  override func updateProperties() {
    super.updateProperties()
    let count = TmuxStore.shared.unreadCount
    dock.setBadge(count, on: .tmux)
    toolbarBadge.count = count
    dockItems[.tmux]?.accessibilityValue = count > 0 ? "\(count) new" : nil
    view.setNeedsLayout()
  }

  static func openWindow() {
    var request = UISceneSessionActivationRequest(role: .windowApplication)
    request.userActivity = NSUserActivity(activityType: SceneDelegate.windowActivity)
    UIApplication.shared.activateSceneSession(for: request, errorHandler: nil)
  }

  // MARK: - TabHost

  func tabDidChange(_ tab: Tab) {
    if let pane = panes.first(where: { $0.tab === tab }) {
      pane.banner.update(for: tab)
      if pane === focusedPane { view.window?.windowScene?.title = tab.displayTitle }
    }
    updateBannerTimer()
    Self.tabsChanged()
  }

  func tabWantsClose(_ tab: Tab) { close(tab) }

  func tabWantsSettings(_ tab: Tab) { openMenu(.settings) }

  func tabWantsTmuxSessions(_ tab: Tab, host: Host) { showTmux(of: host) }

  func terminalView(_ view: TerminalView, didChangeFontSize size: CGFloat) {
    AppSettings.shared.fontSize = Double(size)
  }

  /// Files takes a paste while it is in front (into its folder); otherwise
  /// images and files upload to the terminal's host and their paths are
  /// typed, and text is left to the terminal.
  func terminalView(_ view: TerminalView, paste clip: Clip) -> Bool {
    if panel.isOpen, menu.tab == .files, let browser = menu.shownBrowser {
      if let dir = browser.current { Task { await browser.paste(clip, into: dir) } }
      return true
    }
    guard clip.text == nil, !clip.isEmpty, let tab = tabs.first(where: { $0.view === view }) else { return false }
    Task { await inserter.send(clip, to: tab) }
    return true
  }

  func terminalView(_ view: TerminalView, insertFrom source: InsertSource) {
    guard let tab = tabs.first(where: { $0.view === view }) else { return }
    inserter.pick(source, for: tab)
  }

  /// Tabs off screen take the focused pane's grid as it changes (keyboard,
  /// rotation, fold, font), so showing one is no resize: a program redraws
  /// for every resize, and omp can rewrite its whole transcript.
  func terminalView(_ view: TerminalView, didSizeGrid grid: GridSize) {
    guard focusedPane?.tab.view === view else { return }
    for tab in tabs where !isShown(tab) { tab.view.fit(grid) }
  }

  func terminalView(_ view: TerminalView, voiceNotice text: String) {
    tabs.first { $0.view === view }?.showNotice(text, failed: true, for: 8)
  }

  func terminalViewDictationDestination(_ view: TerminalView) -> DictationDestination? {
    tabs.first { $0.view === view }?.dictationDestination
  }

  func terminalViewOpensVoiceSettings(_ view: TerminalView) {
    menu.settingsStart = .voice
    openMenu(.settings)
  }

  /// A double tap on a terminal opens Sessions. With the menu open, or a
  /// window still zooming, it is two plain taps.
  func terminalViewDoubleTapped(_ view: TerminalView) -> Bool {
    guard !panel.isOpen, menu.zooming == nil, tabs.contains(where: { $0.view === view }) else { return false }
    openMenu(.sessions)
    return true
  }

  private func updateBannerTimer() {
    let needed = panes.contains { $0.tab.unreachable || ($0.tab.isConnected && $0.tab.connecting != nil) }
    if needed, bannerTimer == nil {
      bannerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          for pane in self.panes { pane.banner.update(for: pane.tab) }
        }
      }
    } else if !needed {
      bannerTimer?.invalidate()
      bannerTimer = nil
    }
  }

  private func settingsChanged() {
    view.backgroundColor = AppSettings.shared.theme.backgroundColor
    setNeedsStatusBarAppearanceUpdate()
    view.setNeedsLayout()
  }

  // MARK: - Gestures

  @objc private func twoFingerTap(_ g: UITapGestureRecognizer) {
    newTab(in: pane(at: g.location(in: view)))
  }

  private func pane(at point: CGPoint) -> Pane? {
    panes.first { $0.container.frame.contains(point) }
  }

  /// Every touch on the Screen is the Mac's: none of the window's own gestures see it.
  func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var view = touch.view
    while let v = view {
      if v is ScreenView { return false }
      view = v.superview
    }
    return true
  }

  func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    if g === overviewSwipe {
      let v = overviewSwipe.velocity(in: view)
      return !panel.isOpen && v.y < 0 && abs(v.y) > abs(v.x)
    }
    guard g === pager else { return true }
    let v = pager.velocity(in: view)
    return !panel.isOpen && abs(v.x) > abs(v.y) * 1.5 && pane(at: pager.location(in: view)) != nil
  }

  /// Three fingers up: the overview (the phone twin of Mission Control).
  @objc private func overviewSwiped(_ g: UIPanGestureRecognizer) {
    switch g.state {
    case .began:
      overviewSwipeFired = false
    case .changed:
      guard !overviewSwipeFired, g.translation(in: view).y < -24 else { return }
      overviewSwipeFired = true
      openMenu(.sessions)
    default:
      break
    }
  }

  private struct Drag {
    let pane: Pane
    let previous: Tab?
    let next: Tab?
  }

  /// The tab `step` places from the pane's tab, skipping tabs on screen elsewhere.
  private func neighbor(of pane: Pane, step: Int) -> Tab? {
    guard var i = tabs.firstIndex(where: { $0 === pane.tab }) else { return nil }
    while true {
      i += step
      guard tabs.indices.contains(i) else { return nil }
      if !isShown(tabs[i]) { return tabs[i] }
    }
  }

  @objc private func page(_ g: UIPanGestureRecognizer) {
    switch g.state {
    case .began:
      guard let pane = pane(at: g.location(in: view)) else { return }
      let d = Drag(pane: pane, previous: neighbor(of: pane, step: -1), next: neighbor(of: pane, step: 1))
      for tab in [d.previous, d.next].compactMap({ $0 }) {
        tab.view.frame = pane.container.bounds
        pane.container.insertSubview(tab.view, belowSubview: pane.banner)
        // Sliding views keep the geometry they have, so measure it here, in place.
        tab.view.layoutIfNeeded()
      }
      pane.banner.isHidden = true
      drag = d
      fallthrough
    case .changed:
      guard let d = drag else { return }
      let w = d.pane.container.bounds.width
      var x = g.translation(in: view).x
      if (x < 0 && d.next == nil) || (x > 0 && d.previous == nil) { x *= 0.25 }
      apply(PagerStrip.dragged(by: x, width: w), to: d, current: d.pane.tab)
      trackHUD(d, offset: x / max(w, 1))
    case .ended:
      guard let d = drag else { return }
      let w = d.pane.container.bounds.width
      let x = g.translation(in: view).x
      let v = g.velocity(in: view).x
      var target: Tab?
      if x < 0, x < -w * 0.35 || v < -500 { target = d.next }
      if x > 0, x > w * 0.35 || v > 500 { target = d.previous }
      finishDrag(to: target, animated: true)
    default:
      if drag != nil { finishDrag(to: nil, animated: true) }
    }
  }

  private func apply(_ strip: PagerStrip, to d: Drag, current: Tab) {
    current.view.transform = CGAffineTransform(translationX: strip.current, y: 0)
    d.previous?.view.transform = CGAffineTransform(translationX: strip.previous, y: 0)
    d.next?.view.transform = CGAffineTransform(translationX: strip.next, y: 0)
  }

  private func finishDrag(to target: Tab?, animated: Bool) {
    guard let d = drag else { return }
    drag = nil
    let w = d.pane.container.bounds.width
    let current = d.pane.tab
    settleHUD(on: target ?? current, in: d.pane)
    let moves = {
      let page: PagerStrip.Page = target == nil ? .current : target === d.next ? .next : .previous
      self.apply(PagerStrip.resting(on: page, width: w), to: d, current: current)
    }
    let done = { [weak self] in
      guard let self else { return }
      if let target { show(target, in: d.pane) }
      for tab in [d.previous, d.next, current].compactMap({ $0 }) where tab !== (target ?? current) {
        tab.view.removeFromSuperview()
        tab.view.transform = .identity
      }
      if target == nil {
        d.pane.banner.update(for: current)
      }
      // At rest: measure the grid it held while sliding.
      (target ?? current).view.setNeedsLayout()
    }
    if animated {
      UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                     options: [.allowUserInteraction, .beginFromCurrentState], animations: moves) { _ in done() }
    } else {
      moves()
      done()
    }
  }

  // MARK: - Session HUD

  /// Middle of the pane's visible part (above the keyboard).
  private func hudCenter(for pane: Pane) -> CGPoint {
    var area = pane.container.frame.intersection(view.bounds.inset(by: view.safeAreaInsets))
    let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
    if keyboardTop > area.minY, keyboardTop < area.maxY { area.size.height = keyboardTop - area.minY }
    return CGPoint(x: area.midX.rounded(), y: area.midY.rounded())
  }

  /// `offset` is the swipe in pane widths: negative toward the next tab.
  private func trackHUD(_ d: Drag, offset: CGFloat) {
    guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === d.pane.tab }) else { return }
    var position = CGFloat(i)
    let toward = offset < 0 ? d.next : d.previous
    if let toward, let j = tabs.firstIndex(where: { $0 === toward }) {
      position += CGFloat(j - i) * min(abs(offset), 1)
    }
    view.bringSubviewToFront(hud)
    hud.track(names: tabs.map(\.sessionName), position: position, center: hudCenter(for: d.pane))
  }

  private func settleHUD(on tab: Tab, in pane: Pane) {
    guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
    view.bringSubviewToFront(hud)
    hud.settle(names: tabs.map(\.sessionName), index: i, center: hudCenter(for: pane))
  }

  // MARK: - Actions (also reachable up the responder chain, e.g. from Smart Keys)

  @objc func newSession(_ sender: Any?) { newTab() }

  @objc func closeSession(_ sender: Any?) {
    if let tab = focusedTab { close(tab) }
  }

  @objc func nextSession(_ sender: Any?) { step(1) }

  @objc func previousSession(_ sender: Any?) { step(-1) }

  private func step(_ delta: Int) {
    guard let pane = focusedPane, let tab = neighbor(of: pane, step: delta) else { return }
    show(tab, in: pane, focus: true)
    settleHUD(on: tab, in: pane)
  }

  @objc func showSettings(_ sender: Any?) { openMenu(.settings) }

  @objc func showOverview(_ sender: Any?) { openMenu(.sessions) }

  /// Double-tap ⌘ on Smart Keys and three-finger tap: the menu on its last tab.
  @objc func toggleMenu(_ sender: Any?) {
    if panel.isOpen { closeMenu() } else { openMenu() }
  }

  func showHistory(for tab: Tab) {
    guard let target = tab.target, let source = tab.historySource else { return }
    menuRestoresFocus = false
    closeMenu()
    present(HistoryViewController(host: target, source: source), animated: true)
  }

  /// `tmux host` at the prompt: the tmux tab, scrolled to that host.
  func showTmux(of host: Host) {
    menu.tmuxTarget = host.serverKey
    openMenu(.tmux)
  }

  override var keyCommands: [UIKeyCommand]? {
    // While the Screen shows, ⌘W and the rest are the Mac's.
    if panel.isOpen, menu.tab == .screen { return nil }
    return [
      UIKeyCommand(title: "New Shell", action: #selector(newSession(_:)), input: "t", modifierFlags: .command),
      UIKeyCommand(title: "Close Shell", action: #selector(closeSession(_:)), input: "w", modifierFlags: .command),
      UIKeyCommand(title: "Next Shell", action: #selector(nextSession(_:)), input: "]", modifierFlags: [.command, .shift]),
      UIKeyCommand(title: "Previous Shell", action: #selector(previousSession(_:)), input: "[", modifierFlags: [.command, .shift]),
      UIKeyCommand(title: "Show All Sessions", action: #selector(showOverview(_:)), input: "\\", modifierFlags: [.command, .shift]),
      UIKeyCommand(title: "Settings", action: #selector(showSettings(_:)), input: ",", modifierFlags: .command),
    ]
  }

  // MARK: - Menu panel

  /// Opens the menu on `tab` (nil: the last one used). Opening on the
  /// overview shrinks the terminal into its tile; other tabs scale in.
  func openMenu(_ tab: MenuTab? = nil, fromIcon: Bool = false) {
    let tab = tab ?? menu.tab
    guard !panel.isOpen else {
      if tab == .sessions { menu.sessionsPage = .overview }
      menu.tab = tab
      return
    }
    // A closed panel opens straight onto its tab, with no cross-fade from
    // the one it closed on. The model puts every page back at its root.
    var quiet = Transaction()
    quiet.disablesAnimations = true
    withTransaction(quiet) { menu.tab = tab }
    hud.hide()
    if drag != nil { finishDrag(to: nil, animated: false) }
    let terminal = focusedTab?.view
    menuRestoresFocus = terminal?.isFirstResponder == true
    if menuRestoresFocus, !panel.fitsAboveKeyboard { terminal?.resignFirstResponder() }
    view.bringSubviewToFront(panel.view)
    view.bringSubviewToFront(dock)

    if fromIcon {
      panel.open(tab, fromIcon: true)
    } else if tab == .sessions, let pane = focusedPane, !UIAccessibility.isReduceMotionEnabled {
      openOverview(shrinking: pane)
    } else {
      panel.open(tab, fromIcon: false)
    }
  }

  func closeMenu() {
    panel.close()
  }

  /// As when the panel opens without room above the keyboard: the terminal
  /// gives up the keyboard while the panel is open and gets it back on close.
  private func keyboardCrowdsPanel() {
    guard let terminal = focusedTab?.view, terminal.isFirstResponder else { return }
    menuRestoresFocus = true
    terminal.resignFirstResponder()
  }

  /// The card fades in while the terminal shrinks into its window above it,
  /// then hands over to the window's live thumbnail.
  private func openOverview(shrinking pane: Pane) {
    let tab = pane.tab
    menu.zooming = tab.id
    panel.fadeIn(.sessions, duration: Chrome.Panel.zoomFadeIn)
    // The overview places its windows during the hosting view's layout pass.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard panel.isOpen, menu.tab == .sessions, pane.tab === tab, let thumbnail = thumbnail(of: tab) else {
        menu.zooming = nil
        return
      }
      zoom(pane, into: thumbnail, towardTile: true) { [weak self] in self?.menu.zooming = nil }
    }
  }

  /// Tapping a window: that session takes the screen, growing out of its
  /// thumbnail (`fromTile` false: it just comes forward, as from the tmux tab).
  func zoom(into tab: Tab, fromTile: Bool = true) {
    guard tabs.contains(where: { $0 === tab }) else {
      // Another window's session: bring that window forward.
      closeMenu()
      if let other = Self.live.first(where: { $0.tabs.contains { $0 === tab } }),
         let session = other.view.window?.windowScene?.session {
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session), errorHandler: nil)
        other.select(tab)
      }
      return
    }
    let thumbnail = fromTile ? thumbnail(of: tab) : nil
    let focus = menuRestoresFocus
    menuRestoresFocus = false
    select(tab, focus: focus)
    guard let pane = panes.first(where: { $0.tab === tab }), let thumbnail, !UIAccessibility.isReduceMotionEnabled else {
      closeMenu()
      return
    }
    menu.zooming = tab.id
    panel.fadeOut(duration: Chrome.Panel.zoomFadeOut) {}
    zoom(pane, into: thumbnail, towardTile: false) { [weak self] in self?.menu.zooming = nil }
  }

  /// `tab`'s live thumbnail on the overview and where it draws the grid, in this view's space.
  private func thumbnail(of tab: Tab) -> (frame: CGRect, grid: ThumbnailGrid)? {
    guard let shown = menu.thumbnails.view(showing: tab.current), shown.bounds.width > 0,
          let grid = shown.currentGrid() else { return nil }
    let frame = shown.convert(shown.bounds, to: view)
    let ratio = frame.width / shown.bounds.width
    return (frame, ThumbnailGrid(origin: shown.convert(grid.origin, to: view),
                                 cell: CGSize(width: grid.cell.width * ratio, height: grid.cell.height * ratio)))
  }

  /// Scales `pane` between full size and the thumbnail, above the panel, the
  /// terminal's cells landing on the thumbnail's; at the small end everything
  /// outside the thumbnail is masked.
  private func zoom(_ pane: Pane, into thumbnail: (frame: CGRect, grid: ThumbnailGrid), towardTile: Bool,
                    completion: @escaping () -> Void) {
    let container = pane.container
    let terminal = pane.tab.view
    terminal.layoutIfNeeded()
    let cell = terminal.cellSizePoints
    let scale = max(terminal.scale, 1)
    guard cell.width > 0, thumbnail.grid.cell.width > 0 else { completion(); return }
    let origin = terminal.convert(CGPoint(x: terminal.gridOrigin.x / scale, y: terminal.gridOrigin.y / scale), to: container)

    // Container point p lands at center + s * (p - boundsCenter) + t.
    let s = thumbnail.grid.cell.width / cell.width
    let c = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
    let t = CGPoint(x: thumbnail.grid.origin.x - container.center.x - s * (origin.x - c.x),
                    y: thumbnail.grid.origin.y - container.center.y - s * (origin.y - c.y))
    let small = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: t.x, ty: t.y)
    // The thumbnail in container space: what stays visible at the small end.
    let f = thumbnail.frame
    let shown = CGRect(x: c.x + (f.minX - container.center.x - t.x) / s, y: c.y + (f.minY - container.center.y - t.y) / s,
                       width: f.width / s, height: f.height / s)
    let fullPath = Self.maskPath(container.bounds, bottomRadius: 0)
    let tilePath = Self.maskPath(shown, bottomRadius: Chrome.Radius.tile / s)

    // The mask's path is already its end value; it morphs there on the transform's spring.
    let mask = CAShapeLayer()
    mask.path = towardTile ? tilePath : fullPath
    container.layer.mask = mask
    view.insertSubview(container, aboveSubview: panel.view)
    view.bringSubviewToFront(dock)
    container.transform = towardTile ? .identity : small

    let morph = CASpringAnimation(perceptualDuration: Chrome.Panel.zoom, bounce: 0)
    morph.keyPath = "path"
    morph.fromValue = towardTile ? fullPath : tilePath
    morph.toValue = towardTile ? tilePath : fullPath
    morph.duration = morph.settlingDuration
    mask.add(morph, forKey: "path")

    let animator = UIViewPropertyAnimator(duration: Chrome.Panel.zoom, timingParameters: Chrome.Panel.spring(Chrome.Panel.zoom))
    animator.addAnimations { container.transform = towardTile ? small : .identity }
    animator.addCompletion { [weak self] _ in
      guard let self else { return }
      container.layer.mask = nil
      container.transform = .identity
      view.insertSubview(container, belowSubview: divider)
      view.setNeedsLayout()
      completion()
    }
    animator.startAnimation()
  }

  /// A rectangle with rounded bottom corners (a window's screen under its
  /// title bar), drawn with the same elements at every radius so the two ends
  /// of a zoom morph into each other.
  private static func maskPath(_ r: CGRect, bottomRadius radius: CGFloat) -> CGPath {
    // Cubic control points of a quarter circle sit 0.5523 of the radius along its tangents.
    let k = radius * (1 - 0.5523)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    path.addCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - k),
                  control2: CGPoint(x: r.maxX - k, y: r.maxY))
    path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    path.addCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control1: CGPoint(x: r.minX + k, y: r.maxY),
                  control2: CGPoint(x: r.minX, y: r.maxY - k))
    path.closeSubpath()
    return path
  }

  private func menuWillClose() {
    panel.view.endEditing(true)
    if menuRestoresFocus, let terminal = focusedTab?.view, !terminal.isFirstResponder {
      terminal.becomeFirstResponder()
    }
    menuRestoresFocus = false
  }

  private func menuChanged() {
    let open = menu.isOpen ? menu.tab : nil
    dock.setSelected(open)
    for (tab, item) in dockItems { item.tintColor = tab == open ? Chrome.UI.accent : nil }
    // The Screen takes the keyboard (its own, or a hardware one's keys): the terminal hands it over until the panel closes.
    if open == .screen, let terminal = focusedTab?.view, terminal.isFirstResponder {
      menuRestoresFocus = true
      terminal.resignFirstResponder()
    }
  }

  /// A dock icon: opens the panel out of itself, switches to its tab when the
  /// panel shows another, closes the panel when it shows this one.
  private func dockTapped(_ tab: MenuTab) {
    if panel.isOpen {
      if menu.tab == tab { closeMenu() } else { menu.tab = tab }
    } else {
      openMenu(tab, fromIcon: true)
    }
  }

  private func dockIconFrame(_ tab: MenuTab) -> CGRect? {
    if !dock.isHidden, let frame = dock.iconFrame(tab, in: view) { return frame }
    guard navigationController?.isToolbarHidden == false, let item = dockItems[tab],
          let frame = item.frame(in: view), frame.width > 0 else { return nil }
    let side = min(frame.width, frame.height, 34)
    return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
  }

  // MARK: - Dock placement (iPhone Duo)

  /// The band above the safe area is free left of the clock on the inner
  /// display in portrait; the vertical bar (outer display, inner landscape)
  /// holds the toolbar instead. The status bar reports itself 2 pt tall there,
  /// so the band is the top safe-area inset, cut at the clock's occlusion region.
  private var bandDockFrame: CGRect? {
    guard traitCollection.horizontalSizeClass == .regular, view.bounds.height > view.bounds.width,
          navigationController?.isToolbarHidden != false else { return nil }
    let top = view.safeAreaInsets.top
    let size = dock.intrinsicContentSize
    guard top >= size.height else { return nil }
    var right = view.bounds.maxX
    if #available(iOS 27.1, *),
       let clock = view.reservedRegions(kind: .occlusion).first(where: { $0.isActive && $0.frame.minY < top }) {
      right = clock.frame.minX
    }
    let x = view.safeAreaInsets.left + 14
    guard x + size.width <= right else { return nil }
    // On the clock's line: 34 pt above the safe area on the Duo inner display (measured).
    return CGRect(x: x, y: (top - 34 - size.height / 2).rounded(), width: size.width, height: size.height)
  }

  private func layoutDock() {
    toolbarBadge.follow()
    let frame = bandDockFrame
    dock.isHidden = frame == nil
    guard let frame else { return }
    dock.frame = frame
    view.bringSubviewToFront(dock)
  }

  /// The toolbar exists only where the system puts it in the vertical bar
  /// (outer display, inner landscape); elsewhere the terminal keeps the screen.
  private func updateBars() {
    var vertical = false
    if #available(iOS 27.1, *) {
      vertical = traitCollection.verticalBarEdge != .unspecified
    }
    navigationController?.setToolbarHidden(!vertical, animated: false)
    view.setNeedsLayout()
  }

  private func makeToolbarItems() -> [UIBarButtonItem] {
    MenuTab.allCases.map { tab in
      let item = UIBarButtonItem(title: tab.title, image: UIImage(systemName: tab.symbol),
                                 primaryAction: UIAction { [weak self] _ in self?.dockTapped(tab) })
      dockItems[tab] = item
      return item
    }
  }

  /// The navigation controller laid the bar out: the tmux icon may have moved.
  func barDidLayout() {
    toolbarBadge.follow()
  }
}

/// A rectangle of the window showing one tab, with its reconnect banner.
@MainActor
final class Pane {
  let container = UIView()
  let banner = StatusBanner()
  private(set) var tabIfSet: Tab?

  var tab: Tab {
    get { tabIfSet! }
    set { tabIfSet = newValue }
  }

  init() {
    container.clipsToBounds = true
    banner.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(banner)
    NSLayoutConstraint.activate([
      // Below the notch or Dynamic Island, which covers the pane's top edge.
      banner.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
      banner.centerXAnchor.constraint(equalTo: container.safeAreaLayoutGuide.centerXAnchor),
      banner.widthAnchor.constraint(lessThanOrEqualTo: container.safeAreaLayoutGuide.widthAnchor, constant: -16),
    ])
  }
}

/// Root view that re-runs pane layout on every layout pass, including the
/// ones the system triggers when the fold region changes.
private final class SpaceView: UIView {
  weak var controller: SpaceController?

  init(controller: SpaceController) {
    self.controller = controller
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    controller?.layoutPanes()
  }
}
