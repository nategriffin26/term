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
      SessionRegistry.shared.setTiling(nil, forScene: sceneID)
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

  // Bug: a split or swap on the overview that leaves swipes in the old order, or a tiling the next launch forgets.
  func testArrangingTakesTheTilingsReadingOrder() throws {
    let space = try space(tabs: 3)
    let (a, b, c) = (space.tabs[0], space.tabs[1], space.tabs[2])
    space.select(c)
    let tiling = SplitTree<UUID>.split(.across, [.init(share: 0.5, node: .window(c.id)),
                                                 .init(share: 0.5, node: .split(.down, [.init(share: 0.5, node: .window(a.id)),
                                                                                         .init(share: 0.5, node: .window(b.id))]))])

    space.arrange(tiling.windows, tiling: tiling)

    XCTAssertTrue(space.tabs.elementsEqual([c, a, b], by: ===))
    XCTAssertTrue(SessionRegistry.shared.tabs(forScene: sceneID).elementsEqual([c, a, b], by: ===))
    XCTAssertEqual(space.tiling, tiling)
    space.nextSession(nil)
    XCTAssertTrue(space.focusedTab === a, "the next swipe from the first window should reach the one after it in the tiling")
  }

  // Bug: a tab opened during a drag lost when the drop arranges the others.
  func testArrangingKeepsTabsTheOrderLacks() throws {
    let space = try space(tabs: 3)
    let (a, b, c) = (space.tabs[0], space.tabs[1], space.tabs[2])
    space.arrange([b.id, a.id], tiling: nil)
    XCTAssertTrue(space.tabs.elementsEqual([b, a, c], by: ===))
  }

  // Bug: the user's tiling not written for the next launch, or not read back.
  func testATilingSurvivesARelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "tilings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tiling = SplitTree<UUID>.split(.down, [.init(share: 0.3, node: .window(UUID())), .init(share: 0.7, node: .window(UUID()))])
    let before = SessionRegistry(directory: directory)
    before.setTiling(tiling, forScene: "window")
    before.saveTilings()

    let after = SessionRegistry(directory: directory)
    after.restoreTilings()

    XCTAssertEqual(after.tiling(forScene: "window"), tiling)
    XCTAssertNil(after.tiling(forScene: "other"))
  }
}
