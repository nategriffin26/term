import SwiftUI
import UIKit

/// The App side of Appearance: how the app's own colours follow the terminal.
struct AppAppearancePage: View {
  @Bindable private var settings = AppSettings.shared

  /// Picked accents; "From Terminal" (nil) is the first swatch.
  private static let hues: [UInt32] = [0xF2A65A, 0xFF6B86, 0x7AA2FF, 0xB79BFF, 0xF5D547]

  var body: some View {
    List {
      HelmSection("Colors") {
        Toggle("Match Terminal", isOn: $settings.appMatchesTerminal)
        VStack(alignment: .leading, spacing: 10) {
          Text("Accent")
          HStack(spacing: 14) {
            swatch(nil)
            ForEach(Self.hues, id: \.self) { swatch($0) }
          }
        }
        .padding(.vertical, 4)
      }
      if UIApplication.shared.supportsMultipleScenes {
        HelmSection("Layout") {
          Toggle("Two Panes", isOn: $settings.splitWhenFlat)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }

  /// A colour to pick; nil is the one the theme gives (the first swatch shows it).
  private func swatch(_ rgb: UInt32?) -> some View {
    let given = settings.appMatchesTerminal ? AppTheme.derived(from: settings.theme) : AppTheme.standard
    let shown = rgb ?? given.accent.rgb
    let selected = settings.appAccent == rgb
    return Button { settings.appAccent = rgb } label: {
      Circle().fill(Color(hex: shown)).frame(width: 26, height: 26)
        .padding(4)
        .overlay(Circle().strokeBorder(Helm.fg, lineWidth: selected ? 2 : 0))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(rgb == nil ? "From Terminal" : String(format: "#%06X", rgb!))
  }
}
