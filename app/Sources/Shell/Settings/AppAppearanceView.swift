import SwiftUI
import UIKit

/// The App side of Appearance: the app's own colours, glass, type, icon and feel.
struct AppAppearancePage: View {
  @Bindable private var settings = AppSettings.shared
  @State private var icon = AppIcon.current

  /// Picked accents after the first swatch, which is the terminal's cursor (nil).
  private static let hues: [(rgb: UInt32, name: String)] = [
    (0xF2A65A, "Amber"), (0xFF6B86, "Rose"), (0x7AA2FF, "Blue"), (0xB79BFF, "Violet"), (0xF5D547, "Yellow"),
  ]

  var body: some View {
    List {
      ListSection("Colors") {
        Toggle("Match Terminal", isOn: $settings.appMatchesTerminal)
        HStack {
          Text("Glass")
          Spacer()
          CapsuleSegmented(options: [(GlassStyle.clear, "Clear"), (.tinted, "Tinted")], selection: settings.glassStyle,
                           fills: false) { settings.glassStyle = $0 }
        }
      }
      ListSection("Accent") {
        HStack(spacing: Chrome.Space.s) {
          Text(Self.hues.first { $0.rgb == settings.appAccent }?.name ?? "Cursor")
          Spacer(minLength: Chrome.Space.s)
          swatch(nil, name: "Cursor")
          ForEach(Self.hues, id: \.rgb) { swatch($0.rgb, name: $0.name) }
        }
      }
      Section {
        CapsuleSegmented(options: [(TextSize.small, "Small"), (.standard, "Default"), (.large, "Large")],
                         selection: settings.textSize) { settings.textSize = $0 }
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      } header: {
        SectionLabel("Text Size")
      }
      Section {
        HStack(spacing: Chrome.Space.m) {
          ForEach(AppIcon.allCases, id: \.self) { iconTile($0) }
        }
        .padding(.horizontal, Chrome.Space.xs)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      } header: {
        SectionLabel("App Icon")
      }
      ListSection("Feel") {
        Toggle("Haptics", isOn: $settings.haptics)
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

  /// A home screen icon to pick, ringed in the accent when it is the one in use.
  private func iconTile(_ choice: AppIcon) -> some View {
    let selected = choice == icon
    return Button {
      guard !selected else { return }
      icon = choice
      Task {
        // iOS confirms the change with its own alert; a refusal puts the ring back.
        do { try await UIApplication.shared.setAlternateIconName(choice.assetName) } catch { icon = AppIcon.current }
      }
    } label: {
      choice.preview
        .resizable()
        .frame(width: AppIcon.side, height: AppIcon.side)
        .clipShape(RoundedRectangle(cornerRadius: AppIcon.side * 0.225, style: .continuous))
        .padding(3)
        .overlay {
          RoundedRectangle(cornerRadius: AppIcon.side * 0.225 + 3, style: .continuous)
            .strokeBorder(Chrome.accent, lineWidth: 2)
            .opacity(selected ? 1 : 0)
        }
    }
    .buttonStyle(PressScale())
    .animation(Chrome.quick, value: selected)
    .accessibilityLabel(choice.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The home screen icons Term comes with (app/Resources/Assets.xcassets,
/// the alternates drawn by scripts/app-icons.swift).
enum AppIcon: CaseIterable {
  case standard, porcelain, graphite

  static let side: CGFloat = 64

  var title: String {
    switch self {
    case .standard: "Default"
    case .porcelain: "Porcelain"
    case .graphite: "Graphite"
    }
  }

  /// The alternate icon's asset; nil for the primary.
  var assetName: String? { self == .standard ? nil : "AppIcon-\(title)" }

  /// Its Settings tile (AppIconPreview-*, made by scripts/app-icons.swift): app icon sets don't load as images.
  var preview: Image { Image("AppIconPreview-\(title)") }

  @MainActor static var current: AppIcon {
    let name = UIApplication.shared.alternateIconName
    return allCases.first { $0.assetName == name } ?? .standard
  }
}
