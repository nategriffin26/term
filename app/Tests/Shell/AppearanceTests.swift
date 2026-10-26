import Observation
import UIKit
import XCTest
@testable import Term

// MARK: - Terminal theme files

@MainActor
final class ThemeParsingTests: XCTestCase {
  private let dracula = """
    palette = 0=#21222c
    palette = 1=#ff5555
    palette = 2=#50fa7b
    palette = 3=#f1fa8c
    palette = 4=#bd93f9
    palette = 5=#ff79c6
    palette = 6=#8be9fd
    palette = 7=#f8f8f2
    palette = 8=#6272a4
    palette = 9=#ff6e6e
    palette = 10=#69ff94
    palette = 11=#ffffa5
    palette = 12=#d6acff
    palette = 13=#ff92df
    palette = 14=#a4ffff
    palette = 15=#ffffff
    background = #282a36
    foreground = #f8f8f2
    cursor-color = #f0f0f0
    """

  private func without(_ prefix: String) -> String {
    dracula.split(separator: "\n").filter { !$0.hasPrefix(prefix) }.joined(separator: "\n")
  }

  func testAGhosttyFileReadsEveryColour() throws {
    let t = try XCTUnwrap(Theme(name: "Dracula", ghostty: dracula))
    XCTAssertEqual(t.background, 0x282A36)
    XCTAssertEqual(t.foreground, 0xF8F8F2)
    XCTAssertEqual(t.cursor, 0xF0F0F0)
    XCTAssertEqual(t.palette.count, 16)
    XCTAssertEqual(t.palette[0], 0x21222C)
    XCTAssertEqual(t.palette[1], 0xFF5555)
    XCTAssertEqual(t.palette[15], 0xFFFFFF)
  }

  func testNoCursorColourMeansTheForeground() throws {
    let t = try XCTUnwrap(Theme(name: "x", ghostty: without("cursor-color")))
    XCTAssertEqual(t.cursor, 0xF8F8F2)
  }

  func testAThemeMissingBackgroundForegroundOrAPaletteColourIsRejected() {
    XCTAssertNil(Theme(name: "x", ghostty: without("background")))
    XCTAssertNil(Theme(name: "x", ghostty: without("foreground")))
    XCTAssertNil(Theme(name: "x", ghostty: without("palette = 15=")))
    XCTAssertNil(Theme(name: "x", ghostty: ""))
  }

  func testCommentsAndOtherKeysAreSkipped() throws {
    let text = "# palette = 1=#000000\n  # background = #123456\nselection-background = #abcdef\ncursor-text = #111111\n" + dracula
    let t = try XCTUnwrap(Theme(name: "x", ghostty: text))
    XCTAssertEqual(t.palette[1], 0xFF5555)
    XCTAssertEqual(t.background, 0x282A36)
  }

  func testHashIsOptionalButABadColourRejectsTheTheme() throws {
    let bare = dracula.replacingOccurrences(of: "#ff5555", with: "ff5555")
    XCTAssertEqual(try XCTUnwrap(Theme(name: "x", ghostty: bare)).palette[1], 0xFF5555)
    XCTAssertNil(Theme(name: "x", ghostty: dracula.replacingOccurrences(of: "#ff5555", with: "#ff55")))
    XCTAssertNil(Theme(name: "x", ghostty: dracula.replacingOccurrences(of: "#ff5555", with: "#gg5555")))
  }

  func testPaletteSlotsPastFifteenAreIgnored() throws {
    let t = try XCTUnwrap(Theme(name: "x", ghostty: dracula + "\npalette = 16=#010203\npalette = 255=#040506"))
    XCTAssertEqual(t.palette.count, 16)
  }

  func testTheCatalogIsDuskThenTermThenTheOtherFortyFourByName() {
    let all = Theme.all
    XCTAssertEqual(all.count, 46)
    XCTAssertEqual(all.prefix(2).map(\.name), ["Dusk", "Term"])
    XCTAssertEqual(Set(all.map(\.name)).count, 46)
    let rest = all.dropFirst(2).map(\.name)
    XCTAssertEqual(rest, rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    XCTAssertTrue(all.allSatisfy { $0.palette.count == 16 })
  }

  func testDuskIsTheMockupsPalette() {
    let t = Theme.named("Dusk")
    XCTAssertEqual(t.name, "Dusk")
    XCTAssertEqual(t.background, 0x15121C)
    XCTAssertEqual(t.foreground, 0xF6F4FA)
    XCTAssertEqual(t.cursor, 0x7EF0DA)
    XCTAssertEqual(t.palette[1], 0xFF6B86)
    XCTAssertEqual(t.palette[8], 0x5A5368)
  }

  func testTodaysTermThemeIsUnchanged() {
    let t = Theme.named("Term")
    XCTAssertEqual(t.background, 0x000000)
    XCTAssertEqual(t.foreground, 0xE6E6E6)
    XCTAssertEqual(t.cursor, 0xB0B0B0)
    XCTAssertEqual(t.palette[1], 0xCC0000)
    XCTAssertEqual(t.palette[15], 0xEEEEEC)
  }

  func testAFolderOfThemesSkipsFilesThatAreNotThemes() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try dracula.write(to: dir.appending(path: "Dracula.ghostty"), atomically: true, encoding: .utf8)
    try "palette = 1=#ff5555".write(to: dir.appending(path: "Broken.ghostty"), atomically: true, encoding: .utf8)
    try "# credits".write(to: dir.appending(path: "LICENSE.md"), atomically: true, encoding: .utf8)
    XCTAssertEqual(Theme.catalog(in: dir).map(\.name), ["Dracula"])
  }
}

// MARK: - Settings

@MainActor
final class AppearanceSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""

  override func setUp() {
    suite = "term-settings-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  func testTodaysKeysLoadUnchangedAndNewOnesTakeDefaults() {
    defaults.set("Dracula", forKey: "themeName")
    defaults.set("Menlo", forKey: "fontFamily")
    defaults.set(15.0, forKey: "fontSize")
    defaults.set(false, forKey: "cursorBlink")
    defaults.set(true, forKey: "boldIsBright")
    defaults.set(true, forKey: "splitWhenFlat")
    let s = AppSettings(defaults: defaults)
    XCTAssertEqual(s.themeName, "Dracula")
    XCTAssertEqual(s.fontFamily, "Menlo")
    XCTAssertEqual(s.fontSize, 15)
    XCTAssertFalse(s.cursorBlink)
    XCTAssertTrue(s.boldIsBright)
    XCTAssertTrue(s.splitWhenFlat)
    XCTAssertEqual(s.lineSpacing, 1)
    XCTAssertEqual(s.cursorShape, .block)
    XCTAssertEqual(s.cursorColor, .theme)
    XCTAssertTrue(s.cursorFollowsPrograms)
    XCTAssertTrue(s.appMatchesTerminal, "the app follows the terminal unless he turned Match off")
    XCTAssertNil(s.appAccent)
    XCTAssertEqual(s.appTheme.bg.rgb, 0x282A36, "Dracula's ground")
  }

  func testMatchTurnedOffStaysOff() {
    defaults.set(false, forKey: "appMatchesTerminal")
    let s = AppSettings(defaults: defaults)
    XCTAssertFalse(s.appMatchesTerminal)
    XCTAssertEqual(s.appTheme, AppTheme.fixed())
  }

  func testAFreshInstallBlinksAtDusk() {
    let s = AppSettings(defaults: defaults)
    XCTAssertTrue(s.cursorBlink)
    XCTAssertEqual(s.themeName, "Dusk")
    XCTAssertEqual(s.appTheme.bg.rgb, 0x15121C, "Match is on, so the chrome is Dusk's")
  }

  func testSomeoneWhoPickedTermKeepsIt() {
    defaults.set("Term", forKey: "themeName")
    XCTAssertEqual(AppSettings(defaults: defaults).theme.name, "Term")
  }

  func testUnknownOrOutOfRangeStoredValuesFallBack() {
    defaults.set("Gone Theme", forKey: "themeName")
    defaults.set(-5, forKey: "appAccent")
    defaults.set("star", forKey: "cursorShape")
    defaults.set("rainbow", forKey: "cursorColor")
    let s = AppSettings(defaults: defaults)
    XCTAssertEqual(s.theme.name, "Dusk")
    XCTAssertNil(s.appAccent)
    XCTAssertEqual(s.cursorShape, .block)
    XCTAssertEqual(s.cursorColor, .theme)

    defaults.set(9.0, forKey: "lineSpacing")
    XCTAssertEqual(AppSettings(defaults: defaults).lineSpacing, 1.6)
    defaults.set(0.2, forKey: "lineSpacing")
    XCTAssertEqual(AppSettings(defaults: defaults).lineSpacing, 1.0)
    defaults.set(1.6, forKey: "lineSpacing")
    XCTAssertEqual(AppSettings(defaults: defaults).lineSpacing, 1.6)
  }

  func testEveryAppearanceSettingSurvivesARelaunch() {
    let s = AppSettings(defaults: defaults)
    s.cursorShape = .underline
    s.cursorBlink = false
    s.cursorColor = .accent
    s.cursorFollowsPrograms = false
    s.lineSpacing = 1.3
    s.themeName = "Kanagawa Dragon"
    s.appMatchesTerminal = true
    s.appAccent = 0xF2A65A
    let again = AppSettings(defaults: defaults)
    XCTAssertEqual(again.cursorShape, .underline)
    XCTAssertFalse(again.cursorBlink)
    XCTAssertEqual(again.cursorColor, .accent)
    XCTAssertFalse(again.cursorFollowsPrograms)
    XCTAssertEqual(again.lineSpacing, 1.3)
    XCTAssertEqual(again.themeName, "Kanagawa Dragon")
    XCTAssertTrue(again.appMatchesTerminal)
    XCTAssertEqual(again.appAccent, 0xF2A65A)
    again.appAccent = nil
    XCTAssertNil(AppSettings(defaults: defaults).appAccent, "clearing the accent is stored")
  }

  func testTheCoreThemeCarriesTheUsersCursor() {
    let s = AppSettings(defaults: defaults)
    s.cursorShape = .bar
    s.cursorBlink = false
    var t = s.termTheme
    XCTAssertEqual(UInt32(t.cursor_style), UInt32(TERM_CURSOR_BAR.rawValue))
    XCTAssertEqual(t.cursor_blink, 0)
    XCTAssertEqual(t.cursor, 0xFF00_0000 | 0x7EF0DA, "Dusk's own cursor colour")

    s.cursorShape = .underline
    s.cursorBlink = true
    t = s.termTheme
    XCTAssertEqual(UInt32(t.cursor_style), UInt32(TERM_CURSOR_UNDERLINE.rawValue))
    XCTAssertEqual(t.cursor_blink, 1)
  }

  func testTheAccentCursorColourIsTheAppAccent() {
    let s = AppSettings(defaults: defaults)
    s.appAccent = 0xF2A65A
    s.cursorColor = .accent
    XCTAssertEqual(s.termTheme.cursor, 0xFF00_0000 | 0xF2A65A)
  }

  func testProgramsMayChangeTheCursorUnlessTurnedOff() {
    let s = AppSettings(defaults: defaults)
    s.cursorShape = .bar
    s.cursorBlink = false
    XCTAssertNil(s.cursorOverride)
    s.cursorFollowsPrograms = false
    XCTAssertEqual(s.cursorOverride, CursorLook(style: UInt32(TERM_CURSOR_BAR.rawValue), blinks: false))
  }
}

// MARK: - Cursor

final class CursorTests: XCTestCase {
  private let block = UInt32(TERM_CURSOR_BLOCK.rawValue)
  private let bar = UInt32(TERM_CURSOR_BAR.rawValue)
  private let hollow = UInt32(TERM_CURSOR_BLOCK_HOLLOW.rawValue)

  func testAProgramsCursorShowsUnlessTheUserOverridesIt() {
    let program = CursorLook.resolve(frameStyle: bar, frameBlinks: false, override: nil, focused: true)
    XCTAssertEqual(program, CursorLook(style: bar, blinks: false))
    let user = CursorLook(style: block, blinks: true)
    XCTAssertEqual(CursorLook.resolve(frameStyle: bar, frameBlinks: false, override: user, focused: true), user)
  }

  func testAnUnfocusedTerminalDrawsAHollowSteadyBlockWhateverIsAsked() {
    let user = CursorLook(style: bar, blinks: true)
    let want = CursorLook(style: hollow, blinks: false)
    XCTAssertEqual(CursorLook.resolve(frameStyle: bar, frameBlinks: true, override: user, focused: false), want)
    XCTAssertEqual(CursorLook.resolve(frameStyle: block, frameBlinks: true, override: nil, focused: false), want)
  }

  // Solid 0.6 s; then a 0.12 s fade out, hidden until 1.2 s, a 0.12 s fade in, solid until 1.8 s.
  func testTheBlinkIsSolidFadesOutStaysHiddenAndFadesIn() {
    XCTAssertEqual(CursorBlink.alpha(at: 0), 1)
    XCTAssertEqual(CursorBlink.alpha(at: 0.59), 1)
    XCTAssertEqual(CursorBlink.alpha(at: 0.6), 1)
    XCTAssertEqual(CursorBlink.alpha(at: 0.66), 0.5, accuracy: 0.001)
    XCTAssertEqual(CursorBlink.alpha(at: 0.72), 0, accuracy: 0.001)
    XCTAssertEqual(CursorBlink.alpha(at: 1.19), 0)
    XCTAssertEqual(CursorBlink.alpha(at: 1.26), 0.5, accuracy: 0.001)
    XCTAssertEqual(CursorBlink.alpha(at: 1.32), 1, accuracy: 0.001)
    XCTAssertEqual(CursorBlink.alpha(at: 1.79), 1)
    XCTAssertEqual(CursorBlink.alpha(at: 1.86), 0.5, accuracy: 0.001)
  }

  func testTheDisplayLinkRunsOnlyDuringAFade() {
    XCTAssertFalse(CursorBlink.isFading(at: 0.3))
    XCTAssertFalse(CursorBlink.isFading(at: 0.59))
    XCTAssertTrue(CursorBlink.isFading(at: 0.6))
    XCTAssertTrue(CursorBlink.isFading(at: 0.71))
    XCTAssertFalse(CursorBlink.isFading(at: 0.72))
    XCTAssertFalse(CursorBlink.isFading(at: 1.1))
    XCTAssertTrue(CursorBlink.isFading(at: 1.25))
  }
}

// MARK: - App theme

final class DerivedAppThemeTests: XCTestCase {
  private func theme(fg: UInt32 = 0xF8F8F2, bg: UInt32 = 0x282A36, cursor: UInt32 = 0xF8F8F2) -> Theme {
    let palette: [UInt32] = (0..<16).map { UInt32($0) * 0x101010 }
    var t = Theme(name: "T", foreground: fg, background: bg, cursor: cursor, palette: palette)
    t.palette[1] = 0xFF5555
    t.palette[2] = 0x50FA7B
    t.palette[3] = 0xF1FA8C
    t.palette[11] = 0xFFFFA5
    return t
  }

  func testGroundAndTextAreTheThemesOwn() {
    let a = AppTheme.derived(from: theme())
    XCTAssertEqual(a.bg.rgb, 0x282A36)
    XCTAssertEqual(a.fg.rgb, 0xF8F8F2)
    XCTAssertEqual(a.name, "T")
    XCTAssertTrue(a.isDark)
    XCTAssertEqual(a.line2.opacity, 0.18, accuracy: 0.0001)
    XCTAssertEqual(a.line2.rgb, 0xF8F8F2)
  }

  func testStatusColoursAreAnsiGreenYellowRed() {
    let a = AppTheme.derived(from: theme())
    XCTAssertEqual(a.ok.rgb, 0x50FA7B)
    XCTAssertEqual(a.warn.rgb, 0xF1FA8C)
    XCTAssertEqual(a.bad.rgb, 0xFF5555)
  }

  func testAccentIsTheCursorIfItHasColourElseBrightYellowAndAPickedOneBeatsBoth() {
    XCTAssertEqual(AppTheme.derived(from: theme(cursor: 0x7EF0DA)).accent.rgb, 0x7EF0DA)
    XCTAssertEqual(AppTheme.derived(from: theme(cursor: 0xB0B0B0)).accent.rgb, 0xFFFFA5, "a grey cursor has no colour to lend")
    XCTAssertEqual(AppTheme.derived(from: theme(cursor: 0x7EF0DA), accent: 0xFF6B86).accent.rgb, 0xFF6B86)
  }

  /// Bug: Solarized Light's cursor and bright yellow are both greys, so the
  /// needs-you pill came out grey, indistinguishable from the text.
  func testWithoutAColouredCursorOrBrightYellowTheAccentIsTheNextColouredSlot() {
    let solarized = Theme.named("Solarized Light")
    XCTAssertLessThan(AppTheme.chroma(solarized.cursor), 0.25)
    XCTAssertLessThan(AppTheme.chroma(solarized.palette[11]), 0.25)
    let accent = AppTheme.derived(from: solarized).accent.rgb
    XCTAssertGreaterThanOrEqual(AppTheme.chroma(accent), 0.25, String(format: "#%06X", accent))
    XCTAssertGreaterThan(accent >> 16, accent & 0xFF, "yellow (ANSI 3), the next slot with colour")
  }

  /// Bug: a light theme with a pale cursor gave a needs-you colour that
  /// vanished as text ("finished", the open tab's icon) on the ground.
  func testTheAccentReadsAsTextOnTheGround() {
    let pale = AppTheme.derived(from: theme(fg: 0x24292F, bg: 0xFFFFFF, cursor: 0xF5D547))
    XCTAssertGreaterThanOrEqual(AppTheme.contrast(pale.accent.rgb, 0xFFFFFF), 3)
    let picked = AppTheme.derived(from: theme(), accent: 0x000080)
    XCTAssertGreaterThanOrEqual(AppTheme.contrast(picked.accent.rgb, 0x282A36), 3, "a picked accent too dark for the ground")
    XCTAssertGreaterThan(picked.accent.rgb & 0xFF, picked.accent.rgb >> 16, "still blue")
  }

  func testSecondaryTextIsNudgedUntilItReads() {
    let a = AppTheme.derived(from: theme(fg: 0xA0A0A0, bg: 0x000000))
    XCTAssertGreaterThanOrEqual(AppTheme.contrast(a.fg2.rgb, a.raised.rgb), 4.5)
    XCTAssertGreaterThanOrEqual(AppTheme.contrast(a.muted.rgb, a.raised.rgb), 3)
  }

  func testALightThemeGivesLightChrome() {
    let a = AppTheme.derived(from: theme(fg: 0x000000, bg: 0xFFFFFF))
    XCTAssertFalse(a.isDark)
    XCTAssertEqual(a.raised.rgb, 0xF6F6F6, "3.5% of the way from white to black")
    XCTAssertGreaterThanOrEqual(AppTheme.contrast(a.fg2.rgb, a.raised.rgb), 4.5)
  }

  func testTextOnTheAccentReadsAtFourPointFive() {
    let onLight = AppTheme.derived(from: theme(), accent: 0xF5D547)
    XCTAssertEqual(onLight.onAccent.rgb, 0x282A36, "the ground reads on a light accent")
    let onGrey = AppTheme.derived(from: theme(fg: 0x000000, bg: 0xE0E0E0), accent: 0x3A6AB8)
    XCTAssertEqual(onGrey.accent.rgb, 0x3A6AB8, "reads on the ground at 4:1, kept")
    XCTAssertEqual(onGrey.onAccent.rgb, 0xFFFFFF, "the ground (4:1) does not read on it; white (5.3:1) beats black (3.9:1)")
    let mid = AppTheme.derived(from: theme(), accent: 0x808080)
    XCTAssertEqual(mid.onAccent.rgb, 0x000000, "the ground (3.6:1) does not read on mid grey; black (5.3:1) beats white (3.9:1)")
  }

  func testColourMathAtTheEnds() {
    XCTAssertEqual(AppTheme.mix(0x000000, 0xFFFFFF, 0), 0x000000)
    XCTAssertEqual(AppTheme.mix(0x000000, 0xFFFFFF, 1), 0xFFFFFF)
    XCTAssertEqual(AppTheme.mix(0x102030, 0x304050, 0.5), 0x203040)
    XCTAssertEqual(AppTheme.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.001)
    XCTAssertEqual(AppTheme.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
  }

  func testTheFixedPaletteIsTermsOwnDuskWithAnOptionalAccent() {
    let a = AppTheme.fixed()
    XCTAssertEqual(a.bg.rgb, 0x15121C)
    XCTAssertEqual(a.fg.rgb, 0xF6F4FA)
    XCTAssertEqual(a.accent.rgb, 0x7EF0DA)
    XCTAssertEqual(a.bad.rgb, 0xFF6B86)
    let picked = AppTheme.fixed(accent: 0xFF6B86)
    XCTAssertEqual(picked.accent.rgb, 0xFF6B86)
    XCTAssertEqual(picked.bg, a.bg)
  }
}

@MainActor
final class AppThemeRefreshTests: XCTestCase {
  private var saved: (match: Bool, theme: String, accent: UInt32?)!

  override func setUp() {
    let s = AppSettings.shared
    saved = (s.appMatchesTerminal, s.themeName, s.appAccent)
  }

  override func tearDown() {
    let s = AppSettings.shared
    (s.appMatchesTerminal, s.themeName, s.appAccent) = saved
  }

  private var other: AppTheme {
    var t = AppTheme.fixed()
    t.name = "Test"
    t.bg = AppTheme.Tone(rgb: 0xFFFFFF)
    t.line2 = AppTheme.Tone(rgb: 0xFF0000)
    return t
  }

  func testSwiftUIColoursInvalidateWhenTheTerminalThemeChangesWhileMatching() {
    let s = AppSettings.shared
    s.appMatchesTerminal = true
    s.themeName = "Term"
    nonisolated(unsafe) var fired = false
    withObservationTracking { _ = Chrome.bg } onChange: { fired = true }
    s.themeName = "Dracula"
    XCTAssertTrue(fired)
    XCTAssertEqual(s.appTheme.bg.rgb, 0x282A36)
  }

  func testSwiftUIColoursInvalidateWhenMatchingIsTurnedOn() {
    let s = AppSettings.shared
    s.appMatchesTerminal = false
    s.themeName = "Dracula"
    nonisolated(unsafe) var fired = false
    withObservationTracking { _ = Chrome.bg } onChange: { fired = true }
    s.appMatchesTerminal = true
    XCTAssertTrue(fired)
  }

  func testTheAppKeepsItsLookWhenTheTerminalThemeChangesWithoutMatching() {
    let s = AppSettings.shared
    s.appMatchesTerminal = false
    s.themeName = "Term"
    let before = s.appTheme
    s.themeName = "Dracula"
    XCTAssertEqual(s.appTheme, before)
  }

  func testUIKitColoursResolveAgainstTheTraitsAppTheme() {
    let custom = other
    let traits = UITraitCollection { $0[AppThemeTrait.self] = custom }
    XCTAssertEqual(Chrome.UI.bg.resolvedColor(with: traits).argb, 0xFFFF_FFFF)
    XCTAssertEqual(Chrome.UI.bg.resolvedColor(with: UITraitCollection()).argb, UIColor(rgb: 0x15121C).argb, "the fixed palette's ground")
  }

  private func borderRGB(_ view: UIView) -> UInt32 {
    UIColor(cgColor: view.layer.borderColor ?? UIColor.clear.cgColor).argb & 0xFFFFFF
  }

  func testBorderColoursFollowTheThemeOfTheirWindow() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
    let banner = StatusBanner()
    let hud = SessionHUD(frame: .zero)
    window.addSubview(banner)
    window.addSubview(hud)
    window.layoutIfNeeded()
    XCTAssertEqual(UIColor(cgColor: banner.layer.borderColor!).argb >> 24, 0x2E, "the hairline: text at 18%")

    window.traitOverrides[AppThemeTrait.self] = other
    window.layoutIfNeeded()
    XCTAssertEqual(borderRGB(banner), 0xFF0000)
    XCTAssertEqual(borderRGB(hud), 0xFF0000)
  }
}
