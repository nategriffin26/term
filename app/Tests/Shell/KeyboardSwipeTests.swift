import UIKit
import XCTest
@testable import Term

/// Removing the outgoing first responder before focusing the incoming page
/// dismissed the keyboard, resized every terminal, then raised it again.
@MainActor
final class KeyboardSwipeTests: XCTestCase {
  private var window: UIWindow?
  private var space: SpaceController!
  private var savedSplit = false

  override func tearDown() async throws {
    if let space { SessionRegistry.shared.discardScenes([space.sceneID]) }
    window?.isHidden = true
    window = nil
    space = nil
    AppSettings.shared.splitWhenFlat = savedSplit
  }

  /// `split`: Two Panes, forced on with a regular width and a window wide enough for two.
  private func open(tabs count: Int, split: Bool = false) async throws {
    savedSplit = AppSettings.shared.splitWhenFlat
    AppSettings.shared.splitWhenFlat = split
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    if split { window.frame.size.width = max(window.frame.width, 900) }
    space = SpaceController(sceneID: "keyboard-swipe-" + UUID().uuidString)
    if split { space.traitOverrides.horizontalSizeClass = .regular }
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window
    space.view.layoutIfNeeded()
    try await settle()
    for _ in 1..<count { space.newTab(); try await settle() }
    space.select(space.tabs[0])
    try await settle()
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(800)) }

  private func swipe(_ direction: CGFloat, fast: Bool = false, cancel: Bool = false,
                     expectsSoftwareKeyboard: Bool = true) async throws {
    let probe = KeyboardContinuityProbe(space, expectsSoftwareKeyboard: expectsSoftwareKeyboard)
    defer { probe.stop() }
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    let parent = try XCTUnwrap(terminal.superview)
    let gesture = SwipeGesture()
    gesture.point = parent.convert(CGPoint(x: parent.bounds.midX, y: parent.bounds.height * 0.25), to: space.view)
    gesture.phase = .began
    space.perform(NSSelectorFromString("page:"), with: gesture)
    for step in 1...12 {
      gesture.phase = .changed
      gesture.distance = direction * parent.bounds.width * (cancel ? 0.2 : fast ? 0.25 : 0.7) * CGFloat(step) / 12
      space.perform(NSSelectorFromString("page:"), with: gesture)
      try await Task.sleep(for: .milliseconds(fast ? 8 : 40))
    }
    gesture.speed = fast ? direction * 900 : 0
    gesture.phase = cancel ? .cancelled : .ended
    space.perform(NSSelectorFromString("page:"), with: gesture)
    try await SwipeGesture.waitForCompletion(in: parent)
  }

  /// One quick flick, released without waiting for it to settle. `moved`
  /// runs after the gesture's first move.
  private func flick(_ direction: CGFloat, in container: UIView, moved: () -> Void = {}) async throws {
    let gesture = SwipeGesture()
    gesture.point = container.convert(CGPoint(x: container.bounds.midX, y: container.bounds.height * 0.25), to: space.view)
    gesture.phase = .began
    space.perform(NSSelectorFromString("page:"), with: gesture)
    for step in 1...6 {
      gesture.phase = .changed
      gesture.distance = direction * container.bounds.width * 0.2 * CGFloat(step) / 6
      space.perform(NSSelectorFromString("page:"), with: gesture)
      if step == 1 { moved() }
      try await Task.sleep(for: .milliseconds(8))
    }
    gesture.speed = direction * 900
    gesture.phase = .ended
    space.perform(NSSelectorFromString("page:"), with: gesture)
  }

  /// Flicks one after another, each beginning 60 ms after the previous
  /// release, while that release is still settling (0.3 s).
  private func flicks(_ directions: [CGFloat], expectsSoftwareKeyboard: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
    let probe = KeyboardContinuityProbe(space, expectsSoftwareKeyboard: expectsSoftwareKeyboard, file: file, line: line)
    defer { probe.stop(file: file, line: line) }
    let container = try XCTUnwrap(space.focusedTab?.view.superview)
    var expected = try XCTUnwrap(space.tabs.firstIndex { $0 === space.focusedTab })
    for (n, direction) in directions.enumerated() {
      // Where each page is on screen as the finger lands, mid-settle.
      var before: [ObjectIdentifier: CGFloat] = [:]
      for case let page as TerminalView in container.subviews {
        before[ObjectIdentifier(page)] = (page.layer.presentation() ?? page.layer).frame.minX
      }
      try await flick(direction, in: container) {
        guard n > 0 else { return }
        for case let page as TerminalView in container.subviews {
          guard let was = before[ObjectIdentifier(page)] else { continue }
          XCTAssertEqual(page.convert(page.bounds, to: container).minX, was, accuracy: container.bounds.width * 0.1,
                         "flick \(n + 1) moved a page from where the one before had left it", file: file, line: line)
        }
      }
      expected = min(max(expected - Int(direction), 0), space.tabs.count - 1)
      try await Task.sleep(for: .milliseconds(60))
    }
    try await SwipeGesture.waitForCompletion(in: container, file: file, line: line)
    let landed = try XCTUnwrap(space.focusedTab, file: file, line: line)
    XCTAssertTrue(landed === space.tabs[expected],
                  "landed on tab \(space.tabs.firstIndex { $0 === landed } ?? -1), not \(expected)", file: file, line: line)
    XCTAssertTrue(landed.view.superview === container, file: file, line: line)
    XCTAssertEqual(landed.view.transform, .identity, file: file, line: line)
  }

  /// Bug (seen in the user's recording): a swipe that began while the one
  /// before was still settling rebuilt the pages around the session that one
  /// had left, pulled it back under the finger and landed where the first
  /// swipe already had, so quick swipes moved one session for every two.
  func testQuickSwipesMoveOneSessionEachWithTheKeyboardUp() async throws {
    try await open(tabs: 4)
    let grids = space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }
    try await flicks([-1, -1, -1])
    try await flicks([1, 1, 1])
    try await flicks([-1, 1, -1, -1])
    try await flicks([-1, -1, -1])
    XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.isFirstResponder)
    XCTAssertEqual(space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }, grids)
  }

  func testQuickSwipesMoveOneSessionEachWithTheKeyboardDown() async throws {
    try await open(tabs: 4)
    space.focusedTab?.view.resignFirstResponder()
    try await settle()
    let grids = space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }
    try await flicks([-1, -1, -1], expectsSoftwareKeyboard: false)
    try await flicks([1, 1, 1], expectsSoftwareKeyboard: false)
    try await flicks([-1, 1, -1, -1], expectsSoftwareKeyboard: false)
    try await flicks([-1, -1, -1], expectsSoftwareKeyboard: false)
    XCTAssertFalse(space.tabs.contains { $0.view.isFirstResponder })
    XCTAssertEqual(space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }, grids)
  }

  /// Bug: ⌘⇧] or ⌘W pressed while a swipe settled acted on the session the
  /// swipe had left: ⌘⇧] landed where the swipe already had, and ⌘W closed
  /// the session swiped away from instead of the one on screen.
  func testShortcutsDuringASettleActOnTheSessionItBringsIn() async throws {
    try await open(tabs: 3)
    let container = try XCTUnwrap(space.focusedTab?.view.superview)
    try await flick(-1, in: container)
    try await Task.sleep(for: .milliseconds(60))
    space.nextSession(nil)
    try await SwipeGesture.waitForCompletion(in: container)
    XCTAssertTrue(space.focusedTab === space.tabs[2], "⌘⇧] after a swipe must move one session further")
    let left = space.tabs[2]
    let shown = space.tabs[1]
    try await flick(1, in: container)
    try await Task.sleep(for: .milliseconds(60))
    space.closeSession(nil)
    try await SwipeGesture.waitForCompletion(in: container)
    XCTAssertFalse(space.tabs.contains { $0 === shown }, "⌘W must close the session the swipe brought in")
    XCTAssertTrue(space.tabs.contains { $0 === left }, "⌘W closed the session swiped away from")
    XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.isFirstResponder)
  }

  /// Pulls the page a fifth of the way and cancels, so it springs back.
  private func cancelledPull(in container: UIView) {
    let gesture = SwipeGesture()
    gesture.point = container.convert(CGPoint(x: container.bounds.midX, y: container.bounds.height * 0.25), to: space.view)
    gesture.phase = .began
    space.perform(NSSelectorFromString("page:"), with: gesture)
    gesture.phase = .changed
    gesture.distance = -container.bounds.width * 0.2
    space.perform(NSSelectorFromString("page:"), with: gesture)
    gesture.phase = .cancelled
    space.perform(NSSelectorFromString("page:"), with: gesture)
  }

  /// At rest: in place, no transform on the model or on screen (so it lays out its grid again).
  private func assertAtRest(_ tab: Tab, in container: UIView, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(tab.view.superview === container, "the page left its pane", file: file, line: line)
    XCTAssertTrue(tab.view.transform.isIdentity, "the page stayed displaced: \(tab.view.transform)", file: file, line: line)
    XCTAssertTrue((tab.view.layer.presentation()?.affineTransform() ?? .identity).isIdentity,
                  "the page is still sliding on screen", file: file, line: line)
    XCTAssertEqual(tab.view.frame, container.bounds, file: file, line: line)
  }

  /// Bug: opening the menu during a cancelled swipe's spring-back stopped the
  /// page where it was, displaced, and left it sliding (no grid layout).
  func testMenuOpenedDuringASpringBackLeavesThePageAtRest() async throws {
    try await open(tabs: 2)
    let tab = try XCTUnwrap(space.focusedTab)
    let container = try XCTUnwrap(tab.view.superview)
    cancelledPull(in: container)
    try await Task.sleep(for: .milliseconds(60))
    space.toggleMenu(nil)
    try await Task.sleep(for: .milliseconds(100))
    assertAtRest(tab, in: container)
    space.closeMenu()
    try await settle()
  }

  /// Bug: with Two Panes, a swipe in one pane during the other's spring-back
  /// left the other pane's page displaced and sliding.
  func testSwipeInTheOtherPaneDuringASpringBackLeavesThePageAtRest() async throws {
    try await open(tabs: 4, split: true)
    XCTAssertTrue(space.showsTwoPanes, "the test needs Two Panes")
    let shown = space.tabs.filter { space.paneIndex(showing: $0) != nil }
      .sorted { (space.paneIndex(showing: $0) ?? 0) < (space.paneIndex(showing: $1) ?? 0) }
    XCTAssertEqual(shown.count, 2)
    let left = try XCTUnwrap(shown.first)
    let right = try XCTUnwrap(shown.last)
    let leftContainer = try XCTUnwrap(left.view.superview)
    let rightContainer = try XCTUnwrap(right.view.superview)
    cancelledPull(in: leftContainer)
    try await Task.sleep(for: .milliseconds(60))
    // Toward a session neither pane shows.
    let last = space.tabs.last === right
    try await flick(last ? 1 : -1, in: rightContainer)
    try await SwipeGesture.waitForCompletion(in: rightContainer)
    assertAtRest(left, in: leftContainer)
    XCTAssertFalse(space.paneIndex(showing: right) == 1, "the swipe in the other pane must still switch it")
  }

  func testSwipesKeepKeyboardAndEveryTabGridForTwoAndThreeTabs() async throws {
    try await open(tabs: 2)
    for count in 2...3 {
      if count == 3 { space.newTab(); space.select(space.tabs[0]); try await settle() }
      let grids = space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }
      for fast in [false, true] {
        for direction: CGFloat in [-1, 1] {
          let source = space.focusedTab
          try await swipe(direction, fast: fast, cancel: true)
          XCTAssertTrue(space.focusedTab === source)
          XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.isFirstResponder)
          try await swipe(direction, fast: fast)
          XCTAssertFalse(space.focusedTab === source, "the swipe must actually switch tabs")
          XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.isFirstResponder)
          XCTAssertEqual(space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }, grids)
        }
      }
    }
  }

  func testSelectingCreatingClosingAndKeyboardShortcutsKeepKeyboard() async throws {
    try await open(tabs: 2)
    let actions: [() -> Void] = [
      { self.space.select(self.space.tabs[1]) },
      { self.space.previousSession(nil) },
      { self.space.nextSession(nil) },
      { self.space.newTab() },
      { self.space.close(self.space.focusedTab!) },
    ]
    for action in actions {
      let probe = KeyboardContinuityProbe(space)
      action()
      try await settle()
      XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.isFirstResponder)
      probe.stop()
    }
    let window = try XCTUnwrap(window)
    let local = space.view.convert(space.view.keyboardLayoutGuide.layoutFrame, to: window)
    let frame = window.convert(local, to: window.screen.coordinateSpace)
    let probe = KeyboardContinuityProbe(space)
    for _ in 0..<2 {
      NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                      userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
    }
    try await settle()
    probe.stop()
    XCTAssertEqual(probe.shows, 0, "an unchanged keyboard frame reloaded its input views")
  }

  func testKeyboardDownSwipesDoNotTakeFocus() async throws {
    try await open(tabs: 3)
    space.focusedTab?.view.resignFirstResponder()
    try await settle()
    let grids = space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }
    for direction: CGFloat in [-1, -1, 1, 1] {
      try await swipe(direction, expectsSoftwareKeyboard: false)
      XCTAssertFalse(space.tabs.contains { $0.view.isFirstResponder })
      XCTAssertEqual(space.tabs.map { "\($0.current.cols)x\($0.current.rows)" }, grids)
    }
  }

  /// The Smart Keys bar lives in the retained accessory host, in the keyboard's
  /// window, whose first responder is nil: a nil-targeted action sent from the
  /// bar found no responder, so double ⌘ stopped opening the menu after a
  /// session switch.
  func testDoubleCommandOpensTheMenuAfterASessionSwitch() async throws {
    try await open(tabs: 2)
    space.select(space.tabs[1])
    try await settle()
    let accessory = try XCTUnwrap(space.focusedTab?.view.inputAccessoryView)
    let command = try XCTUnwrap(Self.commandKey(in: accessory))
    command.onTap?()
    command.onTap?()
    try await settle()
    let panel = try XCTUnwrap(space.children.compactMap { $0 as? MenuPanel }.first)
    XCTAssertTrue(panel.isOpen, "double ⌘ after a session switch must open the menu")
  }

  private static func commandKey(in view: UIView) -> KeyCap? {
    if let cap = view as? KeyCap, cap.accessibilityLabel == "Command" { return cap }
    for child in view.subviews { if let cap = commandKey(in: child) { return cap } }
    return nil
  }

  func testRotationKeepsKeyboardStableWhenReturningToPreviouslyHiddenTabs() async throws {
    try await open(tabs: 3)
    let scene = try XCTUnwrap(window?.windowScene)
    try XCTSkipIf(scene.traitCollection.horizontalSizeClass != .compact,
                  "The simulator cannot rotate the regular-width inner display; its swipe matrix runs separately.")
    let original = scene.effectiveGeometry.interfaceOrientation
    let rotated: UIInterfaceOrientation = original == .landscapeLeft ? .landscapeRight : .landscapeLeft
    let originalMask = UIInterfaceOrientationMask(rawValue: 1 << original.rawValue)
    let rotatedMask = UIInterfaceOrientationMask(rawValue: 1 << rotated.rawValue)
    defer { scene.requestGeometryUpdate(.iOS(interfaceOrientations: originalMask)) }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotatedMask))
    let deadline = Date.now.addingTimeInterval(5)
    while scene.effectiveGeometry.interfaceOrientation != rotated, Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, rotated)
    try await settle()
    for direction: CGFloat in [-1, -1, 1, 1] {
      let source = space.focusedTab
      try await swipe(direction)
      XCTAssertFalse(space.focusedTab === source)
    }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: originalMask))
    let restoreDeadline = Date.now.addingTimeInterval(5)
    while scene.effectiveGeometry.interfaceOrientation != original, Date.now < restoreDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, original)
    try await settle()
  }
}

@MainActor
final class SwipeGesture: UIPanGestureRecognizer {
  var phase = UIGestureRecognizer.State.possible
  var distance: CGFloat = 0
  var speed: CGFloat = 0
  var point = CGPoint.zero
  override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
  override func location(in view: UIView?) -> CGPoint { point }
  override func translation(in view: UIView?) -> CGPoint { CGPoint(x: distance, y: 0) }
  override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: speed, y: 0) }

  static func waitForCompletion(in container: UIView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    // The completion removes the outgoing/preview terminals. A fixed sleep
    // can finish first when the host is busy, overlapping the next gesture.
    while container.subviews.filter({ $0 is TerminalView }).count > 1, Date.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(container.subviews.filter({ $0 is TerminalView }).count, 1,
                   "the swipe animation did not complete", file: file, line: line)
    try await Task.sleep(for: .milliseconds(100))
  }
}
