import UIKit
import XCTest
@testable import Term

@MainActor
final class SessionsGridTests: XCTestCase {
  private var window: UIWindow?
  private var space: SpaceController?
  private var savedSplit = false

  override func tearDown() async throws {
    if let space { SessionRegistry.shared.discardScenes([space.sceneID]) }
    window?.isHidden = true
    window = nil
    space = nil
    AppSettings.shared.splitWhenFlat = savedSplit
  }

  private func prove(keyboard: Bool, shortViewport: Bool = false) async throws {
    savedSplit = AppSettings.shared.splitWhenFlat
    AppSettings.shared.splitWhenFlat = false
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let space = SpaceController(sceneID: "sessions-grid-" + UUID().uuidString)
    self.window = window
    self.space = space
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(800))
    for _ in 0..<2 { space.newTab(); try await Task.sleep(for: .milliseconds(300)) }
    if !keyboard { space.focusedTab?.view.resignFirstResponder() }
    try await Task.sleep(for: .milliseconds(800))
    if shortViewport {
      let visible = space.view.keyboardLayoutGuide.layoutFrame.minY - space.view.safeAreaInsets.top
      space.additionalSafeAreaInsets.top = max(0, visible - 250)
      space.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(800))
    }
    for fromIcon in [true, false] {
      for exit in 0..<3 {
        let probe = KeyboardContinuityProbe(space, expectsSoftwareKeyboard: keyboard)
        space.openMenu(.sessions, fromIcon: fromIcon)
        try await Task.sleep(for: .milliseconds(600))
        let current = try XCTUnwrap(space.focusedTab)
        // A cramped board shelves windows instead of dismissing the keyboard.
        if !shortViewport {
          XCTAssertNotNil(space.menu.thumbnails.view(showing: current.current), "no live thumbnail exercised the zoom")
        }
        switch exit {
        case 0: space.zoom(into: current)
        case 1: space.zoom(into: try XCTUnwrap(space.tabs.first { $0 !== current }))
        default: space.closeMenu()
        }
        try await Task.sleep(for: .milliseconds(600))
        probe.stop()
        XCTAssertEqual(space.tabs.contains { $0.view.isFirstResponder }, keyboard)
      }
    }
  }

  func testSessionsNeverResizeGridsWithKeyboardUp() async throws { try await prove(keyboard: true) }
  func testSessionsNeverResizeGridsWithKeyboardDown() async throws { try await prove(keyboard: false) }
  func testSessionsKeepKeyboardInAShortViewport() async throws { try await prove(keyboard: true, shortViewport: true) }
}
