import UIKit
import XCTest
@testable import Term

/// A tab off screen kept the grid it last had, so swiping to it after the
/// keyboard rose or fell resized its program: omp rewrote its whole
/// transcript on every such swipe.
@MainActor
final class OffscreenTabGridTests: XCTestCase {
  private var window: UIWindow?
  private let sceneID = "offscreen-grid-\(UUID().uuidString)"

  override func tearDown() async throws {
    await MainActor.run {
      window?.isHidden = true
      window = nil
      SessionRegistry.shared.setTabs([], forScene: sceneID)
    }
  }

  func testATabOffScreenTakesTheShownTabsGridAsItChanges() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
    self.window = window
    let space = SpaceController(sceneID: sceneID)
    window.rootViewController = space
    window.isHidden = false
    space.view.layoutIfNeeded()
    space.newTab()
    space.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))

    let shown = try XCTUnwrap(space.focusedTab)
    let offscreen = try XCTUnwrap(space.tabs.first { $0 !== shown })
    XCTAssertNil(offscreen.view.window, "the first tab should be off screen")
    let rowsBefore = shown.view.session.rows

    // The keyboard rises: the pane, and so the shown grid, gets shorter.
    window.frame.size.height = 500
    space.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(400))

    XCTAssertLessThan(shown.view.session.rows, rowsBefore, "the shown grid did not change; the test proves nothing")
    XCTAssertEqual(offscreen.view.session.cols, shown.view.session.cols)
    XCTAssertEqual(offscreen.view.session.rows, shown.view.session.rows)

    // A connection completes in the tab off screen: its new session, made at
    // another size, takes the same grid before the tab is shown.
    let connected = try XCTUnwrap(Session(localCols: 80, rows: 24))
    offscreen.view.session = connected
    XCTAssertEqual(connected.cols, shown.view.session.cols)
    XCTAssertEqual(connected.rows, shown.view.session.rows)
  }
}
