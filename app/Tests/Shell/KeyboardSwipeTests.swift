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

  private func open(tabs count: Int) async throws {
    savedSplit = AppSettings.shared.splitWhenFlat
    AppSettings.shared.splitWhenFlat = false
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    space = SpaceController(sceneID: "keyboard-swipe-" + UUID().uuidString)
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
