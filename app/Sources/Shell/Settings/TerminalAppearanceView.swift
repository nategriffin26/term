import SwiftUI
import UIKit

/// A terminal appearance page: the live preview pinned above its list.
struct PreviewPage<Content: View>: View {
  let title: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      TerminalPreview().frame(height: 142)
      Rectangle().fill(Chrome.line2).frame(height: 1)
      content
    }
    .modifier(TitledPage(title: title))
  }
}

private struct TitledPage: ViewModifier {
  let title: String?

  func body(content: Content) -> some View {
    if let title {
      content.chromeList().navigationTitle(title)
    } else {
      content
    }
  }
}

/// The Terminal side of Appearance: theme, font, cursor.
struct TerminalAppearancePage: View {
  @Bindable private var settings = AppSettings.shared

  /// The themes shown on the strip; the rest are behind All.
  private static let strip = ["Term", "Tomorrow Night", "Dracula", "Nord", "Gruvbox Dark", "Catppuccin Mocha",
                              "Solarized Dark", "Solarized Light"]

  private var stripThemes: [Theme] {
    var names = Self.strip
    if !names.contains(settings.themeName) { names.insert(settings.themeName, at: 0) }
    return names.map(Theme.named)
  }

  var body: some View {
    PreviewPage(title: nil) {
      List {
        Section {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
              ForEach(stripThemes) { theme in
                Button { settings.themeName = theme.name } label: {
                  ThemeTile(theme: theme, selected: theme.name == settings.themeName)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
          }
          .listRowInsets(EdgeInsets())
          Toggle("Bold as Bright", isOn: $settings.boldIsBright)
        } header: {
          HStack {
            Text("Theme").font(Chrome.font(.secondary, .medium)).foregroundStyle(Chrome.muted)
            Spacer()
            NavigationLink("All") { ThemesView() }
              .font(Chrome.font(.secondary, .medium))
              .foregroundStyle(Chrome.accent)
          }
          .textCase(nil)
        }
        .listRowBackground(Color.clear)
        ListSection("Font") {
          NavigationLink { FontFamilyView() } label: {
            LabeledContent { ValueText(settings.fontFamily) } label: { Text("Family") }
          }
          SliderRow(label: "Size", value: $settings.fontSize, range: AppSettings.fontSizeRange, step: 1,
                     text: "\(Int(settings.fontSize)) pt")
          SliderRow(label: "Line Height", value: $settings.lineSpacing, range: AppSettings.lineSpacingRange,
                     step: 0.05, text: String(format: "%.2f", settings.lineSpacing))
        }
        ListSection("Cursor") {
          LabeledContent {
            Picker("Shape", selection: $settings.cursorShape) {
              ForEach(CursorShape.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
          } label: { Text("Shape") }
          Toggle("Blink", isOn: $settings.cursorBlink)
          Toggle("Follow Programs", isOn: $settings.cursorFollowsPrograms)
          LabeledContent {
            Picker("Color", selection: $settings.cursorColor) {
              ForEach(CursorColor.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
          } label: { Text("Color") }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
    }
  }
}

/// A theme on the strip: its look and name; the picked one is ringed in the accent.
private struct ThemeTile: View {
  let theme: Theme
  let selected: Bool

  var body: some View {
    VStack(spacing: 6) {
      ThemeThumbnail(theme: theme)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.accent, lineWidth: selected ? 2 : 0))
      Text(theme.name)
        .font(Chrome.font(.caption, selected ? .semibold : .regular))
        .foregroundStyle(selected ? Chrome.fg : Chrome.muted)
        .lineLimit(1)
    }
    .frame(width: 84)
  }
}

struct ThemesView: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    PreviewPage(title: "Theme") {
      ScrollViewReader { proxy in
        List {
          section("Dark", Theme.all.filter(\.isDark))
          section("Light", Theme.all.filter { !$0.isDark })
        }
        .onAppear { proxy.scrollTo(settings.themeName, anchor: .center) }
      }
    }
  }

  @ViewBuilder private func section(_ title: String, _ themes: [Theme]) -> some View {
    if !themes.isEmpty {
      ListSection(title) {
        ForEach(themes) { theme in
          Button {
            settings.themeName = theme.name
          } label: {
            HStack(spacing: 12) {
              ThemeThumbnail(theme: theme)
              Text(theme.name)
              Spacer()
              if theme.name == settings.themeName {
                Image(systemName: "checkmark").foregroundStyle(Chrome.accent)
              }
            }
          }
          .id(theme.name)
        }
      }
    }
  }
}

/// A theme at a glance: a prompt and cursor on its background, over its six colours.
struct ThemeThumbnail: View {
  let theme: Theme

  private func color(_ rgb: UInt32) -> Color { Color(uiColor: UIColor(rgb: rgb)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 0) {
        Text("$ ls").foregroundStyle(color(theme.palette[2]))
        Rectangle().fill(color(theme.cursor)).frame(width: 5, height: 10).padding(.leading, 2)
      }
      .font(Chrome.mono(.caption, .medium))
      .foregroundStyle(color(theme.foreground))
      HStack(spacing: 2) {
        ForEach(1..<7, id: \.self) { i in
          RoundedRectangle(cornerRadius: 1.5).fill(color(theme.palette[i])).frame(width: 8, height: 6)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .frame(width: 80, alignment: .leading)
    .background(color(theme.background), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.line2, lineWidth: 1))
  }
}

struct FontFamilyView: View {
  @Bindable private var settings = AppSettings.shared
  private let families = FontFamilyView.monospacedFamilies()

  var body: some View {
    PreviewPage(title: "Font") {
      List {
        ForEach(families, id: \.self) { family in
          Button {
            settings.fontFamily = family
          } label: {
            HStack {
              Text(family).font(.custom(family, size: 15))
              Spacer()
              if family == settings.fontFamily {
                Image(systemName: "checkmark").foregroundStyle(Chrome.accent)
              }
            }
          }
        }
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
