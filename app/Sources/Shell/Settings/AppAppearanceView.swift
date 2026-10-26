import SwiftUI
import UIKit

/// The App side of Appearance: how the app's own colours follow the terminal.
struct AppAppearancePage: View {
  @Bindable private var settings = AppSettings.shared

  /// Picked accents after the first swatch, which is the terminal's cursor (nil).
  private static let hues: [(rgb: UInt32, name: String)] = [
    (0xF2A65A, "Amber"), (0xFF6B86, "Rose"), (0x7AA2FF, "Blue"), (0xB79BFF, "Violet"), (0xF5D547, "Yellow"),
  ]

  var body: some View {
    List {
      ListSection("Colors") {
        Toggle("Match Terminal", isOn: $settings.appMatchesTerminal)
      }
      ListSection("Accent") {
        HStack(spacing: Chrome.Space.s) {
          Text(Self.hues.first { $0.rgb == settings.appAccent }?.name ?? "Cursor")
          Spacer(minLength: Chrome.Space.s)
          swatch(nil, name: "Cursor")
          ForEach(Self.hues, id: \.rgb) { swatch($0.rgb, name: $0.name) }
        }
      }
      if UIApplication.shared.supportsMultipleScenes {
        ListSection("Layout") {
          Toggle("Two Panes", isOn: $settings.splitWhenFlat)
        }
      }
    }
    .chromeList()
  }

  /// A colour to pick; nil is the one the theme gives (its cursor's).
  private func swatch(_ rgb: UInt32?, name: String) -> some View {
    let given = settings.appMatchesTerminal ? AppTheme.derived(from: settings.theme) : AppTheme.fixed()
    let selected = settings.appAccent == rgb
    return Button { settings.appAccent = rgb } label: {
      Circle().fill(Color(hex: rgb ?? given.accent.rgb))
        .frame(width: 20, height: 20)
        .padding(3)
        .overlay(Circle().strokeBorder(Chrome.fg, lineWidth: 2).opacity(selected ? 1 : 0))
        .frame(width: 30, height: Chrome.Size.target)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressScale(0.9))
    .animation(Chrome.quick, value: selected)
    .accessibilityLabel(name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
