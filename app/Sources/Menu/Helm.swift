import CoreText
import SwiftUI
import UIKit

/// Helm style for app chrome (menu panel, overview, HUD, files):
/// blue-black ink, hairlines, one cobalt accent for "you are here / asks
/// you", Geist for language and Geist Mono for machine facts.
enum Helm {
  // Colours (dark; the app runs dark only).
  static let bg = Color(hex: 0x0A0D13)
  static let raised = Color(hex: 0x121722)
  static let fg = Color(hex: 0xE6EAF3)
  static let fg2 = Color(hex: 0xA2ABBF)
  static let muted = Color(hex: 0x7C85A1)
  static let faint = Color(hex: 0x384056)
  static let line = Color(red: 150 / 255, green: 175 / 255, blue: 1, opacity: 0.075)
  static let line2 = Color(red: 150 / 255, green: 175 / 255, blue: 1, opacity: 0.14)
  static let hover = Color(red: 150 / 255, green: 175 / 255, blue: 1, opacity: 0.045)
  static let sel = Color(red: 150 / 255, green: 175 / 255, blue: 1, opacity: 0.08)
  static let accent = Color(hex: 0x6F8CFF)
  static let onAccent = Color(hex: 0x060A1A)
  static let ok = Color(hex: 0x4FB894)
  static let warn = Color(hex: 0xE5B25D)
  static let bad = Color(hex: 0xFF5B69)
  static let overlay = Color(red: 2 / 255, green: 4 / 255, blue: 10 / 255, opacity: 0.62)

  /// UIKit twins of the colours above.
  enum UI {
    static let bg = UIColor(rgb: 0x0A0D13)
    static let raised = UIColor(rgb: 0x121722)
    static let fg = UIColor(rgb: 0xE6EAF3)
    static let fg2 = UIColor(rgb: 0xA2ABBF)
    static let muted = UIColor(rgb: 0x7C85A1)
    static let faint = UIColor(rgb: 0x384056)
    static let line = UIColor(red: 150 / 255, green: 175 / 255, blue: 1, alpha: 0.075)
    static let line2 = UIColor(red: 150 / 255, green: 175 / 255, blue: 1, alpha: 0.14)
    static let sel = UIColor(red: 150 / 255, green: 175 / 255, blue: 1, alpha: 0.08)
    static let accent = UIColor(rgb: 0x6F8CFF)
    static let overlay = UIColor(red: 2 / 255, green: 4 / 255, blue: 10 / 255, alpha: 0.62)
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
