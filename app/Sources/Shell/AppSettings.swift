import Foundation
import Observation

extension Notification.Name {
  /// Posted on the main thread after any AppSettings value changes.
  static let termSettingsChanged = Notification.Name("TermSettingsChanged")
}

enum AppIdentity {
  /// Set per developer in app/Config (signing); keychain items and activity types hang off it.
  static let bundleID = Bundle.main.bundleIdentifier ?? "term"
}

/// User preferences (UserDefaults). Hosts and keys live in ConfigStore and Keychain.
@MainActor @Observable
final class AppSettings {
  static let shared = AppSettings(defaults: .standard)

  static let bundledFontFamily = "JetBrainsMono Nerd Font Mono"
  static let fontSizeRange: ClosedRange<Double> = 6...36
  static let lineSpacingRange: ClosedRange<Double> = 1...1.6
  static let keyRepeatDelayRange: ClosedRange<Double> = 0.1...1.0
  static let keyRepeatRateRange: ClosedRange<Double> = 2...60

  var themeName: String { didSet { store(themeName, "themeName"); refreshAppTheme() } }
  var fontFamily: String { didSet { store(fontFamily, "fontFamily") } }
  var fontSize: Double { didSet { store(fontSize, "fontSize") } }
  /// Cell height as a multiple of the font's line height.
  var lineSpacing: Double { didSet { store(lineSpacing, "lineSpacing") } }
  /// The cursor until a program sets its own (DECSCUSR).
  var cursorShape: CursorShape { didSet { store(cursorShape.rawValue, "cursorShape") } }
  var cursorBlink: Bool { didSet { store(cursorBlink, "cursorBlink") } }
  var cursorColor: CursorColor { didSet { store(cursorColor.rawValue, "cursorColor") } }
  /// Off: the user's cursor whatever programs ask for.
  var cursorFollowsPrograms: Bool { didSet { store(cursorFollowsPrograms, "cursorFollowsPrograms") } }
  var boldIsBright: Bool { didSet { store(boldIsBright, "boldIsBright") } }
  /// The app's colours follow the terminal theme; off, the fixed palette.
  var appMatchesTerminal: Bool { didSet { store(appMatchesTerminal, "appMatchesTerminal"); refreshAppTheme() } }
  /// 0xRRGGBB for the colour that marks what needs you; nil takes it from the theme.
  var appAccent: UInt32? {
    didSet {
      if let appAccent { store(Int(appAccent), "appAccent") } else { remove("appAccent") }
      refreshAppTheme()
    }
  }
  /// The app's colours, kept in step with the three settings above (every chrome colour reads it).
  private(set) var appTheme = AppTheme.fixed()
  var smartKeysWithHardwareKeyboard: Bool { didSet { store(smartKeysWithHardwareKeyboard, "smartKeysWithHardwareKeyboard") } }
  var keyClickSound: Bool { didSet { store(keyClickSound, "keyClickSound") } }
  /// Inner display of iPhone Duo: two sessions side by side even when flat.
  var splitWhenFlat: Bool { didSet { store(splitWhenFlat, "splitWhenFlat") } }
  /// Seconds a key is held before it repeats.
  var keyRepeatDelay: Double { didSet { store(keyRepeatDelay, "keyRepeatDelay") } }
  /// Repeats per second once a key repeats.
  var keyRepeatRate: Double { didSet { store(keyRepeatRate, "keyRepeatRate") } }
  /// How much of the theme tints the menu panel and docks.
  var glassStyle: GlassStyle { didSet { store(glassStyle.rawValue, "glassStyle") } }
  /// The chrome's type size; the terminal has its own.
  var textSize: TextSize { didSet { store(textSize.rawValue, "textSize") } }
  /// Light taps on Smart Keys, switches and swipe actions.
  var haptics: Bool { didSet { store(haptics, "haptics") } }
  /// The OpenRouter model dictation transcribes with (Settings › Voice).
  var voiceModel: String { didSet { store(voiceModel, "voiceModel") } }
  /// Whether the Keychain holds an OpenRouter key; set it through `setOpenRouterKey`.
  private(set) var hasOpenRouterKey: Bool

  /// The most accurate on commands, paths and flags (measured: a 30 s recording in about 2 s).
  static let recommendedVoiceModel = "openai/gpt-4o-transcribe"

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    themeName = defaults.string(forKey: "themeName") ?? Theme.own[0]
    fontFamily = defaults.string(forKey: "fontFamily") ?? Self.bundledFontFamily
    fontSize = (defaults.object(forKey: "fontSize") as? Double) ?? 13
    lineSpacing = ((defaults.object(forKey: "lineSpacing") as? Double) ?? 1).clamped(to: Self.lineSpacingRange)
    cursorShape = defaults.string(forKey: "cursorShape").flatMap(CursorShape.init(rawValue:)) ?? .block
    cursorBlink = (defaults.object(forKey: "cursorBlink") as? Bool) ?? true
    cursorColor = defaults.string(forKey: "cursorColor").flatMap(CursorColor.init(rawValue:)) ?? .theme
    cursorFollowsPrograms = (defaults.object(forKey: "cursorFollowsPrograms") as? Bool) ?? true
    boldIsBright = (defaults.object(forKey: "boldIsBright") as? Bool) ?? false
    appMatchesTerminal = (defaults.object(forKey: "appMatchesTerminal") as? Bool) ?? true
    appAccent = (defaults.object(forKey: "appAccent") as? Int).flatMap { UInt32(exactly: $0) }.map { $0 & 0xFFFFFF }
    smartKeysWithHardwareKeyboard = (defaults.object(forKey: "smartKeysWithHardwareKeyboard") as? Bool) ?? false
    keyClickSound = (defaults.object(forKey: "keyClickSound") as? Bool) ?? true
    splitWhenFlat = (defaults.object(forKey: "splitWhenFlat") as? Bool) ?? false
    keyRepeatDelay = ((defaults.object(forKey: "keyRepeatDelay") as? Double) ?? 0.4)
      .clamped(to: Self.keyRepeatDelayRange)
    keyRepeatRate = ((defaults.object(forKey: "keyRepeatRate") as? Double) ?? 25)
      .clamped(to: Self.keyRepeatRateRange)
    glassStyle = defaults.string(forKey: "glassStyle").flatMap(GlassStyle.init(rawValue:)) ?? .tinted
    textSize = defaults.string(forKey: "textSize").flatMap(TextSize.init(rawValue:)) ?? .standard
    haptics = (defaults.object(forKey: "haptics") as? Bool) ?? true
    voiceModel = defaults.string(forKey: "voiceModel").flatMap { $0.isEmpty ? nil : $0 } ?? Self.recommendedVoiceModel
    hasOpenRouterKey = Keychain.openRouterKey()?.isEmpty == false
    refreshAppTheme()
  }

  /// Keeps the key in the Keychain (empty removes it).
  func setOpenRouterKey(_ key: String) {
    Keychain.setOpenRouterKey(key)
    hasOpenRouterKey = !key.isEmpty
  }

  var theme: Theme { Theme.named(themeName) }

  private func refreshAppTheme() {
    appTheme = appMatchesTerminal ? AppTheme.derived(from: theme, accent: appAccent) : AppTheme.fixed(accent: appAccent)
  }

  /// What sessions draw with: the theme's colours, the cursor colour
  /// picked, and the user's cursor as the terminal's default.
  var termTheme: TermTheme {
    var t = theme.termTheme(boldIsBright: boldIsBright)
    if cursorColor == .accent { t.cursor = 0xFF00_0000 | appTheme.accent.rgb }
    t.cursor_style = cursorShape.termStyle
    t.cursor_blink = cursorBlink ? 1 : 0
    return t
  }

  /// The cursor drawn whatever programs ask for, or nil to let them set it.
  var cursorOverride: CursorLook? {
    cursorFollowsPrograms ? nil : CursorLook(style: UInt32(cursorShape.termStyle), blinks: cursorBlink)
  }

  private func store(_ value: Any, _ key: String) {
    defaults.set(value, forKey: key)
    NotificationCenter.default.post(name: .termSettingsChanged, object: self)
  }

  private func remove(_ key: String) {
    defaults.removeObject(forKey: key)
    NotificationCenter.default.post(name: .termSettingsChanged, object: self)
  }
}

enum CursorShape: String, CaseIterable, Sendable {
  case block, bar, underline

  var termStyle: UInt8 {
    switch self {
    case .block: UInt8(TERM_CURSOR_BLOCK.rawValue)
    case .bar: UInt8(TERM_CURSOR_BAR.rawValue)
    case .underline: UInt8(TERM_CURSOR_UNDERLINE.rawValue)
    }
  }
}

enum CursorColor: String, CaseIterable, Sendable {
  /// The terminal theme's cursor colour.
  case theme
  /// The app's accent.
  case accent
}

enum GlassStyle: String, CaseIterable, Sendable {
  /// The terminal shows through, lightly tinted.
  case clear
  /// The theme's ground mostly hides the terminal (c-glass).
  case tinted
}

/// The chrome's type size (Chrome.TextStep.size(in:)).
enum TextSize: String, CaseIterable, Sendable {
  case small, standard, large
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
