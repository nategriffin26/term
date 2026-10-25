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
  static let keyRepeatDelayRange: ClosedRange<Double> = 0.1...1.0
  static let keyRepeatRateRange: ClosedRange<Double> = 2...60

  var themeName: String { didSet { store(themeName, "themeName") } }
  var fontFamily: String { didSet { store(fontFamily, "fontFamily") } }
  var fontSize: Double { didSet { store(fontSize, "fontSize") } }
  var cursorBlink: Bool { didSet { store(cursorBlink, "cursorBlink") } }
  var boldIsBright: Bool { didSet { store(boldIsBright, "boldIsBright") } }
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
    cursorBlink = (defaults.object(forKey: "cursorBlink") as? Bool) ?? true
    boldIsBright = (defaults.object(forKey: "boldIsBright") as? Bool) ?? false
    smartKeysWithHardwareKeyboard = (defaults.object(forKey: "smartKeysWithHardwareKeyboard") as? Bool) ?? false
    keyClickSound = (defaults.object(forKey: "keyClickSound") as? Bool) ?? true
    splitWhenFlat = (defaults.object(forKey: "splitWhenFlat") as? Bool) ?? false
    keyRepeatDelay = ((defaults.object(forKey: "keyRepeatDelay") as? Double) ?? 0.4)
      .clamped(to: Self.keyRepeatDelayRange)
    keyRepeatRate = ((defaults.object(forKey: "keyRepeatRate") as? Double) ?? 25)
      .clamped(to: Self.keyRepeatRateRange)
  }

  var theme: Theme { Theme.named(themeName) }
  var termTheme: TermTheme { theme.termTheme(boldIsBright: boldIsBright) }

  private func store(_ value: Any, _ key: String) {
    defaults.set(value, forKey: key)
    NotificationCenter.default.post(name: .termSettingsChanged, object: self)
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
