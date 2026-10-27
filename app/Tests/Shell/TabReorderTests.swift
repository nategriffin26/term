import UIKit
import XCTest
@testable import Term

/// A window dropped on the overview moves its tab in the window's real order:
/// the order swiping follows and the one the next launch restores.
@MainActor
final class TabReorderTests: XCTestCase {
  private var window: UIWindow?
  private let sceneID = "tab-reorder-\(UUID().uuidString)"

  override func tearDown() async throws {
    await MainActor.run {
      window?.isHidden = true
      window = nil
      SessionRegistry.shared.setTabs([], forScene: sceneID)
    }
  }

  private func space(tabs count: Int) throws -> SpaceController {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
    self.window = window
    let space = SpaceController(sceneID: sceneID)
    window.rootViewController = space
    window.isHidden = false
    space.view.layoutIfNeeded()
    while space.tabs.count < count { space.newTab() }
    space.view.layoutIfNeeded()
    return space
  }

  // Bug: a drop that only redraws the overview, leaving swipes in the old order.
  func testADropMovesTheTabInTheSwipeOrder() throws {
    let space = try space(tabs: 3)
    let (a, b, c) = (space.tabs[0], space.tabs[1], space.tabs[2])
    space.select(a)

    space.move(c, to: 1)

    XCTAssertTrue(space.tabs.elementsEqual([a, c, b], by: ===))
    XCTAssertTrue(SessionRegistry.shared.tabs(forScene: sceneID).elementsEqual([a, c, b], by: ===), "the next launch restores the old order")
    space.nextSession(nil)
    XCTAssertTrue(space.focusedTab === c, "the next swipe from the first tab should reach the moved one")
  }

  // Bug: a drop past the end, or onto its own place, losing or duplicating a tab.
  func testADropAtEitherEndOrInPlaceKeepsEveryTab() throws {
    let space = try space(tabs: 3)
    let (a, b, c) = (space.tabs[0], space.tabs[1], space.tabs[2])

    space.move(a, to: 2)
    XCTAssertTrue(space.tabs.elementsEqual([b, c, a], by: ===))
    space.move(a, to: 0)
    XCTAssertTrue(space.tabs.elementsEqual([a, b, c], by: ===))
    space.move(b, to: 1)
    XCTAssertTrue(space.tabs.elementsEqual([a, b, c], by: ===))
    space.move(c, to: 99)
    XCTAssertTrue(space.tabs.elementsEqual([a, b, c], by: ===))
  }

  // Bug: reordering the overview changing what the window shows.
  func testADropKeepsTheShownTab() throws {
    let space = try space(tabs: 3)
    let shown = try XCTUnwrap(space.focusedTab)
    space.move(shown, to: 0)
    XCTAssertTrue(space.focusedTab === shown)
    XCTAssertNotNil(shown.view.window)
  }

  // Bug: sessions opening or closing during a drag dropping the lifted one somewhere other than the preview showed.
  func testAMembershipChangeDuringADragCommitsThePreviewedOrder() throws {
    let space = try space(tabs: 4)
    let (a, b, d) = (space.tabs[0], space.tabs[1], space.tabs[3])
    // d lifted and held after a; then b closes and a new session opens.
    let held = Mosaic.Placement(id: d.id, after: a.id)
    space.close(b)
    space.newTab()
    let ids = space.tabs.map(\.id)
    let preview = try XCTUnwrap(held.apply(to: ids, id: { $0 }, run: Set(ids)))
    XCTAssertEqual(preview.firstIndex(of: d.id), try XCTUnwrap(preview.firstIndex(of: a.id)) + 1)

    space.move(d, to: try XCTUnwrap(held.index(in: ids, run: Set(ids))))

    XCTAssertEqual(space.tabs.map(\.id), preview)
  }
}
