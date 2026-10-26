import UIKit
import XCTest
@testable import Term

@MainActor
final class KeyboardHandoffTests: XCTestCase {
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

  private func open(split: Bool = false) async throws {
    savedSplit = AppSettings.shared.splitWhenFlat
    AppSettings.shared.splitWhenFlat = split
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    if split { window.frame = CGRect(x: 0, y: 0, width: 1000, height: 900) }
    space = SpaceController(sceneID: "keyboard-handoff-" + UUID().uuidString)
    if split { space.traitOverrides.horizontalSizeClass = .regular }
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window
    space.view.layoutIfNeeded()
    try await settle()
    if !split { space.newTab(); try await settle() }
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(800)) }
  private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
  }

  func testHandoffKeepsTypingCompositionSmartKeysPasteAndSelectionOnTheirTab() async throws {
    try await open()
    let first = space.tabs[0], second = space.tabs[1]
    var firstBytes = Data(), secondBytes = Data()
    first.local.onOutput = { firstBytes.append($0) }
    second.local.onOutput = { secondBytes.append($0) }
    space.select(first)
    try await settle()
    first.local.feed("\u{1b}[2J\u{1b}[Hretained")
    first.view.render()
    first.view.selection = (GridPoint(row: 0, col: 0), GridPoint(row: 0, col: 7))
    let selected = first.view.selectedText
    XCTAssertEqual(selected, "retained")
    let probe = KeyboardContinuityProbe(space)
    space.select(second)
    try await settle()
    probe.stop()
    XCTAssertEqual(first.view.selectedText, selected)
    XCTAssertTrue(second.view.isFirstResponder)
    second.view.insertText("x")
    second.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
    try await settle()
    XCTAssertEqual(secondBytes, Data("x".utf8), "marked text was sent before it was committed")
    second.view.unmarkText()
    let ctrl = try XCTUnwrap(descendants(second.view.smartKeys, as: KeyCap.self).first { $0.accessibilityLabel == "ctrl" })
    ctrl.onTap?()
    second.view.insertText("c")
    second.view.smartKey(.key(TERM_KEY_TAB))
    // Hardware special keys use the same encoder, including their modifiers.
    second.view.send(TERM_KEY_UP)
    second.view.paste(itemProviders: [NSItemProvider(object: "pasted" as NSString)])
    try await settle()
    XCTAssertEqual(secondBytes, Data("xにほん\u{03}\t\u{1b}[A\u{1b}[200~pasted\u{1b}[201~".utf8))
    XCTAssertTrue(firstBytes.isEmpty, "input leaked into the tab left behind")
    XCTAssertNil(second.view.markedTextRange)
    XCTAssertEqual(second.view.smartKeys.activeMods, 0)
    let command = try XCTUnwrap(descendants(second.view.smartKeys, as: KeyCap.self).first { $0.accessibilityLabel == "Command" })
    command.onTap?()
    XCTAssertTrue(second.view.smartKeys.command)
    XCTAssertEqual(descendants(second.view.smartKeys, as: UIPasteControl.self).count, 1)
    XCTAssertTrue(descendants(second.view.smartKeys, as: KeyCap.self).contains { $0.accessibilityLabel == "Insert File" })
  }

  func testSettingsTextFieldReturnsKeyboardToSelectedTerminalAfterHandoff() async throws {
    try await open()
    let probe = KeyboardContinuityProbe(space)
    space.select(space.tabs[0])
    try await settle()
    probe.stop()
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    space.menu.settingsStart = .voice
    space.openMenu(.settings)
    try await settle()
    let field = try XCTUnwrap(descendants(space.view, as: UITextField.self).first { $0.isSecureTextEntry })
    XCTAssertTrue(field.becomeFirstResponder())
    try await settle()
    XCTAssertFalse(terminal.isFirstResponder)
    XCTAssertTrue(field.isFirstResponder)
    space.closeMenu()
    try await settle()
    XCTAssertTrue(terminal.isFirstResponder)
    XCTAssertFalse(field.isFirstResponder)
  }

  func testTwoPanesFocusAndCollapsingFocusedPaneKeepKeyboard() async throws {
    try await open(split: true)
    XCTAssertEqual(space.tabs.count, 2)
    let left = space.tabs[0], right = space.tabs[1]
    XCTAssertNotNil(left.view.window)
    XCTAssertNotNil(right.view.window)
    // Collapsing a pane legitimately changes its width, but not the keyboard.
    let probe = KeyboardContinuityProbe(space, tracksGridChanges: false)
    space.select(right)
    try await settle()
    XCTAssertTrue(right.view.isFirstResponder)
    XCTAssertFalse(left.view.isFirstResponder)
    XCTAssertTrue(space.focusedTab === right)
    AppSettings.shared.splitWhenFlat = false
    space.view.setNeedsLayout()
    space.view.layoutIfNeeded()
    try await settle()
    XCTAssertTrue(left.view.isFirstResponder)
    XCTAssertTrue(space.focusedTab === left)
    XCTAssertNil(right.view.window)
    probe.stop()
  }
}
