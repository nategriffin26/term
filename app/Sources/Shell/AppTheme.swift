import SwiftUI
import UIKit

/// Colours of the app's own surfaces (menu panel, Settings, Files, HUD,
/// banners); the terminal's come from `Theme`. Helm.* reads the current one
/// (AppSettings.appTheme, derived from the terminal theme or the fixed
/// palette): SwiftUI views through observation, UIKit views through
/// `AppThemeTrait` on each window scene.
struct AppTheme: Identifiable, Hashable, Sendable {
  /// 0xRRGGBB with an opacity.
  struct Tone: Hashable, Sendable {
    var rgb: UInt32
    var opacity: Double = 1

    var color: Color {
      Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }

    var uiColor: UIColor { UIColor(rgb: rgb).withAlphaComponent(opacity) }
  }

  var name: String
  var bg, raised, fg, fg2, muted, faint: Tone
  var line, line2, hover, sel: Tone
  var accent, onAccent, ok, warn, bad, overlay: Tone

  var id: String { name }

  var isDark: Bool {
    let r = Double((bg.rgb >> 16) & 0xFF), g = Double((bg.rgb >> 8) & 0xFF), b = Double(bg.rgb & 0xFF)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128
  }

  /// The app's colours follow the terminal theme: ground, panel and text
  /// are the theme's own colours mixed toward each other; the accent (what
  /// needs you) is `accent`, else the cursor colour if it has colour, else
  /// ANSI bright yellow; ok, warn and bad are ANSI green, yellow and red.
  static func derived(from theme: Theme, accent override: UInt32? = nil) -> AppTheme {
    let bg = theme.background, fg = theme.foreground
    let raised = mix(bg, fg, 0.035)
    let cursorHasColour = chroma(theme.cursor) >= 0.25
    let accent = override ?? (cursorHasColour ? theme.cursor : theme.palette[11])
    return AppTheme(
      name: theme.name,
      bg: Tone(rgb: bg), raised: Tone(rgb: raised),
      fg: Tone(rgb: fg),
      fg2: Tone(rgb: legible(mix(fg, bg, 0.32), on: raised, ratio: 4.5, toward: fg)),
      muted: Tone(rgb: legible(mix(fg, bg, 0.52), on: raised, ratio: 3, toward: fg)),
      faint: Tone(rgb: mix(fg, bg, 0.74)),
      line: Tone(rgb: fg, opacity: 0.09), line2: Tone(rgb: fg, opacity: 0.18),
      hover: Tone(rgb: fg, opacity: 0.045), sel: Tone(rgb: fg, opacity: 0.07),
      accent: Tone(rgb: accent), onAccent: Tone(rgb: onAccent(for: accent, background: bg)),
      ok: Tone(rgb: theme.palette[2]), warn: Tone(rgb: theme.palette[3]), bad: Tone(rgb: theme.palette[1]),
      overlay: Tone(rgb: mix(bg, 0x000000, 0.6), opacity: 0.62))
  }

  /// The fixed palette, with the accent replaced when one is picked.
  static func fixed(accent override: UInt32? = nil) -> AppTheme {
    guard let override else { return standard }
    var t = standard
    t.accent = Tone(rgb: override)
    t.onAccent = Tone(rgb: onAccent(for: override, background: standard.bg.rgb))
    return t
  }

  /// `a` moved `t` of the way to `b`, per sRGB channel.
  static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    func channel(_ shift: UInt32) -> UInt32 {
      let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
      return UInt32((x + (y - x) * t).rounded())
    }
    return channel(16) << 16 | channel(8) << 8 | channel(0)
  }

  /// WCAG relative luminance.
  static func luminance(_ rgb: UInt32) -> Double {
    func linear(_ shift: UInt32) -> Double {
      let c = Double((rgb >> shift) & 0xFF) / 255
      return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
  }

  /// WCAG contrast ratio, 1...21.
  static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  /// How far the brightest channel is from the dimmest, 0...1.
  static func chroma(_ rgb: UInt32) -> Double {
    let c = [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF]
    return Double(c.max()! - c.min()!) / 255
  }

  /// `colour`, moved toward `limit` in steps until it reads at `ratio` on `ground`.
  private static func legible(_ colour: UInt32, on ground: UInt32, ratio: Double, toward limit: UInt32) -> UInt32 {
    var out = colour
    for step in 1...20 where contrast(out, ground) < ratio {
      out = mix(colour, limit, Double(step) / 20)
    }
    return out
  }

  /// Text on the accent: the ground if it reads at 4.5:1, else black or white, whichever reads better.
  private static func onAccent(for accent: UInt32, background: UInt32) -> UInt32 {
    if contrast(background, accent) >= 4.5 { return background }
    return contrast(0x000000, accent) >= contrast(0xFFFFFF, accent) ? 0x000000 : 0xFFFFFF
  }

  /// Blue-black ink, blue-tinted hairlines, one cobalt accent.
  static let standard = AppTheme(
    name: "Default",
    bg: Tone(rgb: 0x0A0D13), raised: Tone(rgb: 0x121722),
    fg: Tone(rgb: 0xE6EAF3), fg2: Tone(rgb: 0xA2ABBF), muted: Tone(rgb: 0x7C85A1), faint: Tone(rgb: 0x384056),
    line: Tone(rgb: 0x96AFFF, opacity: 0.075), line2: Tone(rgb: 0x96AFFF, opacity: 0.14),
    hover: Tone(rgb: 0x96AFFF, opacity: 0.045), sel: Tone(rgb: 0x96AFFF, opacity: 0.08),
    accent: Tone(rgb: 0x6F8CFF), onAccent: Tone(rgb: 0x060A1A),
    ok: Tone(rgb: 0x4FB894), warn: Tone(rgb: 0xE5B25D), bad: Tone(rgb: 0xFF5B69),
    overlay: Tone(rgb: 0x02040A, opacity: 0.62))
}

/// The current app theme as a UIKit trait, set on every window scene, so
/// dynamic colours (Helm.UI) resolve against it and refresh when it changes.
struct AppThemeTrait: UITraitDefinition {
  static let defaultValue = AppTheme.standard
  static let affectsColorAppearance = true
}

extension UIWindowScene {
  /// Hands the current app theme to this scene's views.
  @MainActor func applyAppTheme() {
    traitOverrides[AppThemeTrait.self] = AppSettings.shared.appTheme
  }
}
