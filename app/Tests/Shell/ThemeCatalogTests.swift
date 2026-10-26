import XCTest
@testable import Term

// MARK: - Importing theme files

@MainActor
final class ThemeImportTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appending(path: "imports-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  /// An .itermcolors file: `colors` maps iTerm keys to (r, g, b) in 0-1, in `space` (nil leaves the key out).
  private func itermcolors(_ colors: [String: (Double, Double, Double)], space: String? = "sRGB") throws -> Data {
    var plist: [String: Any] = [:]
    for (key, c) in colors {
      var entry: [String: Any] = ["Red Component": c.0, "Green Component": c.1, "Blue Component": c.2, "Alpha Component": 1.0]
      if let space { entry["Color Space"] = space }
      plist[key] = entry
    }
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  }

  private var fullIterm: [String: (Double, Double, Double)] {
    var colors = ["Background Color": (0.0, 0.0, 0.0), "Foreground Color": (1.0, 1.0, 1.0), "Cursor Color": (1.0, 0.0, 0.0)]
    for i in 0..<16 { colors["Ansi \(i) Color"] = (Double(i) / 15, 0.5, 0.2) }
    return colors
  }

  func testAnItermcolorsFileReadsEveryColourAndDropsItsExtension() throws {
    let t = try Theme(file: itermcolors(fullIterm), named: "Night Shift.itermcolors")
    XCTAssertEqual(t.name, "Night Shift")
    XCTAssertEqual(t.background, 0x000000)
    XCTAssertEqual(t.foreground, 0xFFFFFF)
    XCTAssertEqual(t.cursor, 0xFF0000)
    XCTAssertEqual(t.palette.count, 16)
    XCTAssertEqual(t.palette[0], 0x008033)
    XCTAssertEqual(t.palette[15], 0xFF8033)
  }

  // Bug: P3 and Calibrated components read as sRGB come out too dull / shifted.
  func testItermColoursInOtherSpacesAreConvertedToSRGB() throws {
    let colors = ["Background Color": (0.8, 0.4, 0.3)]
    XCTAssertEqual(try Theme(file: itermcolors(colors, space: "sRGB"), named: "a").background, 0xCC664D)
    XCTAssertEqual(try Theme(file: itermcolors(colors, space: nil), named: "a").background, 0xCC664D)
    try assertClose(Theme(file: itermcolors(colors, space: "P3"), named: "a").background, 0xDB5E44)
    try assertClose(Theme(file: itermcolors(colors, space: "Calibrated"), named: "a").background, 0xD77B5F)
  }

  private func assertClose(_ rgb: UInt32, _ expected: UInt32, file: StaticString = #filePath, line: UInt = #line) {
    for shift in [16, 8, 0] as [UInt32] {
      let a = Int((rgb >> shift) & 0xFF), b = Int((expected >> shift) & 0xFF)
      XCTAssertLessThanOrEqual(abs(a - b), 1, String(format: "%06X vs %06X", rgb, expected), file: file, line: line)
    }
  }

  func testAGhosttyFileWithoutAnExtensionKeepsItsWholeName() throws {
    let text = Data("background = #102030\nforeground = #e0e0e0\n".utf8)
    XCTAssertEqual(try Theme(file: text, named: "Monokai Pro (Filter Octagon)").name, "Monokai Pro (Filter Octagon)")
    XCTAssertEqual(try Theme(file: text, named: "v1.5 Night").name, "v1.5 Night")
    XCTAssertEqual(try Theme(file: text, named: "Calm.ghostty").name, "Calm")
  }

  // Bug: a partial Ghostty theme (just a ground and text colour) was refused,
  // though Ghostty shows it with its own palette.
  func testColoursAFileLeavesOutAreGhosttysDefaults() throws {
    let t = try Theme(file: Data("background = #102030\npalette = 1=#ff0000\n".utf8), named: "Mine")
    XCTAssertEqual(t.background, 0x102030)
    XCTAssertEqual(t.foreground, 0xFFFFFF)
    XCTAssertEqual(t.cursor, 0xFFFFFF)
    XCTAssertEqual(t.palette[0], 0x1D1F21)
    XCTAssertEqual(t.palette[1], 0xFF0000)
    XCTAssertEqual(t.palette[15], 0xEAEAEA)
  }

  func testAFileWithNoColoursOrABadOneIsNotATheme() {
    for (data, name) in [(Data("font-size = 14\n".utf8), "config"), (Data(), "empty"),
                         (Data([0xFF, 0xFE, 0x00, 0x80]), "binary"), (Data("background = #12345\n".utf8), "bad")] {
      XCTAssertThrowsError(try Theme(file: data, named: name), name) {
        XCTAssertEqual($0 as? ImportedThemes.Failure, .notATheme(file: name))
      }
    }
  }

  // Bug: an imported theme saved in a form Term can't read back vanished on relaunch.
  func testAnImportIsSavedAndReadsBackTheSame() throws {
    let saved = try ImportedThemes.add(itermcolors(fullIterm), fileName: "Night.itermcolors", taken: [], in: folder)
    XCTAssertEqual(ImportedThemes.all(in: folder), [saved])
    XCTAssertEqual(saved.name, "Night")
  }

  // Bug: importing a file named like a shipped theme replaced which one the name means.
  func testAnImportTakesANameNoThemeHas() throws {
    let data = Data("background = #102030\n".utf8)
    let first = try ImportedThemes.add(data, fileName: "Nord", taken: ["Nord", "Nord 2"], in: folder)
    XCTAssertEqual(first.name, "Nord 3")
    XCTAssertEqual(ImportedThemes.uniqueName("a/b:c", taken: []), "a-b-c")
    XCTAssertEqual(ImportedThemes.uniqueName("..hidden", taken: []), "hidden")
    XCTAssertEqual(ImportedThemes.uniqueName("  ", taken: []), "Imported")
    XCTAssertEqual(ImportedThemes.uniqueName("Imported", taken: ["Imported"]), "Imported 2")
  }

  func testDeletingAnImportRemovesOnlyIt() throws {
    let data = Data("background = #102030\n".utf8)
    _ = try ImportedThemes.add(data, fileName: "One", taken: [], in: folder)
    _ = try ImportedThemes.add(data, fileName: "Two", taken: ["One"], in: folder)
    try ImportedThemes.delete("One", in: folder)
    XCTAssertEqual(ImportedThemes.all(in: folder).map(\.name), ["Two"])
  }
}

// MARK: - Search

final class ThemeSearchTests: XCTestCase {
  private func themes(_ names: [String]) -> [Theme] {
    names.map { Theme(name: $0, foreground: 0, background: 0, cursor: 0, palette: Array(repeating: 0, count: 16)) }
  }

  private let catalog = ["Dusk", "Term", "Catppuccin Mocha", "Nord", "Nord Light", "Rosé Pine", "TokyoNight Storm", "Snazzy",
                         "Gruvbox Dark", "Everforest Dark Hard", "iTerm2 Solarized Dark"]

  private func search(_ query: String) -> [String] {
    Theme.search(themes(catalog), query).map(\.name)
  }

  func testAnEmptyOrBlankQueryShowsEverything() {
    XCTAssertEqual(search(""), catalog)
    XCTAssertEqual(search("  -"), catalog)
  }

  func testCaseAccentsSpacesAndPunctuationDoNotMatter() {
    XCTAssertEqual(search("ROSE"), ["Rosé Pine"])
    XCTAssertEqual(search("rosepine"), ["Rosé Pine"])
    XCTAssertEqual(search("tokyo night"), ["TokyoNight Storm"])
    XCTAssertEqual(search("tokyo-night"), ["TokyoNight Storm"])
  }

  func testEveryWordMustMatchInAnyOrder() {
    XCTAssertEqual(search("dark gruv"), ["Gruvbox Dark"])
    XCTAssertEqual(search("dark solarized"), ["iTerm2 Solarized Dark"])
    XCTAssertEqual(search("dark nord"), [])
  }

  // Bug: "nord" listed whatever came first in the catalog, not the Nords.
  func testNamesStartingWithTheQueryComeFirst() {
    XCTAssertEqual(search("dark"), ["Gruvbox Dark", "Everforest Dark Hard", "iTerm2 Solarized Dark"])
    XCTAssertEqual(Theme.search(themes(["Snord", "Nord Light", "Nord"]), "nord").map(\.name), ["Nord Light", "Nord", "Snord"])
  }
}

// MARK: - Text Size

final class TextSizeTests: XCTestCase {
  // Bug: Small pushed the caption under the design system's 11 pt floor.
  func testSmallDefaultAndLargeSizesPerStep() {
    let steps: [Chrome.TextStep] = [.title, .body, .secondary, .caption]
    XCTAssertEqual(steps.map { $0.size(in: .small) }, [16, 14, 12, 11])
    XCTAssertEqual(steps.map { $0.size(in: .standard) }, [17, 15, 13, 11])
    XCTAssertEqual(steps.map { $0.size(in: .large) }, [19, 17, 15, 13])
  }

  // Bug: dock glyphs grew with text and overflowed the fixed dock.
  func testOnlySymbolsBesideTextFollowTheSize() {
    let steps: [Chrome.SymbolStep] = [.inline, .control, .dock, .hero]
    XCTAssertEqual(steps.map { $0.size(in: .small) }, [12, 16, 20, 34])
    XCTAssertEqual(steps.map { $0.size(in: .large) }, [15, 19, 20, 34])
  }
}
