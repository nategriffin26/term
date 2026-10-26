import XCTest
@testable import Term

@MainActor
final class MenuModelTests: XCTestCase {
  // Bug: after picking a host on the Sessions "New" page, reopening the menu showed that page, not the grid.
  func testReopeningShowsTheSessionsGrid() {
    let menu = MenuModel()
    menu.isOpen = true
    menu.sessionsPage = .new
    menu.isOpen = false
    menu.isOpen = true
    XCTAssertEqual(menu.sessionsPage, .grid)
  }

  // Bug: a Settings sub-screen left open stayed open on reopen (Settings rebuilds when this changes).
  func testEachOpeningRebuildsSettings() {
    let menu = MenuModel()
    let first = menu.settingsGeneration
    menu.isOpen = true
    XCTAssertEqual(menu.settingsGeneration, first + 1)
    menu.isOpen = false
    XCTAssertEqual(menu.settingsGeneration, first + 1)
    menu.isOpen = true
    XCTAssertEqual(menu.settingsGeneration, first + 2)
  }

  // Bug (guard against over-reset): the page changing while the panel is open must not bounce back.
  func testPageHoldsWhileOpen() {
    let menu = MenuModel()
    menu.isOpen = true
    menu.sessionsPage = .new
    menu.isOpen = true
    menu.tab = .tmux
    menu.tab = .sessions
    XCTAssertEqual(menu.sessionsPage, .new)
  }
}
