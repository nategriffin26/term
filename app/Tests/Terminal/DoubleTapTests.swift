import UIKit
import XCTest
@testable import Term

/// A quick double tap at the terminal's right edge opens Sessions without
/// moving the keyboard; a single tap there is held for the double-tap window;
/// elsewhere a tap acts at once.
@MainActor
final class DoubleTapTests: XCTestCase {
  private var window: UIWindow?
  private var delegateStub: Stub?
  private var space: SpaceController?
  private var savedSplit: Bool?

  override func tearDown() async throws {
    if let space { SessionRegistry.shared.discardScenes([space.sceneID]) }
    if let savedSplit { AppSettings.shared.splitWhenFlat = savedSplit }
    window?.isHidden = true
    window = nil
    delegateStub = nil
    space = nil
  }

  private final class FakeTap: TimedTapGestureRecognizer {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
  }

  /// The pager's pan, still: it begins and ends where it started.
  private final class FakePan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .began
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
      get { phase }
      set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { .zero }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
  }

  private final class Stub: TerminalViewDelegate {
    var edgeBand = true
    var takesDoubleTap = true
    var doubleTaps = 0
    func terminalViewHasEdgeBand(_ view: TerminalView) -> Bool { edgeBand }
    func terminalViewDoubleTapped(_ view: TerminalView) -> Bool {
      doubleTaps += 1
      return takesDoubleTap
    }
    func terminalView(_ view: TerminalView, didChangeFontSize pointSize: CGFloat) {}
    func terminalView(_ view: TerminalView, paste clip: Clip) -> Bool { false }
    func terminalView(_ view: TerminalView, insertFrom source: InsertSource) {}
    func terminalView(_ view: TerminalView, didSizeGrid grid: GridSize) {}
    func terminalView(_ view: TerminalView, voiceNotice text: String) {}
    func terminalViewOpensVoiceSettings(_ view: TerminalView) {}
    func terminalViewDictationDestination(_ view: TerminalView) -> DictationDestination? { nil }
  }

  /// A terminal `width` pt wide whose program tracks the mouse (SGR) when
  /// `mouse`, focused when `focused`, and the bytes it sends.
  private func terminal(width: CGFloat = 320, mouse: Bool = true, focused: Bool = true) async throws -> (TerminalView, Stub, () -> String) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: width, height: 480)
    let session = try XCTUnwrap(Session(localCols: 30, rows: 20))
    var sent = Data()
    session.onOutput = { sent.append($0) }
    let view = TerminalView(session: session)
    let stub = Stub()
    view.delegate = stub
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    self.window = window
    delegateStub = stub
    if focused {
      XCTAssertTrue(view.becomeFirstResponder())
    } else {
      view.resignFirstResponder()
      XCTAssertFalse(view.isFirstResponder)
    }
    if mouse {
      session.feed("\u{1B}[?1000h\u{1B}[?1006h")
      let deadline = Date.now.addingTimeInterval(3)
      while !view.snapshot.has(TERM_MODE_MOUSE_TRACKING), Date.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
      }
      XCTAssertTrue(view.snapshot.has(TERM_MODE_MOUSE_TRACKING))
    }
    return (view, stub, { String(decoding: sent, as: UTF8.self) })
  }

  /// In the band of a 320 pt terminal (its right 57.6 pt), and outside it.
  private let band = CGPoint(x: 300, y: 60)
  private let elsewhere = CGPoint(x: 60, y: 60)

  /// A tap as UIKit delivers it: the finger's event times (default: now), handled now.
  private func tap(_ view: TerminalView, at point: CGPoint, touch: TimeInterval? = nil, lift: TimeInterval? = nil) {
    let now = ProcessInfo.processInfo.systemUptime
    let tap = FakeTap()
    tap.point = point
    tap.touchTime = touch ?? now
    tap.liftTime = lift ?? touch ?? now
    view.perform(NSSelectorFromString("handleTap:"), with: tap)
  }

  /// SGR mouse presses and releases in the bytes sent (ESC [ < b ; x ; y M, a
  /// release ending in m; nothing else in them is a letter).
  private static func clicks(_ output: String) -> (presses: Int, releases: Int) {
    (output.filter { $0 == "M" }.count, output.filter { $0 == "m" }.count)
  }
  private static func presses(_ output: String) -> Int { clicks(output).presses }

  // MARK: - The band

  // Bug: the double tap reaching tmux or vim as clicks (tmux selects a word and enters copy mode).
  func testBandDoubleTapSendsNoClickAndOpensSessions() async throws {
    let (view, stub, sent) = try await terminal()
    tap(view, at: band)
    tap(view, at: CGPoint(x: band.x + 4, y: band.y - 2))
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertEqual(sent(), "", "neither tap is a click")
  }

  // Bug: a double tap with the keyboard down raising it (the grid shrinks and omp redraws its transcript).
  func testBandDoubleTapLeavesTheKeyboardDown() async throws {
    let (view, stub, _) = try await terminal(mouse: false, focused: false)
    tap(view, at: band)
    tap(view, at: band)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertFalse(view.isFirstResponder)
  }

  // Bug: a single tap at the edge raising the keyboard, or acting before a second tap could come.
  func testBandSingleTapRaisesNothing() async throws {
    let (view, stub, _) = try await terminal(mouse: false, focused: false)
    tap(view, at: band)
    XCTAssertFalse(view.isFirstResponder)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertFalse(view.isFirstResponder, "the window passed and still no keyboard")
    XCTAssertEqual(stub.doubleTaps, 0)
  }

  // Bug: a held tap clicking at once (so a double tap is a click), never, twice, or somewhere else.
  func testBandSingleTapIsOneClickAtItsCellAfterTheWindow() async throws {
    let (view, _, sent) = try await terminal(focused: false)
    let now = ProcessInfo.processInfo.systemUptime
    tap(view, at: band, touch: now - 0.05, lift: now)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(sent(), "", "held while a second tap may come")
    try await Task.sleep(for: .milliseconds(350))
    let cell = view.cell(at: band)
    let at = "\(cell.col + 1);\(cell.row + 1)"
    XCTAssertGreaterThan(cell.col, 20, "a cell at the right edge")
    XCTAssertEqual(sent(), "\u{1B}[<0;\(at)M\u{1B}[<0;\(at)m", "one press and release at the tapped cell")
    XCTAssertFalse(view.isFirstResponder, "the click raises no keyboard")
  }

  // Bug: the first tap's handler running late (a busy main thread) shortening
  // the gap, so a slow second click opened Sessions: lift 0.10 s before the
  // handler ran, second touch 0.30 s after it, 0.40 s apart in all.
  func testASlowSecondTapStaysAClickWhenTheFirstTapIsHandledLate() async throws {
    let (view, stub, sent) = try await terminal()
    let now = ProcessInfo.processInfo.systemUptime
    tap(view, at: band, touch: now - 0.15, lift: now - 0.10)
    tap(view, at: band, touch: now + 0.30, lift: now + 0.35)
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertEqual(stub.doubleTaps, 0)
    XCTAssertEqual(Self.presses(sent()), 2)
  }

  // Bug: two quick taps queued behind a busy main thread and handled after
  // both fingers lifted read as two taps (the second touched before the first was handled).
  func testQuickTapsHandledLateAreADoubleTap() async throws {
    let (view, stub, sent) = try await terminal()
    let now = ProcessInfo.processInfo.systemUptime
    tap(view, at: band, touch: now - 0.50, lift: now - 0.45)
    tap(view, at: CGPoint(x: band.x + 2, y: band.y + 1), touch: now - 0.30, lift: now - 0.25)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertEqual(Self.presses(sent()), 0)
  }

  // Bug: a slow second tap eaten, or paired with the first.
  func testTwoSlowBandTapsAreTwoClicks() async throws {
    let (view, stub, sent) = try await terminal()
    tap(view, at: band)
    try await Task.sleep(for: .milliseconds(550))
    XCTAssertEqual(Self.presses(sent()), 1)
    tap(view, at: band)
    try await Task.sleep(for: .milliseconds(550))
    XCTAssertEqual(stub.doubleTaps, 0)
    XCTAssertEqual(Self.presses(sent()), 2)
  }

  // Bug: with the menu open (the delegate declines) a tap vanishing.
  func testDeclinedDoubleTapIsTwoClicks() async throws {
    let (view, stub, sent) = try await terminal()
    stub.takesDoubleTap = false
    tap(view, at: band)
    tap(view, at: band)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertEqual(Self.presses(sent()), 2)
  }

  // Bug: a tap held in the band clicking after a later tap elsewhere, or not at all.
  func testATapElsewhereReleasesTheHeldTapFirst() async throws {
    let (view, stub, sent) = try await terminal()
    tap(view, at: band)
    tap(view, at: elsewhere)
    try await Task.sleep(for: .milliseconds(60))
    let first = view.cell(at: band), second = view.cell(at: elsewhere)
    XCTAssertEqual(
      sent(),
      "\u{1B}[<0;\(first.col + 1);\(first.row + 1)M\u{1B}[<0;\(first.col + 1);\(first.row + 1)m"
        + "\u{1B}[<0;\(second.col + 1);\(second.row + 1)M\u{1B}[<0;\(second.col + 1);\(second.row + 1)m")
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(Self.presses(sent()), 2)
    XCTAssertEqual(stub.doubleTaps, 0)
  }

  // Bug: the band too narrow for a thumb on a narrow pane, or not the right 18 %:
  // a 320 pt terminal's band is 57.6 pt (from x 262.4), a 300 pt one's 56 pt (from 244).
  func testTheBandIsTheRight18PercentAtLeast56Points() async throws {
    for (width, edge) in [(CGFloat(320), CGFloat(262.4)), (300, 244)] {
      let (view, _, sent) = try await terminal(width: width)
      tap(view, at: CGPoint(x: edge - 0.5, y: 60))
      try await Task.sleep(for: .milliseconds(60))
      XCTAssertEqual(Self.presses(sent()), 1, "\(width) pt: left of the band, the click goes out at once")
      tap(view, at: CGPoint(x: edge + 0.5, y: 300))
      try await Task.sleep(for: .milliseconds(60))
      XCTAssertEqual(Self.presses(sent()), 1, "\(width) pt: in the band, the tap is held")
      try await Task.sleep(for: .milliseconds(550))
      XCTAssertEqual(Self.presses(sent()), 2, "\(width) pt: released after the window")
      window?.isHidden = true
    }
  }

  // MARK: - Elsewhere

  // Bug: a tap away from the edge waiting for a second tap before raising the keyboard.
  func testATapElsewhereRaisesTheKeyboardAtOnce() async throws {
    let (view, _, _) = try await terminal(mouse: false, focused: false)
    tap(view, at: elsewhere)
    XCTAssertTrue(view.isFirstResponder)
  }

  // Bug: two quick taps away from the edge opening Sessions instead of clicking twice.
  func testTwoQuickTapsElsewhereAreTwoClicks() async throws {
    let (view, stub, sent) = try await terminal()
    tap(view, at: elsewhere)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(Self.presses(sent()), 1, "the first click goes out at once")
    tap(view, at: elsewhere)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(Self.presses(sent()), 2, "and so does the second")
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(stub.doubleTaps, 0)
  }

  // MARK: - In the window

  /// A window on a new shell; `regular` gives it the Duo inner display's
  /// regular width, so upright and with no vertical bar it has the edge band.
  private func openSpace(split: Bool, regular: Bool = false) async throws -> SpaceController {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    savedSplit = AppSettings.shared.splitWhenFlat
    AppSettings.shared.splitWhenFlat = split
    let window = UIWindow(windowScene: scene)
    let space = SpaceController(sceneID: "double-tap-" + UUID().uuidString)
    if regular { space.traitOverrides.horizontalSizeClass = .regular }
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window
    self.space = space
    space.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(800))
    space.newTab()
    try await Task.sleep(for: .milliseconds(800))
    return space
  }

  private func panel(of space: SpaceController) throws -> MenuPanel {
    try XCTUnwrap(space.children.compactMap { $0 as? MenuPanel }.first)
  }

  private func bandPoint(of view: TerminalView) -> CGPoint {
    CGPoint(x: view.bounds.maxX - 10, y: view.bounds.height * 0.3)
  }

  // Bug: the double tap not opening Sessions, or reopening it under a menu that is already open.
  func testDoubleTapOpensSessionsOnlyWithTheMenuClosed() async throws {
    let space = try await openSpace(split: false)
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    space.menu.tab = .tmux
    XCTAssertTrue(space.terminalViewDoubleTapped(terminal))
    XCTAssertTrue(try panel(of: space).isOpen)
    XCTAssertEqual(space.menu.tab, .sessions)
    try await Task.sleep(for: .milliseconds(800))
    space.menu.tab = .tmux
    XCTAssertFalse(space.terminalViewDoubleTapped(terminal), "with the menu open the taps stay plain")
    XCTAssertEqual(space.menu.tab, .tmux)
  }

  // Bug: Sessions opening with the keyboard raised (or dropped) and the grid
  // resized, so omp redraws its whole transcript.
  func testBandDoubleTapOpensSessionsAndKeepsTheKeyboard() async throws {
    let space = try await openSpace(split: false, regular: true)
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    for up in [false, true] {
      if up { terminal.becomeFirstResponder() } else { terminal.resignFirstResponder() }
      try await Task.sleep(for: .milliseconds(800))
      let grid = terminal.gridSize
      tap(terminal, at: bandPoint(of: terminal))
      tap(terminal, at: bandPoint(of: terminal))
      XCTAssertTrue(try panel(of: space).isOpen, "keyboard \(up ? "up" : "down")")
      XCTAssertEqual(space.menu.tab, .sessions)
      XCTAssertEqual(terminal.isFirstResponder, up, "the keyboard stays \(up ? "up" : "down")")
      try await Task.sleep(for: .milliseconds(900))
      XCTAssertEqual(terminal.isFirstResponder, up, "the keyboard stays \(up ? "up" : "down") once Sessions is open")
      XCTAssertEqual(terminal.gridSize.cols, grid.cols)
      XCTAssertEqual(terminal.gridSize.rows, grid.rows)
      space.closeMenu()
      try await Task.sleep(for: .milliseconds(900))
      XCTAssertEqual(terminal.isFirstResponder, up, "and after Sessions closes")
    }
  }

  // Bug: a double tap in one of the Duo's Two Panes shrinking the other pane's
  // session, or a pane's band measured on the whole window.
  func testEachPaneHasItsOwnBand() async throws {
    let space = try await openSpace(split: true)
    try XCTSkipIf(space.traitCollection.horizontalSizeClass != .regular, "Two Panes needs the Duo's inner display")
    let shown = space.tabs.filter { $0.view.window != nil }
    XCTAssertEqual(shown.count, 2, "two panes, one session each")
    for tab in shown.reversed() {
      let width = tab.view.bounds.width
      let edge = width - max(width * 0.18, 56)
      let outside = CGPoint(x: edge - 1, y: tab.view.bounds.height * 0.3)
      tap(tab.view, at: outside)
      tap(tab.view, at: outside)
      XCTAssertFalse(try panel(of: space).isOpen, "left of the pane's band two taps are two taps")
      let inside = CGPoint(x: edge + 1, y: outside.y)
      tap(tab.view, at: inside)
      tap(tab.view, at: inside)
      XCTAssertTrue(try panel(of: space).isOpen)
      XCTAssertEqual(space.menu.zooming, tab.id, "the tapped pane's session shrinks into its window")
      try await Task.sleep(for: .milliseconds(900))
      space.closeMenu()
      try await Task.sleep(for: .milliseconds(900))
    }
  }

  // Bug: a session swipe that springs back to the same session between two
  // band taps leaving the first held, so the second opened Sessions or the first clicked.
  func testASwipeDropsTheHeldTap() async throws {
    let space = try await openSpace(split: false, regular: true)
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    let sent = try await trackMouse(terminal)
    XCTAssertTrue(terminal.becomeFirstResponder())
    let point = bandPoint(of: terminal)
    let now = ProcessInfo.processInfo.systemUptime
    tap(terminal, at: point, touch: now, lift: now + 0.05)
    let pan = FakePan()
    pan.point = space.view.convert(point, from: terminal)
    space.perform(NSSelectorFromString("page:"), with: pan)
    pan.phase = .ended
    space.perform(NSSelectorFromString("page:"), with: pan)
    tap(terminal, at: point, touch: now + 0.25, lift: now + 0.3)
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertFalse(try panel(of: space).isOpen, "the swipe ended the pair")
    XCTAssertEqual(space.focusedTab?.view, terminal, "the swipe sprang back to the same session")
    XCTAssertEqual(Self.presses(sent()), 1, "only the tap after the swipe clicks")
  }

  /// The program in `terminal` tracks the mouse (SGR); the bytes it sends from now.
  private func trackMouse(_ terminal: TerminalView) async throws -> () -> String {
    var sent = Data()
    terminal.session.onOutput = { sent.append($0) }
    terminal.session.feed("\u{1B}[?1000h\u{1B}[?1006h")
    let deadline = Date.now.addingTimeInterval(3)
    while !terminal.snapshot.has(TERM_MODE_MOUSE_TRACKING), Date.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(terminal.snapshot.has(TERM_MODE_MOUSE_TRACKING))
    return { String(decoding: sent, as: UTF8.self) }
  }

  /// Sets the window's size class, shape and vertical bar (the toolbar the
  /// window shows in it), as the outer display, either display's orientation or a phone gives them.
  private func place(_ space: SpaceController, regular: Bool, size: CGSize, verticalBar: Bool) async throws {
    space.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
    window?.frame = CGRect(origin: .zero, size: size)
    try await Task.sleep(for: .milliseconds(300))
    space.navigationController?.setToolbarHidden(!verticalBar, animated: false)
    space.view.setNeedsLayout()
    window?.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
  }

  /// Two quick taps at the terminal's right edge with the keyboard down:
  /// whether they opened Sessions and whether the first raised the keyboard.
  private func edgeDoubleTap(_ space: SpaceController) async throws -> (sessions: Bool, keyboard: Bool) {
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    terminal.resignFirstResponder()
    tap(terminal, at: bandPoint(of: terminal))
    let keyboard = terminal.isFirstResponder
    tap(terminal, at: bandPoint(of: terminal))
    let sessions = try panel(of: space).isOpen
    if sessions {
      try await Task.sleep(for: .milliseconds(900))
      space.closeMenu()
      try await Task.sleep(for: .milliseconds(900))
    }
    return (sessions, keyboard)
  }

  // Bug: the band on a phone, on the Duo's outer display or on its inner
  // display turned sideways, where every tap must act at once; or missing on
  // the inner display upright, where the menu's icons are out of reach.
  func testOnlyTheInnerDisplayUprightHasTheBand() async throws {
    let space = try await openSpace(split: false)
    let upright = CGSize(width: 600, height: 800), sideways = CGSize(width: 800, height: 600)
    let cases: [(String, regular: Bool, size: CGSize, bar: Bool, band: Bool)] = [
      ("inner display upright", true, upright, false, true),
      ("phone", false, upright, false, false),
      ("phone sideways", false, sideways, false, false),
      ("outer display (vertical bar)", true, upright, true, false),
      ("outer display, compact", false, upright, true, false),
      ("inner display sideways", true, sideways, true, false),
      ("inner display sideways, no bar yet", true, sideways, false, false),
    ]
    for c in cases {
      try await place(space, regular: c.regular, size: c.size, verticalBar: c.bar)
      let result = try await edgeDoubleTap(space)
      XCTAssertEqual(result.sessions, c.band, "\(c.0): Sessions")
      XCTAssertEqual(result.keyboard, !c.band, "\(c.0): the first tap raises the keyboard at once")
    }
  }

  // Bug: a tap held in the band clicking after the Duo turned or folded, where the band no longer exists.
  func testLeavingTheInnerDisplayUprightDropsTheHeldTap() async throws {
    let space = try await openSpace(split: false)
    try await place(space, regular: true, size: CGSize(width: 600, height: 800), verticalBar: false)
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    let sent = try await trackMouse(terminal)
    tap(terminal, at: bandPoint(of: terminal))
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(Self.presses(sent()), 1, "upright, a lone tap at the edge is held, then clicks")
    tap(terminal, at: bandPoint(of: terminal))
    // The window's width class changes without its size, so the grid and the program's modes stay.
    space.traitOverrides.horizontalSizeClass = .compact
    space.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertTrue(terminal.snapshot.has(TERM_MODE_MOUSE_TRACKING))
    XCTAssertEqual(Self.presses(sent()), 1, "the second tap was dropped")
    XCTAssertFalse(try panel(of: space).isOpen)
  }
}

/// The held tap and its window, on event times.
@MainActor
final class DoubleTapHoldTests: XCTestCase {
  private let here = CGPoint(x: 100, y: 200)

  // Bug: a slow second tap (or one at the window's very edge) misread.
  func testSecondTapCountsUpToTheSystemIntervalAfterTheFirstLifts() {
    // The first tap lifts at 0, so the second's touch time is exactly the gap.
    let t = DoubleTap()
    t.hold(at: here, lift: 0) {}
    XCTAssertTrue(t.pairs(at: here, touch: 0.35), "0.35 s after the lift is still a double tap")
    XCTAssertFalse(t.pairs(at: here, touch: 0.352), "0.352 s after the lift is two taps")
    XCTAssertFalse(t.pairs(at: here, touch: -0.01), "a touch before the lift is not a second tap")
    t.reset()
  }

  // Bug: two taps in different places (a click on one tmux pane, then another) read as a double tap.
  func testSecondTapCountsWithin45Points() {
    let t = DoubleTap()
    t.hold(at: here, lift: 1.05) {}
    XCTAssertTrue(t.pairs(at: CGPoint(x: here.x + 27, y: here.y + 36), touch: 1.2), "45 pt away")
    XCTAssertFalse(t.pairs(at: CGPoint(x: here.x + 27, y: here.y + 36.5), touch: 1.2), "45.4 pt away")
    t.reset()
  }

  // Bug: a tap that was not held (or was dropped) pairing with the next.
  func testNothingHeldPairsWithNothing() {
    let t = DoubleTap()
    XCTAssertFalse(t.pairs(at: here, touch: 1))
    t.hold(at: here, lift: 1) {}
    t.reset()
    XCTAssertFalse(t.pairs(at: here, touch: 1.1))
  }

  // Bug: a dropped tap clicking anyway, or a held one clicking twice.
  func testReleaseRunsOnceAndResetNever() async throws {
    let t = DoubleTap()
    var released = 0
    t.hold(at: here, lift: ProcessInfo.processInfo.systemUptime) { released += 1 }
    t.release()
    t.release()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(released, 1)

    var dropped = 0
    t.hold(at: here, lift: ProcessInfo.processInfo.systemUptime) { dropped += 1 }
    t.reset()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(dropped, 0)
  }

  // Bug: a second band tap away from the first (or late) losing the first one's click.
  func testHoldingAnotherTapReleasesTheFirst() {
    let t = DoubleTap()
    var order: [String] = []
    t.hold(at: here, lift: 1) { order.append("first") }
    t.hold(at: here, lift: 2) { order.append("second") }
    XCTAssertEqual(order, ["first"])
    t.release()
    XCTAssertEqual(order, ["first", "second"])
  }

  // Bug: the window running from when the handler ran, not from the lift.
  func testTheWindowRunsFromTheLift() async throws {
    let t = DoubleTap()
    var released = false
    t.hold(at: here, lift: ProcessInfo.processInfo.systemUptime - 0.25) { released = true }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(released, "0.35 s after the lift, 0.1 s after the handler")
  }

  // Bug: the first tap released while the second finger is still down (touched
  // inside the window, lifting after it), so that double tap never opened Sessions.
  func testASecondFingerDownInsideTheWindowHoldsTheRelease() async throws {
    let t = DoubleTap()
    let lift = ProcessInfo.processInfo.systemUptime
    var finger: TimeInterval? = lift + 0.3
    t.touchDown = { finger }
    var released = false
    t.hold(at: here, lift: lift) { released = true }
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertFalse(released, "the finger is still down")
    XCTAssertTrue(t.pairs(at: here, touch: lift + 0.3), "and its tap still pairs")
    finger = nil
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(released, "it lifted as something other than a tap")
  }

  // Bug: a finger that came down after the window holding the first tap back.
  func testAFingerDownAfterTheWindowDoesNotHoldTheRelease() async throws {
    let t = DoubleTap()
    let lift = ProcessInfo.processInfo.systemUptime
    t.touchDown = { lift + 0.36 }
    var released = false
    t.hold(at: here, lift: lift) { released = true }
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(released)
  }
}
