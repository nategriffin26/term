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

  var themeName: String { didSet { store(themeName, "themeName") } }
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
  var appTheme: AppTheme { didSet { store(appTheme.name, "appTheme") } }
  var smartKeysWithHardwareKeyboard: Bool { didSet { store(smartKeysWithHardwareKeyboard, "smartKeysWithHardwareKeyboard") } }
  var keyClickSound: Bool { didSet { store(keyClickSound, "keyClickSound") } }
  /// Inner display of iPhone Duo: two sessions side by side even when flat.
  var splitWhenFlat: Bool { didSet { store(splitWhenFlat, "splitWhenFlat") } }
  /// Seconds a key is held before it repeats.
  var keyRepeatDelay: Double { didSet { store(keyRepeatDelay, "keyRepeatDelay") } }
  /// Repeats per second once a key repeats.
  var keyRepeatRate: Double { didSet { store(keyRepeatRate, "keyRepeatRate") } }

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    themeName = defaults.string(forKey: "themeName") ?? Theme.all[0].name
    fontFamily = defaults.string(forKey: "fontFamily") ?? Self.bundledFontFamily
    fontSize = (defaults.object(forKey: "fontSize") as? Double) ?? 13
    lineSpacing = ((defaults.object(forKey: "lineSpacing") as? Double) ?? 1).clamped(to: Self.lineSpacingRange)
    cursorShape = defaults.string(forKey: "cursorShape").flatMap(CursorShape.init(rawValue:)) ?? .block
    cursorBlink = (defaults.object(forKey: "cursorBlink") as? Bool) ?? true
    cursorColor = defaults.string(forKey: "cursorColor").flatMap(CursorColor.init(rawValue:)) ?? .theme
    cursorFollowsPrograms = (defaults.object(forKey: "cursorFollowsPrograms") as? Bool) ?? true
    boldIsBright = (defaults.object(forKey: "boldIsBright") as? Bool) ?? false
    appTheme = AppTheme.named(defaults.string(forKey: "appTheme") ?? "")
    smartKeysWithHardwareKeyboard = (defaults.object(forKey: "smartKeysWithHardwareKeyboard") as? Bool) ?? false
    keyClickSound = (defaults.object(forKey: "keyClickSound") as? Bool) ?? true
    splitWhenFlat = (defaults.object(forKey: "splitWhenFlat") as? Bool) ?? false
    keyRepeatDelay = ((defaults.object(forKey: "keyRepeatDelay") as? Double) ?? 0.4)
      .clamped(to: Self.keyRepeatDelayRange)
    keyRepeatRate = ((defaults.object(forKey: "keyRepeatRate") as? Double) ?? 25)
      .clamped(to: Self.keyRepeatRateRange)
  }

  var theme: Theme { Theme.named(themeName) }

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

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
