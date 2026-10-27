import UIKit
import XCTest
@testable import Term

/// A quick double tap on the terminal opens Sessions; the first tap still acts
/// at once and the second never reaches the program.
@MainActor
final class DoubleTapTests: XCTestCase {
  private let here = CGPoint(x: 100, y: 200)

  // Bug: a slow second tap (or one at the window's very edge) misread.
  func testSecondTapCountsUpToTheSystemIntervalAfterTheFirstLifts() {
    // The first tap lifts at 0, so the second's touch time is exactly the gap.
    var a = DoubleTap()
    XCTAssertFalse(a.tap(at: here, touch: -0.08, lift: 0))
    XCTAssertTrue(a.tap(at: here, touch: 0.35, lift: 0.42), "0.35 s after the lift is still a double tap")

    var b = DoubleTap()
    XCTAssertFalse(b.tap(at: here, touch: -0.08, lift: 0))
    XCTAssertFalse(b.tap(at: here, touch: 0.352, lift: 0.42), "0.352 s after the lift is two taps")
  }

  // Bug: two taps in different places (a click on one tmux pane, then another) read as a double tap.
  func testSecondTapCountsWithin45Points() {
    var a = DoubleTap()
    _ = a.tap(at: here, touch: 1, lift: 1.05)
    XCTAssertTrue(a.tap(at: CGPoint(x: here.x + 27, y: here.y + 36), touch: 1.2, lift: 1.25), "45 pt away")

    var b = DoubleTap()
    _ = b.tap(at: here, touch: 1, lift: 1.05)
    XCTAssertFalse(b.tap(at: CGPoint(x: here.x + 27, y: here.y + 36.5), touch: 1.2, lift: 1.25), "45.4 pt away")
  }

  // Bug: a triple tap opening Sessions twice, or a slow pair's second tap
  // not starting a new pair.
  func testADoubleTapUsesUpBothTapsAndAMissStartsANewPair() {
    var t = DoubleTap()
    _ = t.tap(at: here, touch: 1, lift: 1.05)
    XCTAssertTrue(t.tap(at: here, touch: 1.2, lift: 1.25))
    XCTAssertFalse(t.tap(at: here, touch: 1.4, lift: 1.45), "the third tap starts afresh")
    XCTAssertTrue(t.tap(at: here, touch: 1.6, lift: 1.65), "and pairs with the fourth")

    var slow = DoubleTap()
    _ = slow.tap(at: here, touch: 1, lift: 1.05)
    XCTAssertFalse(slow.tap(at: here, touch: 2, lift: 2.05))
    XCTAssertTrue(slow.tap(at: here, touch: 2.2, lift: 2.25), "the late tap is the first of a new pair")
  }

  // Bug: a tap that cleared a selection or opened a diagram becoming half of a double tap.
  func testResetBreaksThePair() {
    var t = DoubleTap()
    _ = t.tap(at: here, touch: 1, lift: 1.05)
    t.reset()
    XCTAssertFalse(t.tap(at: here, touch: 1.2, lift: 1.25))
  }

  // MARK: - On the terminal

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
    var takesDoubleTap = true
    var doubleTaps = 0
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

  /// A focused terminal whose program tracks the mouse (SGR), and the bytes it sends.
  private func mouseTrackingTerminal() async throws -> (TerminalView, Stub, () -> String) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
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
    XCTAssertTrue(view.becomeFirstResponder())
    session.feed("\u{1B}[?1000h\u{1B}[?1006h")
    let deadline = Date.now.addingTimeInterval(3)
    while !view.snapshot.has(TERM_MODE_MOUSE_TRACKING), Date.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(view.snapshot.has(TERM_MODE_MOUSE_TRACKING))
    return (view, stub, { String(decoding: sent, as: UTF8.self) })
  }

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

  // Bug: the double tap reaching tmux or vim as a double-click (tmux selects a word and enters copy mode).
  func testDoubleTapSendsOneClickAndOpensSessions() async throws {
    let (view, stub, sent) = try await mouseTrackingTerminal()
    tap(view, at: CGPoint(x: 60, y: 60))
    tap(view, at: CGPoint(x: 64, y: 58))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(stub.doubleTaps, 1)
    let clicks = Self.clicks(sent())
    XCTAssertEqual(clicks.presses, 1, "one press for the first tap only: \(sent().debugDescription)")
    XCTAssertEqual(clicks.releases, 1, "the first tap's press is released: \(sent().debugDescription)")
  }

  // Bug: the first tap's handler running late (a busy main thread) shortening
  // the gap, so a slow second click opened Sessions: lift 0.10 s before the
  // handler ran, second touch 0.30 s after it, 0.40 s apart in all.
  func testASlowSecondClickStaysAClickWhenTheFirstTapIsHandledLate() async throws {
    let (view, stub, sent) = try await mouseTrackingTerminal()
    let now = ProcessInfo.processInfo.systemUptime
    tap(view, at: CGPoint(x: 60, y: 60), touch: now - 0.15, lift: now - 0.10)
    tap(view, at: CGPoint(x: 60, y: 60), touch: now + 0.30, lift: now + 0.35)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub.doubleTaps, 0)
    XCTAssertEqual(Self.presses(sent()), 2)
  }

  // Bug: two quick taps queued behind a busy main thread and handled after
  // both fingers lifted read as two taps (the second touched before the first was handled).
  func testQuickTapsHandledLateAreADoubleTap() async throws {
    let (view, stub, sent) = try await mouseTrackingTerminal()
    let now = ProcessInfo.processInfo.systemUptime
    tap(view, at: CGPoint(x: 60, y: 60), touch: now - 0.50, lift: now - 0.45)
    tap(view, at: CGPoint(x: 62, y: 61), touch: now - 0.30, lift: now - 0.25)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertEqual(Self.presses(sent()), 1)
  }

  // Bug: the double tap holding single taps back, or eating a slow second click.
  func testTwoSlowTapsAreTwoClicks() async throws {
    let (view, stub, sent) = try await mouseTrackingTerminal()
    tap(view, at: CGPoint(x: 60, y: 60))
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(Self.presses(sent()), 1, "the first click goes out at once, not after the double-tap window")
    try await Task.sleep(for: .milliseconds(450))
    tap(view, at: CGPoint(x: 60, y: 60))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub.doubleTaps, 0)
    XCTAssertEqual(Self.presses(sent()), 2)
  }

  // Bug: with the menu open (the delegate declines) the second tap vanishing.
  func testDeclinedDoubleTapIsTwoClicks() async throws {
    let (view, stub, sent) = try await mouseTrackingTerminal()
    stub.takesDoubleTap = false
    tap(view, at: CGPoint(x: 60, y: 60))
    tap(view, at: CGPoint(x: 60, y: 60))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertEqual(Self.presses(sent()), 2)
  }

  // MARK: - In the window

  private func openSpace(split: Bool) async throws -> SpaceController {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    savedSplit = AppSettings.shared.splitWhenFlat
    AppSettings.shared.splitWhenFlat = split
    let window = UIWindow(windowScene: scene)
    let space = SpaceController(sceneID: "double-tap-" + UUID().uuidString)
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

  // Bug: a double tap in one of the Duo's Two Panes shrinking the other pane's session, or nothing.
  func testDoubleTapInEitherPaneOpensSessionsFromThatPane() async throws {
    let space = try await openSpace(split: true)
    try XCTSkipIf(space.traitCollection.horizontalSizeClass != .regular, "Two Panes needs the Duo's inner display")
    let shown = space.tabs.filter { $0.view.window != nil }
    XCTAssertEqual(shown.count, 2, "two panes, one session each")
    for tab in shown.reversed() {
      let point = CGPoint(x: tab.view.bounds.midX, y: tab.view.bounds.height * 0.3)
      tap(tab.view, at: point)
      tap(tab.view, at: point)
      XCTAssertTrue(try panel(of: space).isOpen)
      XCTAssertEqual(space.menu.zooming, tab.id, "the tapped pane's session shrinks into its window")
      try await Task.sleep(for: .milliseconds(900))
      space.closeMenu()
      try await Task.sleep(for: .milliseconds(900))
    }
  }

  // Bug: a session swipe that springs back to the same session between two
  // taps leaving the pair open, so the second tap opened Sessions instead of clicking.
  func testACancelledSwipeBetweenTapsLeavesTwoClicks() async throws {
    let space = try await openSpace(split: false)
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    var sent = Data()
    terminal.session.onOutput = { sent.append($0) }
    terminal.session.feed("\u{1B}[?1000h\u{1B}[?1006h")
    let deadline = Date.now.addingTimeInterval(3)
    while !terminal.snapshot.has(TERM_MODE_MOUSE_TRACKING), Date.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(terminal.becomeFirstResponder())
    let point = CGPoint(x: terminal.bounds.midX, y: terminal.bounds.height * 0.3)
    let now = ProcessInfo.processInfo.systemUptime
    tap(terminal, at: point, touch: now, lift: now + 0.05)
    let pan = FakePan()
    pan.point = space.view.convert(point, from: terminal)
    space.perform(NSSelectorFromString("page:"), with: pan)
    pan.phase = .ended
    space.perform(NSSelectorFromString("page:"), with: pan)
    tap(terminal, at: point, touch: now + 0.25, lift: now + 0.3)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(try panel(of: space).isOpen, "the swipe ended the pair")
    XCTAssertEqual(space.focusedTab?.view, terminal, "the swipe sprang back to the same session")
    XCTAssertEqual(Self.presses(String(decoding: sent, as: UTF8.self)), 2)
  }
}
