import SwiftUI
import UIKit

/// Colours of the app's own surfaces (menu panel, Settings, Files, HUD,
/// banners); the terminal's come from `Theme`. Helm.* reads the current one
/// (AppSettings.appTheme): SwiftUI views through observation, UIKit views
/// through `AppThemeTrait` on each window scene.
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

  /// The presets; the first is the default.
  static let all: [AppTheme] = [standard]

  static func named(_ name: String) -> AppTheme {
    all.first { $0.name == name } ?? all[0]
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
