import SwiftUI

/// Settings, shown in the menu panel: `config` at the prompt, ⌘, or the menu.
struct SettingsView: View {
  private let config = ConfigStore.shared
  private let settings = AppSettings.shared

  var body: some View {
    NavigationStack {
      List {
        HelmSection("Connect") {
          NavigationLink { HostsView() } label: {
            LabeledContent { HelmValue("\(config.hosts.count)") } label: { HelmLabel("Hosts", symbol: "server.rack") }
          }
          NavigationLink { KeysView() } label: {
            HelmLabel("Keys", symbol: "key")
          }
        }
        HelmSection("Terminal") {
          NavigationLink { AppearanceView() } label: {
            LabeledContent { HelmValue(settings.themeName) } label: { HelmLabel("Appearance", symbol: "paintpalette") }
          }
          NavigationLink { KeyboardSettingsView() } label: {
            HelmLabel("Keyboard", symbol: "keyboard")
          }
        }
        HelmSection {
          NavigationLink { AboutView() } label: {
            LabeledContent { HelmValue(AboutView.version) } label: { HelmLabel("About", symbol: "info.circle") }
          }
        }
      }
      .helmList()
      .navigationTitle("Settings")
      .toolbar(.hidden, for: .navigationBar)
    }
  }
}

struct KeyboardSettingsView: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    List {
      HelmSection("Key Repeat") {
        RepeatSlider(label: "Delay", value: $settings.keyRepeatDelay, range: AppSettings.keyRepeatDelayRange,
                     step: 0.05, text: String(format: "%.2f s", settings.keyRepeatDelay))
        RepeatSlider(label: "Rate", value: $settings.keyRepeatRate, range: AppSettings.keyRepeatRateRange,
                     step: 1, text: "\(Int(settings.keyRepeatRate)) /s")
      }
      HelmSection("Smart Keys") {
        Toggle("Show with Hardware Keyboard", isOn: $settings.smartKeysWithHardwareKeyboard)
        Toggle("Key Clicks", isOn: $settings.keyClickSound)
      }
      HelmSection("Shortcuts") {
        HelmRow("New Shell", "⌘T")
        HelmRow("Close Shell", "⌘W")
        HelmRow("Next / Previous Shell", "⇧⌘] / ⇧⌘[")
        HelmRow("Settings", "⌘,")
      }
    }
    .helmList()
    .navigationTitle("Keyboard")
  }
}

/// A setting row: label left, value in mono right, the slider under them.
private struct RepeatSlider: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let text: String

  var body: some View {
    VStack(spacing: 4) {
      LabeledContent { HelmValue(text) } label: { Text(label) }
      Slider(value: $value, in: range, step: step)
    }
  }
}

struct AboutView: View {
  static let version: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }()

  var body: some View {
    List {
      HelmRow("Version", Self.version)
      HelmRow("Terminal Engine", "libghostty-vt cec8b92f")
      HelmRow("Font", "JetBrains Mono, Iosevka (Nerd Fonts)")
      HelmSection("Licenses") {
        Text("JetBrains Mono, Iosevka: SIL Open Font License 1.1. Nerd Fonts glyphs: MIT and OFL. Ghostty: MIT.")
          .font(Helm.sans(12))
          .foregroundStyle(Helm.muted)
      }
    }
    .helmList()
    .navigationTitle("About")
  }
}
