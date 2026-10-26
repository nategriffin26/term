import SwiftUI
import UIKit

/// The Sessions tab: the overview of every open session, and the page for
/// starting a new one.
struct SessionsTab: View {
  let model: MenuModel

  var body: some View {
    ZStack {
      switch model.sessionsPage {
      case .grid:
        SessionsOverview(model: model)
          .transition(.asymmetric(insertion: .offset(x: -40).combined(with: .opacity), removal: .offset(x: -40).combined(with: .opacity)))
      case .new:
        NewSessionPage(model: model)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(Helm.spring(0.4), value: model.sessionsPage)
  }
}

// MARK: - Overview

/// A grid of live thumbnails, one per session, in every open window
/// (Mission Control for terminals). Tap zooms into a session.
struct SessionsOverview: View {
  let model: MenuModel
  @Environment(\.displayScale) private var displayScale

  private static let padding: CGFloat = 16
  private static let spacing: CGFloat = 12
  private static let rowSpacing: CGFloat = 16
  private static let groupHead: CGFloat = 28

  var body: some View {
    GeometryReader { geo in
      let groups = model.groups
      let current = model.currentTab
      let aspect = model.aspect
      let tiles = groups.reduce(1) { $0 + $1.tabs.count }
      let heads = groups.count > 1 ? CGFloat(groups.count) * Self.groupHead : 0
      let area = CGSize(width: geo.size.width - 2 * Self.padding,
                        height: geo.size.height - 2 * Self.padding - heads - CGFloat(groups.count - 1) * 18)
      let grid = MenuLayout.overviewGrid(count: tiles, area: area, aspect: aspect, spacing: Self.spacing,
                                         rowSpacing: Self.rowSpacing)
      let tileSize = CGSize(width: grid.tileWidth, height: (grid.tileWidth / aspect).rounded())
      let fonts = thumbnailFonts(groups: groups, tileWidth: grid.tileWidth, family: current?.view.fontFamily)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 10) {
              if groups.count > 1 {
                Text(group.space === model.space ? "This window" : "Other window")
                  .font(Helm.sans(12.5, .semibold))
                  .foregroundStyle(Helm.fg2)
              }
              LazyVGrid(columns: Array(repeating: GridItem(.fixed(grid.tileWidth), spacing: Self.spacing, alignment: .top),
                                       count: grid.columns),
                        alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(group.tabs) { tab in
                  SessionTile(model: model, owner: group.space, tab: tab, isCurrent: tab === current,
                              size: tileSize, fonts: fonts)
                }
                if group.space === model.space {
                  NewTile(size: tileSize) {
                    model.sessionsPage = .new
                  }
                }
              }
            }
          }
        }
        .padding(Self.padding)
        // Mission Control: a grid that fits sits in the middle of the panel.
        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
        .animation(Helm.spring(0.35), value: model.revision)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  /// One font for all thumbnails: the widest session fits its tile, down to
  /// a legible size.
  private func thumbnailFonts(groups: [SessionGroup], tileWidth: CGFloat, family: String?) -> FontSet? {
    let widest = groups.flatMap(\.tabs).map { $0.current.cols }.max() ?? 80
    guard tileWidth > 0, widest > 0 else { return nil }
    let width = tileWidth - 2 * SessionThumbnailView.inset
    let cell = Int((width * displayScale / CGFloat(widest)).rounded(.down))
    return model.thumbnails.fonts(cellWidth: cell, scale: displayScale, family: family ?? FontSet.family)
  }
}

/// A tab's live tile. Tap and History go through the window showing the
/// overview, which brings another window's tab forward; Close goes to the
/// window the tab is in.
private struct SessionTile: View {
  let model: MenuModel
  let owner: SpaceController
  let tab: Tab
  let isCurrent: Bool
  let size: CGSize
  let fonts: FontSet?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        ThumbnailView(source: { tab.current }, renderer: model.thumbnails, fonts: fonts)
          .frame(width: size.width, height: size.height)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(isCurrent ? Helm.accent : Helm.line2, lineWidth: isCurrent ? 1.5 : 1)
          }
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            model.tileFrames[tab.id] = frame
          }
        Button {
          owner.close(tab)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Helm.fg2)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Helm.raised.opacity(0.92)))
            .overlay(Circle().strokeBorder(Helm.line2, lineWidth: 1))
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(0.9))
        .accessibilityLabel("Close \(tab.sessionName)")
      }
      HStack(alignment: .center, spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          Text(tab.sessionName)
            .font(Helm.mono(12.5, .medium))
            .foregroundStyle(isCurrent ? Helm.fg : Helm.fg2)
          HStack(spacing: 5) {
            if let state = Self.state(of: tab) {
              Circle().fill(state).frame(width: 6, height: 6)
            }
            Text(tab.hostName ?? "local")
              .font(Helm.mono(11))
              .foregroundStyle(Helm.muted)
          }
        }
        .lineLimit(1)
        Spacer(minLength: 0)
        if tab.isConnected {
          Button {
            model.space?.showHistory(for: tab)
          } label: {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
              .font(.system(size: 13))
              .foregroundStyle(Helm.muted)
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
          }
          .buttonStyle(PressScale(0.9))
          .accessibilityLabel("History")
        }
      }
      // As tall as the history button, so tiles without one line up.
      .frame(width: size.width, height: 36, alignment: .leading)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.space?.zoom(into: tab) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(tab.sessionName), \(tab.hostName ?? "local")")
    .accessibilityAddTraits(.isButton)
    .contextMenu {
      if tab.isConnected {
        Button("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") { model.space?.showHistory(for: tab) }
      }
      Button("Close", systemImage: "xmark", role: .destructive) { owner.close(tab) }
    }
  }

  /// Dot beside the host: connecting (accent) or out of contact (amber).
  static func state(of tab: Tab) -> Color? {
    if tab.unreachable { return Helm.warn }
    if tab.connecting != nil { return Helm.accent }
    return nil
  }
}

private struct NewTile: View {
  let size: CGSize
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(Helm.muted)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Helm.hover))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
    }
    .buttonStyle(PressScale())
    .accessibilityLabel("New session")
  }
}

/// SwiftUI face of a SessionThumbnailView.
struct ThumbnailView: UIViewRepresentable {
  let source: @MainActor () -> Session?
  let renderer: ThumbnailRenderer
  let fonts: FontSet?
  var inset = SessionThumbnailView.inset

  func makeUIView(context: Context) -> SessionThumbnailView {
    let view = SessionThumbnailView(source: source, inset: inset)
    view.attach(to: renderer)
    view.fonts = fonts
    return view
  }

  func updateUIView(_ view: SessionThumbnailView, context: Context) {
    view.fonts = fonts
  }

  static func dismantleUIView(_ view: SessionThumbnailView, coordinator: ()) {
    view.detach()
  }
}

// MARK: - New session

/// What the + tile opens: a local shell, a saved host, and on the inner
/// display a second window or two panes.
private struct NewSessionPage: View {
  let model: MenuModel
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    PageScaffold(title: "New", back: { model.sessionsPage = .grid }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Row(symbol: "apple.terminal", title: "Shell", mono: false) {
            model.space?.newTabFromMenu()
          }
          GroupHead("Hosts")
          let hosts = ConfigStore.shared.hosts
          ForEach(hosts) { host in
            Row(title: host.alias, detail: "\(host.user)@\(host.hostname)", mono: true) {
              model.space?.open(host)
            }
          }
          if hosts.isEmpty {
            Row(symbol: "plus", title: "Add Host", mono: false) { model.tab = .settings }
          }
          if sizeClass == .regular {
            GroupHead("Window")
            Row(symbol: "macwindow.badge.plus", title: "New Window", mono: false) {
              model.space?.closeMenu()
              SpaceController.openWindow()
            }
            TwoPanesRow()
          }
        }
      }
      .scrollIndicators(.hidden)
    }
  }
}

private struct TwoPanesRow: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    HStack {
      Image(systemName: "rectangle.split.2x1")
        .font(.system(size: 15))
        .foregroundStyle(Helm.fg2)
        .frame(width: 22)
      Text("Two Panes")
        .font(Helm.sans(14, .medium))
        .foregroundStyle(Helm.fg)
      Spacer()
      Segmented(options: ["On", "Off"], selection: settings.splitWhenFlat ? 0 : 1) { settings.splitWhenFlat = $0 == 0 }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 50)
    .overlay(alignment: .bottom) { Rectangle().fill(Helm.line).frame(height: 1) }
  }
}

/// Helm's segmented control: selected = sel fill and fg text, never accent.
struct Segmented: View {
  let options: [String]
  let selection: Int
  let choose: (Int) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options.indices, id: \.self) { i in
        Button { choose(i) } label: {
          Text(options[i])
            .font(Helm.sans(12.5, .medium))
            .foregroundStyle(i == selection ? Helm.fg : Helm.muted)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
              if i == selection { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Helm.sel) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
  }
}

/// A page inside a tab: back chevron and title over the content.
struct PageScaffold<Content: View>: View {
  let title: String
  let back: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 2) {
        Button(action: back) {
          Image(systemName: "chevron.left")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Helm.fg2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(0.92))
        .accessibilityLabel("Back")
        Text(title)
          .font(Helm.sans(15, .semibold))
          .foregroundStyle(Helm.fg)
          .lineLimit(1)
        Spacer()
      }
      .padding(.leading, 4)
      .frame(height: 46)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
}

/// Group head: 12.5/600 in fg-2 (Helm).
struct GroupHead: View {
  let title: String
  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .font(Helm.sans(12.5, .semibold))
      .foregroundStyle(Helm.fg2)
      .padding(.horizontal, 16)
      .padding(.top, 18)
      .padding(.bottom, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A full-bleed row with a hairline below.
struct Row: View {
  var symbol: String?
  let title: String
  var detail: String?
  var mono: Bool
  var hairline = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(Helm.fg2)
            .frame(width: 22)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(mono ? Helm.mono(13.5, .medium) : Helm.sans(14, .medium))
            .foregroundStyle(Helm.fg)
          if let detail {
            Text(detail)
              .font(Helm.mono(11.5))
              .foregroundStyle(Helm.muted)
          }
        }
        .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 50)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowStyle())
    .overlay(alignment: .bottom) { if hairline { Rectangle().fill(Helm.line).frame(height: 1) } }
  }
}

/// Row press: the Helm `sel` wash.
struct RowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Helm.sel : Color.clear)
  }
}
