import CoreText
import SwiftUI
import UIKit

/// App chrome tokens (menu panel, overview, HUD, files, settings): colours
/// from the current AppTheme, Geist for language and Geist Mono for
/// machine facts.
enum Helm {
  // Colours: read inside a SwiftUI body, they redraw it when the app theme changes.
  @MainActor static var bg: Color { theme.bg.color }
  @MainActor static var raised: Color { theme.raised.color }
  @MainActor static var fg: Color { theme.fg.color }
  @MainActor static var fg2: Color { theme.fg2.color }
  @MainActor static var muted: Color { theme.muted.color }
  @MainActor static var faint: Color { theme.faint.color }
  @MainActor static var line: Color { theme.line.color }
  @MainActor static var line2: Color { theme.line2.color }
  @MainActor static var hover: Color { theme.hover.color }
  @MainActor static var sel: Color { theme.sel.color }
  @MainActor static var accent: Color { theme.accent.color }
  @MainActor static var onAccent: Color { theme.onAccent.color }
  @MainActor static var ok: Color { theme.ok.color }
  @MainActor static var warn: Color { theme.warn.color }
  @MainActor static var bad: Color { theme.bad.color }
  @MainActor static var overlay: Color { theme.overlay.color }

  /// Whether system controls (switches, keyboards, bars) should be dark.
  @MainActor static var isDark: Bool { theme.isDark }

  @MainActor private static var theme: AppTheme { AppSettings.shared.appTheme }

  /// UIKit twins of the colours above: dynamic, resolved against the
  /// window scene's AppThemeTrait, so views refresh when it changes. A
  /// CGColor taken from them (layer borders) must be re-taken on that trait's change.
  enum UI {
    static var bg: UIColor { tone(\.bg) }
    static var raised: UIColor { tone(\.raised) }
    static var fg: UIColor { tone(\.fg) }
    static var fg2: UIColor { tone(\.fg2) }
    static var muted: UIColor { tone(\.muted) }
    static var faint: UIColor { tone(\.faint) }
    static var line: UIColor { tone(\.line) }
    static var line2: UIColor { tone(\.line2) }
    static var sel: UIColor { tone(\.sel) }
    static var accent: UIColor { tone(\.accent) }
    static var bad: UIColor { tone(\.bad) }
    static var overlay: UIColor { tone(\.overlay) }

    private static func tone(_ key: KeyPath<AppTheme, AppTheme.Tone> & Sendable) -> UIColor {
      UIColor { traits in traits[AppThemeTrait.self][keyPath: key].uiColor }
    }
  }

  // Type.
  static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    registerFonts()
    return .custom("Geist", fixedSize: size).weight(weight)
  }

  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    registerFonts()
    return .custom("Geist Mono", fixedSize: size).weight(weight).monospacedDigit()
  }

  static func uiSans(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
    uiFont(family: "Geist", size: size, weight: weight)
  }

  static func uiMono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
    uiFont(family: "Geist Mono", size: size, weight: weight)
  }

  private static func uiFont(family: String, size: CGFloat, weight: UIFont.Weight) -> UIFont {
    registerFonts()
    let descriptor = UIFontDescriptor(fontAttributes: [
      .family: family,
      .traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: size)
  }

  // Motion: the Helm spring for pushes, panels and indicators; ease for fades.
  @MainActor static let springTiming = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.32, y: 0.72), controlPoint2: CGPoint(x: 0, y: 1))
  @MainActor static let easeTiming = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.2, y: 0), controlPoint2: CGPoint(x: 0, y: 1))
  static func spring(_ duration: Double = 0.45) -> Animation { .timingCurve(0.32, 0.72, 0, 1, duration: duration) }
  static func ease(_ duration: Double = 0.2) -> Animation { .timingCurve(0.2, 0, 0, 1, duration: duration) }

  /// Bundled Geist and Geist Mono (variable, OFL), registered once per process.
  static func registerFonts() { _ = registered }

  private static let registered: Void = {
    let urls = ["GeistVariable", "GeistMonoVariable"].compactMap { Bundle.main.url(forResource: $0, withExtension: "woff2") }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
  }()
}

extension Color {
  init(hex: UInt32) {
    self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}
