import SwiftUI

/// A page of Settings beyond its root.
enum SettingsPage: Hashable {
  case hosts, host(Host), newHost
  case keys, key(Keychain.Key), generateKey, importKey
  case appearance, themes, fontFamily
  case keyboard, voice, about
}

/// How a page opens the next one or goes back.
struct SettingsNav: Sendable {
  var push: @MainActor @Sendable (SettingsPage) -> Void
  var pop: @MainActor @Sendable () -> Void
}

extension EnvironmentValues {
  @Entry var settingsNav = SettingsNav(push: { _ in assertionFailure("outside SettingsView") },
                                       pop: { assertionFailure("outside SettingsView") })
  /// False while a page is covered by the one pushed over it.
  @Entry var settingsPageIsTop = true
}

/// Settings, shown in the menu panel: `config` at the prompt, ⌘, or the menu.
///
/// Its own page stack, not a NavigationStack: pages sit on the panel's glass
/// with clear grounds, and the system push slides one page over another with
/// both showing through. Here the page beneath fades as the next slides in,
/// pages keep their state while covered, and a swipe from the leading edge
/// goes back with the page beneath fading in under the finger.
struct SettingsView: View {
  @State private var path: [SettingsPage]
  /// How far the top page is dragged by the back swipe.
  @State private var swipe: CGFloat = 0

  private struct Level: Hashable {
    let depth: Int
    let page: SettingsPage?
  }

  /// `start` opens a page straight away (the mic key with no OpenRouter key opens Voice).
  init(start: SettingsPage? = nil) {
    _path = State(initialValue: start.map { [$0] } ?? [])
  }

  var body: some View {
    GeometryReader { geo in
      let width = max(geo.size.width, 1)
      let progress = min(max(swipe / width, 0), 1)
      let levels = [Level(depth: 0, page: nil)] + path.enumerated().map { Level(depth: $0.offset + 1, page: $0.element) }
      ZStack {
        ForEach(levels, id: \.self) { level in
          let above = path.count - level.depth
          view(for: level.page)
            .environment(\.settingsPageIsTop, above == 0)
            // Pages fade quicker than they slide, so the one leaving is
            // gone before the one arriving crosses it; the swipe drives the fade itself.
            .animation(swipe == 0 ? Chrome.fade : nil) { $0.opacity(above == 0 ? 1 : above == 1 ? progress : 0) }
            .offset(x: above == 0 ? swipe : above == 1 ? -width / 4 * (1 - progress) : 0)
            .allowsHitTesting(above == 0)
            .accessibilityHidden(above != 0)
            .zIndex(Double(level.depth))
            .transition(.offset(x: width).combined(with: .opacity.animation(Chrome.fade)))
        }
      }
      .overlay(alignment: .leading) {
        if !path.isEmpty { backSwipe(width: width) }
      }
    }
    .environment(\.settingsNav, SettingsNav(push: push, pop: pop))
  }

  private func push(_ page: SettingsPage) {
    withAnimation(Chrome.spring) { path.append(page) }
  }

  private func pop() {
    guard !path.isEmpty else { return }
    withAnimation(Chrome.spring) {
      swipe = 0
      path.removeLast()
    }
  }

  /// The leading edge of a pushed page: drag right to go back.
  private func backSwipe(width: CGFloat) -> some View {
    Color.clear
      .frame(width: Chrome.Space.l)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: Chrome.Space.s, coordinateSpace: .global)
          .onChanged { swipe = max($0.translation.width, 0) }
          .onEnded { drag in
            if max(drag.translation.width, drag.predictedEndTranslation.width) > width / 2 {
              pop()
            } else {
              withAnimation(Chrome.spring) { swipe = 0 }
            }
          }
      )
  }

  @ViewBuilder private func view(for page: SettingsPage?) -> some View {
    switch page {
    case nil: SettingsRoot()
    case .hosts: HostsView()
    case .host(let host): HostEditor(host: host, isNew: false)
    case .newHost: HostEditor(host: Host(alias: "", hostname: "", user: ""), isNew: true)
    case .keys: KeysView()
    case .key(let key): KeyDetailView(key: key)
    case .generateKey: GenerateKeyView(existing: Set(Keychain.keys().map(\.name)))
    case .importKey: ImportKeyView(existing: Set(Keychain.keys().map(\.name)))
    case .appearance: AppearanceView()
    case .themes: ThemesView()
    case .fontFamily: FontFamilyView()
    case .keyboard: KeyboardSettingsView()
    case .voice: VoiceView()
    case .about: AboutView()
    }
  }
}

/// A pushed page: the back button and title over its content, actions trailing.
struct SettingsPageView<Trailing: View, Content: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var content: Content
  @Environment(\.settingsNav) private var nav

  var body: some View {
    PageScaffold(title: title, back: nav.pop) { trailing } content: { content }
  }
}

extension SettingsPageView where Trailing == EmptyView {
  init(title: String, @ViewBuilder content: () -> Content) {
    self.init(title: title, trailing: { EmptyView() }, content: content)
  }
}

/// A list row that opens a page: its label, a value, a chevron.
struct PageRow<Label: View>: View {
  let page: SettingsPage
  var value: String?
  /// Words (a theme name) in SF Pro; machine facts (a count, a version) in SF Mono.
  var monoValue = true
  @ViewBuilder var label: Label
  @Environment(\.settingsNav) private var nav

  var body: some View {
    Button { nav.push(page) } label: {
      HStack(spacing: Chrome.Space.s) {
        label
        Spacer(minLength: Chrome.Space.s)
        if let value { ValueText(value, mono: monoValue) }
        Chevron()
      }
      .listRowContent()
    }
    .buttonStyle(RowStyle())
    .listRowInsets(EdgeInsets())
  }
}

/// The trailing mark of a row that opens something.
struct Chevron: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .font(Chrome.symbol(.inline))
      .foregroundStyle(Chrome.faint)
  }
}

extension View {
  /// A full-width row's content inside a List row with zero insets: the
  /// group's text inset and row height, the whole row pressable.
  func listRowContent() -> some View {
    padding(.horizontal, Chrome.Space.l)
      .frame(maxWidth: .infinity, minHeight: Chrome.Size.row, alignment: .leading)
      .contentShape(Rectangle())
  }
}

/// The root page under the tab: what the pages are, with their headline values.
private struct SettingsRoot: View {
  private let config = ConfigStore.shared
  private let settings = AppSettings.shared

  var body: some View {
    List {
      ListSection("Connect") {
        PageRow(page: .hosts, value: "\(config.hosts.count)") { IconLabel("Hosts", symbol: "server.rack") }
        PageRow(page: .keys) { IconLabel("Keys", symbol: "key") }
      }
      ListSection {
        PageRow(page: .appearance, value: settings.themeName, monoValue: false) {
          IconLabel("Appearance", symbol: "paintpalette")
        }
        PageRow(page: .keyboard) { IconLabel("Keyboard", symbol: "keyboard") }
        PageRow(page: .voice, value: VoiceView.summary, monoValue: false) { IconLabel("Voice", symbol: "mic") }
      }
      ListSection {
        PageRow(page: .about, value: AboutView.version) { IconLabel("About", symbol: "info.circle") }
      }
    }
    .chromeList()
  }
}

struct KeyboardSettingsView: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    SettingsPageView(title: "Keyboard") {
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
    SettingsPageView(title: "About") {
      List {
        ListSection {
          ValueRow("Version", Self.version)
          ValueRow("Terminal Engine", "libghostty-vt cec8b92f")
          ValueRow("Font", "JetBrains Mono, Iosevka (Nerd Fonts)")
        }
        ListSection("Licenses") {
          Text("JetBrains Mono, Iosevka: SIL Open Font License 1.1. Nerd Fonts glyphs: MIT and OFL. Ghostty: MIT. "
            + "Terminal themes: iTerm2-Color-Schemes (Mark Badolato and contributors), MIT; each theme belongs to its author.")
            .font(Chrome.font(.secondary))
            .foregroundStyle(Chrome.muted)
            .padding(.vertical, Chrome.Space.m)
        }
      }
      .chromeList()
    }
  }
}
