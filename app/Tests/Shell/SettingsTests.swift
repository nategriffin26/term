import XCTest
@testable import Term

@MainActor
final class ThemeStripTests: XCTestCase {
  private let catalog = ["Dusk", "Term", "Dracula", "Nord", "Tomorrow Night", "Solarized Light"]

  // Bug: a strip name the catalog lacks resolves to the fallback theme, so
  // Dusk showed twice and the strip's ForEach had two rows with one id.
  func testNamesTheCatalogLacksAreLeftOff() {
    let names = TerminalAppearancePage.stripNames(current: "Dusk", catalog: catalog)
    XCTAssertEqual(names, ["Dusk", "Tomorrow Night", "Solarized Light", "Term", "Dracula", "Nord"])
  }

  // Bug: a theme picked under All was missing from the strip, so the strip showed no pick.
  func testAPickOffTheStripLeadsIt() {
    let names = TerminalAppearancePage.stripNames(current: "Kanagawa Wave", catalog: catalog + ["Kanagawa Wave"])
    XCTAssertEqual(names, ["Kanagawa Wave", "Dusk", "Tomorrow Night", "Solarized Light", "Term", "Dracula", "Nord"])
  }

  func testAPickOnTheStripKeepsItsPlace() {
    XCTAssertEqual(TerminalAppearancePage.stripNames(current: "Nord", catalog: catalog),
                   ["Dusk", "Tomorrow Night", "Solarized Light", "Term", "Dracula", "Nord"])
  }

  func testAStoredNameNoLongerShippedAddsNothing() {
    XCTAssertEqual(TerminalAppearancePage.stripNames(current: "Gone", catalog: catalog),
                   ["Dusk", "Tomorrow Night", "Solarized Light", "Term", "Dracula", "Nord"])
  }

  // Bug: a typo in the strip silently drops that theme from it.
  func testEveryStripThemeShips() {
    let shipped = Set(Theme.names)
    for name in TerminalAppearancePage.strip { XCTAssertTrue(shipped.contains(name), name) }
  }
}
