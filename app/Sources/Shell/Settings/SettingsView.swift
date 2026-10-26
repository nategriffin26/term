import SwiftUI

/// Settings, shown in the menu panel: `config` at the prompt, ⌘, or the menu.
struct SettingsView: View {
  private let config = ConfigStore.shared
  private let settings = AppSettings.shared

  var body: some View {
    NavigationStack {
      List {
        ListSection("Connect") {
          NavigationLink { HostsView() } label: {
            LabeledContent { ValueText("\(config.hosts.count)") } label: { IconLabel("Hosts", symbol: "server.rack") }
          }
          NavigationLink { KeysView() } label: {
            IconLabel("Keys", symbol: "key")
          }
        }
        ListSection {
          NavigationLink { AppearanceView() } label: {
            LabeledContent { ValueText(settings.themeName) } label: { IconLabel("Appearance", symbol: "paintpalette") }
          }
          NavigationLink { KeyboardSettingsView() } label: {
            IconLabel("Keyboard", symbol: "keyboard")
          }
        }
        ListSection {
          NavigationLink { AboutView() } label: {
            LabeledContent { ValueText(AboutView.version) } label: { IconLabel("About", symbol: "info.circle") }
          }
        }
      }
      .chromeList()
      .navigationTitle("Settings")
      .toolbar(.hidden, for: .navigationBar)
    }
  }
}

struct KeyboardSettingsView: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    List {
      ListSection("Key Repeat") {
        SliderRow(label: "Delay", value: $settings.keyRepeatDelay, range: AppSettings.keyRepeatDelayRange,
                     step: 0.05, text: String(format: "%.2f s", settings.keyRepeatDelay))
        SliderRow(label: "Rate", value: $settings.keyRepeatRate, range: AppSettings.keyRepeatRateRange,
                     step: 1, text: "\(Int(settings.keyRepeatRate)) /s")
      }
      ListSection("Smart Keys") {
        Toggle("Show with Hardware Keyboard", isOn: $settings.smartKeysWithHardwareKeyboard)
        Toggle("Key Clicks", isOn: $settings.keyClickSound)
      }
      ListSection("Shortcuts") {
        ValueRow("New Shell", "⌘T")
        ValueRow("Close Shell", "⌘W")
        ValueRow("Next / Previous Shell", "⇧⌘] / ⇧⌘[")
        ValueRow("Settings", "⌘,")
      }
    }
    .chromeList()
    .navigationTitle("Keyboard")
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
      ValueRow("Version", Self.version)
      ValueRow("Terminal Engine", "libghostty-vt cec8b92f")
      ValueRow("Font", "JetBrains Mono, Iosevka (Nerd Fonts)")
      ListSection("Licenses") {
        Text("JetBrains Mono, Iosevka: SIL Open Font License 1.1. Nerd Fonts glyphs: MIT and OFL. Ghostty: MIT. "
          + "Terminal themes: iTerm2-Color-Schemes, MIT; each theme belongs to its author.")
          .font(Chrome.font(.secondary))
          .foregroundStyle(Chrome.muted)
      }
    }
    .chromeList()
    .navigationTitle("About")
  }
}
