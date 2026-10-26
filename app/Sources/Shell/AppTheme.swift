import SwiftUI
import UIKit

/// Colours of the app's own surfaces (menu panel, Settings, Files, HUD,
/// banners); the terminal's come from `Theme`. Chrome.* reads the current one
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
  /// The ground, the opaque panel ground, and text by importance.
  var bg, raised, fg, fg2, muted, faint: Tone
  /// Washes and hairlines: the text colour at fixed opacities, so they read on light and dark grounds alike.
  var fill, fill2, fill3, line, line2: Tone
  var accent, onAccent, ok, warn, bad, overlay: Tone
  /// Folders in Files: ANSI blue, legible on the panel.
  var folder: Tone

  var id: String { name }

  var isDark: Bool {
    let r = Double((bg.rgb >> 16) & 0xFF), g = Double((bg.rgb >> 8) & 0xFF), b = Double(bg.rgb & 0xFF)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128
  }

  /// The app's colours follow the terminal theme: ground, panel and text
  /// are the theme's own colours mixed toward each other; the accent (what
  /// needs you) is `accent`, else the cursor colour if it has colour, else
  /// the first coloured of ANSI bright yellow, yellow, bright blue, blue,
  /// bright cyan, cyan, moved toward the text until it reads on the ground;
  /// ok, warn and bad are ANSI green, yellow and red; folders ANSI blue.
  static func derived(from theme: Theme, accent override: UInt32? = nil) -> AppTheme {
    let bg = theme.background, fg = theme.foreground
    let raised = mix(bg, fg, 0.035)
    let given = ([theme.cursor] + [11, 3, 12, 4, 14, 6].map { theme.palette[$0] }).first { chroma($0) >= 0.25 }
    let accent = legible(override ?? given ?? theme.palette[11], on: bg, ratio: 3, toward: fg)
    return AppTheme(
      name: theme.name,
      bg: Tone(rgb: bg), raised: Tone(rgb: raised),
      fg: Tone(rgb: fg),
      fg2: Tone(rgb: legible(mix(fg, bg, 0.32), on: raised, ratio: 4.5, toward: fg)),
      muted: Tone(rgb: legible(mix(fg, bg, 0.52), on: raised, ratio: 3, toward: fg)),
      faint: Tone(rgb: mix(fg, bg, 0.74)),
      fill: Tone(rgb: fg, opacity: 0.06), fill2: Tone(rgb: fg, opacity: 0.1), fill3: Tone(rgb: fg, opacity: 0.16),
      line: Tone(rgb: fg, opacity: 0.09), line2: Tone(rgb: fg, opacity: 0.18),
      accent: Tone(rgb: accent), onAccent: Tone(rgb: onAccent(for: accent, background: bg)),
      ok: Tone(rgb: theme.palette[2]), warn: Tone(rgb: theme.palette[3]), bad: Tone(rgb: theme.palette[1]),
      overlay: Tone(rgb: mix(bg, 0x000000, 0.6), opacity: 0.3),
      folder: Tone(rgb: legible(theme.palette[4], on: raised, ratio: 3, toward: fg)))
  }

  /// The fixed palette (Match Terminal off): Term's own Dusk (a violet-black
  /// ground, near-white text, a mint cursor), with the accent replaced when one is picked.
  static func fixed(accent override: UInt32? = nil) -> AppTheme {
    derived(from: Theme.dusk, accent: override)
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
}

/// The current app theme as a UIKit trait, set on every window scene, so
/// dynamic colours (Chrome.UI) resolve against it and refresh when it changes.
struct AppThemeTrait: UITraitDefinition {
  static let defaultValue = AppTheme.fixed()
  static let affectsColorAppearance = true
}

extension UIWindowScene {
  /// Hands the current app theme to this scene's views.
  @MainActor func applyAppTheme() {
    traitOverrides[AppThemeTrait.self] = AppSettings.shared.appTheme
  }
}
