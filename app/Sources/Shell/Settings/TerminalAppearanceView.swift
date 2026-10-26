import SwiftUI
import UIKit

/// A terminal appearance page: the live preview pinned above its list.
struct PreviewPage<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      PreviewCard()
        .padding(.horizontal, Chrome.Space.m)
        .padding(.bottom, Chrome.Space.xs)
      content
    }
  }
}

/// The live preview on the theme's ground, its sixteen colours under it.
private struct PreviewCard: View {
  private let settings = AppSettings.shared
  @Environment(\.displayScale) private var scale

  /// The sample's lines at the current font, size and line height: the cells the terminal will draw.
  private var previewHeight: CGFloat {
    let fonts = FontSet(family: settings.fontFamily, pointSize: CGFloat(settings.fontSize), scale: scale,
                        lineHeight: CGFloat(settings.lineSpacing))
    return CGFloat(fonts.metrics.height) / scale * CGFloat(PreviewView.lines)
  }

  var body: some View {
    let theme = settings.theme
    VStack(alignment: .leading, spacing: Chrome.Space.m) {
      TerminalPreview().frame(height: previewHeight)
      HStack(spacing: 0) {
        ForEach(0..<16, id: \.self) { i in
          Circle().fill(Color(hex: theme.palette[i])).frame(width: 8, height: 8)
          if i < 15 { Spacer(minLength: 0) }
        }
      }
    }
    .padding(Chrome.Space.m)
    .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: Chrome.Radius.tile, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.tile, style: .continuous).strokeBorder(Chrome.line, lineWidth: 1))
  }
}

/// The Terminal side of Appearance: theme, font, cursor.
struct TerminalAppearancePage: View {
  @Bindable private var settings = AppSettings.shared

  /// The themes on the strip; the rest are behind All.
  static let strip = ["Dusk", "Tomorrow Night", "Catppuccin Mocha", "Gruvbox Dark", "Solarized Light", "Term",
                      "Dracula", "Nord", "Rose Pine Dawn"]

  /// The strip's names: the current theme first when the strip lacks it, and
  /// only names the catalog has (an unknown name would show its fallback twice).
  static func stripNames(current: String, catalog: [String]) -> [String] {
    var names = strip.filter(catalog.contains)
    if !names.contains(current), catalog.contains(current) { names.insert(current, at: 0) }
    return names
  }

  var body: some View {
    PreviewPage {
      List {
        Section {
          themeStrip
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
          HStack {
            SectionLabel("Theme")
            Spacer()
            PageLink(title: "All", page: .themes)
          }
        }
        ListSection("Font") {
          PageRow(page: .fontFamily, value: settings.fontFamily, monoValue: false) { Text("Family") }
          SliderRow(label: "Size", value: $settings.fontSize, range: AppSettings.fontSizeRange, step: 1,
                    text: "\(Int(settings.fontSize)) pt")
          SliderRow(label: "Line Height", value: $settings.lineSpacing, range: AppSettings.lineSpacingRange,
                    step: 0.05, text: String(format: "%.2f", settings.lineSpacing))
          Toggle("Bold as Bright", isOn: $settings.boldIsBright)
        }
        ListSection("Cursor") {
          HStack {
            Text("Shape")
            Spacer()
            CapsuleSegmented(values: CursorShape.allCases, selection: settings.cursorShape, fills: false) {
              settings.cursorShape = $0
            } label: { shape, selected in
              CursorGlyph(shape: shape, selected: selected)
            }
          }
          Toggle("Blink", isOn: $settings.cursorBlink)
          Toggle("Follow Programs", isOn: $settings.cursorFollowsPrograms)
          HStack {
            Text("Color")
            Spacer()
            CapsuleSegmented(options: [(CursorColor.theme, "Theme"), (.accent, "Accent")],
                             selection: settings.cursorColor, fills: false) { settings.cursorColor = $0 }
          }
        }
      }
      .chromeList()
    }
  }

  private var themeStrip: some View {
    let names = Self.stripNames(current: settings.themeName, catalog: Theme.all.map(\.name))
    return ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: Chrome.Space.s) {
          ForEach(names, id: \.self) { name in
            Button { settings.themeName = name } label: {
              ThemeTile(theme: Theme.named(name), selected: name == settings.themeName)
            }
            .buttonStyle(PressScale())
            .id(name)
          }
        }
        .padding(.horizontal, Chrome.Space.xs)
        .padding(.vertical, Chrome.Space.xs)
      }
      .onAppear { proxy.scrollTo(settings.themeName, anchor: .center) }
    }
  }
}

/// A cursor shape drawn as the terminal draws it, for the shape picker.
private struct CursorGlyph: View {
  let shape: CursorShape
  let selected: Bool

  var body: some View {
    let color = selected ? Chrome.accent : Chrome.fg2
    ZStack(alignment: .bottom) {
      Color.clear
      switch shape {
      case .block: RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 9)
      case .bar: Capsule().fill(color).frame(width: 2)
      case .underline: Capsule().fill(color).frame(width: 10, height: 2)
      }
    }
    .frame(width: 10, height: 16)
    .accessibilityElement()
    .accessibilityLabel(shape.rawValue.capitalized)
  }
}

/// A section's link to a page: a word in fg2 at the header's trailing edge.
private struct PageLink: View {
  let title: String
  let page: SettingsPage
  @Environment(\.settingsNav) private var nav

  var body: some View {
    Button(title) { nav.push(page) }
      .font(Chrome.font(.secondary, .semibold))
      .foregroundStyle(Chrome.fg2)
      .buttonStyle(PressScale())
      .frame(minHeight: Chrome.Size.target)
      .contentShape(Rectangle())
  }
}

/// A theme on the strip: its look and name; the picked one is ringed in the accent.
private struct ThemeTile: View {
  let theme: Theme
  let selected: Bool

  var body: some View {
    VStack(spacing: Chrome.Space.s) {
      ThemeThumbnail(theme: theme)
        .padding(3)
        .overlay {
          RoundedRectangle(cornerRadius: ThemeThumbnail.radius + 3, style: .continuous)
            .strokeBorder(Chrome.accent, lineWidth: 2)
            .opacity(selected ? 1 : 0)
        }
      Text(theme.name)
        .font(Chrome.font(.caption, selected ? .semibold : .medium))
        .foregroundStyle(selected ? Chrome.fg : Chrome.muted)
        .lineLimit(1)
    }
    .frame(width: ThemeThumbnail.width + 6)
    .animation(Chrome.quick, value: selected)
  }
}

struct ThemesView: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    SettingsPageView(title: "Themes") {
      PreviewPage {
        ScrollViewReader { proxy in
          List {
            section("Dark", Theme.all.filter(\.isDark))
            section("Light", Theme.all.filter { !$0.isDark })
          }
          .chromeList()
          .onAppear { proxy.scrollTo(settings.themeName, anchor: .center) }
        }
      }
    }
  }

  @ViewBuilder private func section(_ title: String, _ themes: [Theme]) -> some View {
    if !themes.isEmpty {
      ListSection(title) {
        ForEach(themes) { theme in
          ChoiceRow(chosen: theme.name == settings.themeName) {
            settings.themeName = theme.name
          } label: {
            ThemeThumbnail(theme: theme, compact: true)
            Text(theme.name)
          }
          .id(theme.name)
        }
      }
    }
  }
}

/// A row that picks one of a list: its label, a check on the chosen one.
struct ChoiceRow<Label: View>: View {
  let chosen: Bool
  let pick: () -> Void
  @ViewBuilder var label: Label

  var body: some View {
    Button(action: pick) {
      HStack(spacing: Chrome.Space.m) {
        label
        Spacer(minLength: Chrome.Space.s)
        Image(systemName: "checkmark")
          .font(Chrome.symbol(.inline))
          .foregroundStyle(Chrome.accent)
          .opacity(chosen ? 1 : 0)
      }
      .foregroundStyle(Chrome.fg)
      .padding(.vertical, Chrome.Space.s)
      .listRowContent()
    }
    .buttonStyle(RowStyle())
    .listRowInsets(EdgeInsets())
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }
}

/// A theme at a glance: a prompt and a listing on its ground, over a bar of
/// its colours; compact (for a list row), the prompt alone.
struct ThemeThumbnail: View {
  static let width: CGFloat = 104
  static let radius = Chrome.Radius.thumb
  let theme: Theme
  var compact = false

  private func color(_ i: Int) -> Color { Color(hex: theme.palette[i]) }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(Text("~").foregroundStyle(color(4))) \(Text("❯").foregroundStyle(color(2))) ls")
      if !compact {
        Text("\(Text("src").foregroundStyle(color(4))) a.md \(Text("b.rs").foregroundStyle(color(3)))")
      }
      HStack(spacing: 0) {
        ForEach([1, 3, 2, 6, 4, 5], id: \.self) { i in color(i) }
      }
      .frame(height: 4)
      .clipShape(Capsule())
      .padding(.top, compact ? 4 : 6)
    }
    .font(Chrome.mono(.caption, .medium))
    .foregroundStyle(Color(hex: theme.foreground))
    .lineLimit(1)
    .padding(.horizontal, 6)
    .padding(.vertical, Chrome.Space.s)
    .frame(width: compact ? 64 : Self.width, alignment: .leading)
    .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Chrome.line, lineWidth: 1))
  }
}

struct FontFamilyView: View {
  @Bindable private var settings = AppSettings.shared
  private let families = FontFamilyView.monospacedFamilies()

  var body: some View {
    SettingsPageView(title: "Font") {
      PreviewPage {
        List {
          ListSection {
            ForEach(families, id: \.self) { family in
              ChoiceRow(chosen: family == settings.fontFamily) {
                settings.fontFamily = family
              } label: {
                Text(family).font(.custom(family, size: Chrome.TextStep.body.rawValue))
              }
            }
          }
        }
        .chromeList()
      }
    }
  }

  /// The bundled Nerd Fonts first, then the installed monospaced families (Blink lists them all).
  static func monospacedFamilies() -> [String] {
    let bundled = FontSet.bundled.map(\.family)
    let mono = UIFont.familyNames.filter { family in
      UIFont.fontNames(forFamilyName: family).contains { name in
        UIFont(name: name, size: 12)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
      }
    }
    return bundled + mono.filter { !bundled.contains($0) }.sorted()
  }
}
