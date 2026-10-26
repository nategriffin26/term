import SwiftUI
import UIKit

/// The Sessions tab: every open tab and every tmux session on their hosts,
/// grouped by host, and the pages for starting a new one.
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
      case .newTmux(let host):
        NewTmuxPage(model: model, host: host)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(Helm.spring(0.4), value: model.sessionsPage)
  }
}

// MARK: - Overview

/// Mission Control for terminals: a grid per host of live thumbnails for
/// open tabs and snapshots for the host's other tmux sessions. Tap goes into
/// a session; long press manages it.
struct SessionsOverview: View {
  let model: MenuModel
  @Environment(\.displayScale) private var displayScale
  @State private var renaming: Target?
  @State private var newName = ""
  @State private var killing: Target?
  @State private var failure: String?
  /// The group kept at the top while it loads and lays out.
  @State private var reveal: String?

  /// A tmux session an action is about.
  struct Target: Identifiable {
    var host: Host
    var session: Tmux.Session
    var id: String { host.serverKey + "\t" + session.id }
  }

  private static let padding: CGFloat = 16
  private static let spacing: CGFloat = 12
  private static let rowSpacing: CGFloat = 16
  private static let groupHead: CGFloat = 34
  private static let topID = "top"

  var body: some View {
    let store = TmuxStore.shared
    GeometryReader { geo in
      let groups = model.hostGroups
      let current = model.currentTab
      let aspect = model.aspect
      let showHeads = groups.count > 1
      let tiles = groups.reduce(0) { $0 + ($1.collapsed ? 0 : $1.items.count + ($1.host == nil ? 1 : 0)) }
      let heads = showHeads ? CGFloat(groups.count) * Self.groupHead : 0
      let area = CGSize(width: geo.size.width - 2 * Self.padding,
                        height: geo.size.height - 2 * Self.padding - heads - CGFloat(groups.count - 1) * 18)
      let grid = MenuLayout.overviewGrid(count: tiles, area: area, aspect: aspect, spacing: Self.spacing,
                                         rowSpacing: Self.rowSpacing)
      let tileSize = CGSize(width: grid.tileWidth, height: (grid.tileWidth / aspect).rounded())
      let fonts = thumbnailFonts(groups: groups, tileWidth: grid.tileWidth, family: current?.view.fontFamily)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
              VStack(alignment: .leading, spacing: 6) {
                if showHeads {
                  HostHead(group: group, server: group.host.flatMap { store.servers[$0.serverKey] }, model: model) {
                    reveal = group.id
                    withAnimation(Helm.spring(0.45)) { proxy.scrollTo(group.id, anchor: .top) }
                  }
                }
                if !group.collapsed {
                  LazyVGrid(columns: Array(repeating: GridItem(.fixed(grid.tileWidth), spacing: Self.spacing, alignment: .top),
                                           count: grid.columns),
                            alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(group.items) { item in
                      tile(item, in: group, current: current, size: tileSize, fonts: fonts)
                    }
                    if group.host == nil {
                      NewTile(size: tileSize) { model.sessionsPage = .new }
                    }
                  }
                  if let host = group.host, let server = store.servers[host.serverKey] {
                    ServerState(host: host, server: server, hasTiles: !group.items.isEmpty)
                  }
                }
              }
              .id(group.id)
            }
          }
          .padding(.horizontal, Self.padding)
          // A host head sits close under the tab bar, as its own top margin.
          .padding(.top, showHeads ? 6 : Self.padding)
          .padding(.bottom, Self.padding)
          // Mission Control: a lone grid that fits sits in the middle of the
          // panel; host groups read from the top.
          .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: showHeads ? .top : .center)
          .animation(Helm.spring(0.35), value: groups)
          .id(Self.topID)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // Each opening starts at the top, where the current tab's group is
        // (the terminal shrinks into its tile there), or at the host `tmux
        // host` asked for; closing forgets that host.
        .onChange(of: model.isOpen ? model.scrollTarget ?? Self.topID : nil, initial: true) { _, target in
          reveal = target
          if let target { proxy.scrollTo(target, anchor: .top) } else { model.scrollTarget = nil }
        }
        // A host's sessions arrive after it opens, and the keyboard resizes
        // the tiles: the group asked for stays at the top through both,
        // until he scrolls himself.
        .onScrollGeometryChange(for: CGSize.self, of: { CGSize(width: $0.containerSize.height, height: $0.contentSize.height) }) { _, _ in
          if let reveal { proxy.scrollTo(reveal, anchor: .top) }
        }
        .onScrollPhaseChange { _, phase in
          if phase == .interacting { reveal = nil }
        }
      }
    }
    .task(id: model.isOpen && model.tab == .sessions) {
      guard model.isOpen, model.tab == .sessions else { return }
      await store.watch { model.hostGroups.filter { !$0.collapsed }.compactMap(\.host) }
    }
    .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { target in
      TextField("name", text: $newName)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Rename") { rename(target) }
      Button("Cancel", role: .cancel) {}
    }
    .alert(killing.map { "Kill \($0.session.name)?" } ?? "",
           isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }), presenting: killing) { target in
      Button("Kill", role: .destructive) { kill(target) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Its windows and the programs in them end.")
    }
    .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
      Button("OK", role: .cancel) {}
    }
  }

  @ViewBuilder
  private func tile(_ item: SessionMap.Item, in group: SessionMap.Group, current: Tab?, size: CGSize, fonts: FontSet?) -> some View {
    switch item {
    case .tab(let id, let session, let others):
      if let (owner, tab) = model.space(of: id) {
        TabTile(model: model, owner: owner, tab: tab, session: session, others: others, isCurrent: tab === current,
                size: size, fonts: fonts, actions: actions(group.host, session: session, tab: tab))
      }
    case .session(let session, let others):
      if let host = group.host {
        SnapshotTile(model: model, host: host, session: session, others: others, size: size, fonts: fonts,
                     actions: actions(host, session: session, tab: nil))
      }
    }
  }

  private func actions(_ host: Host?, session: Tmux.Session?, tab: Tab?) -> TileActions {
    guard let host, let session else { return TileActions() }
    let target = Target(host: host, session: session)
    return TileActions(
      rename: { newName = session.name; renaming = target },
      kill: { killing = target },
      detachOthers: { detachOthers(target) })
  }

  private func rename(_ target: Target) {
    let name = Tmux.cleanName(newName)
    guard !name.isEmpty, name != target.session.name else { return }
    Task {
      if let error = await TmuxStore.shared.rename(target.session, to: name, on: target.host) {
        failure = error
      } else {
        SpaceController.tmuxSessionRenamed(on: target.host, from: target.session.name, to: name)
      }
    }
  }

  private func kill(_ target: Target) {
    Task {
      if let error = await TmuxStore.shared.kill(target.session, on: target.host) {
        failure = error
      } else {
        SpaceController.tmuxSessionKilled(on: target.host, name: target.session.name)
      }
    }
  }

  /// Term's own clients on the session stay: they are told apart by size.
  private func detachOthers(_ target: Target) {
    let keep = Set(model.tabs.filter {
      $0.isConnected && $0.target?.serverKey == target.host.serverKey && $0.tmuxSession == target.session.name
    }.map { "\($0.current.cols)x\($0.current.rows)" })
    Task {
      if let error = await TmuxStore.shared.detachOthers(target.session, keep: keep, on: target.host) { failure = error }
    }
  }

  /// One font for all thumbnails: the widest session fits its tile, down to
  /// a legible size.
  private func thumbnailFonts(groups: [SessionMap.Group], tileWidth: CGFloat, family: String?) -> FontSet? {
    let widths = groups.filter { !$0.collapsed }.flatMap(\.items).compactMap { item -> Int? in
      switch item {
      case .tab(let id, _, _): model.space(of: id)?.1.current.cols
      case .session(let session, _): session.width
      }
    }
    let widest = widths.max() ?? 80
    guard tileWidth > 0, widest > 0 else { return nil }
    let width = tileWidth - 2 * SessionThumbnailView.inset
    let cell = Int((width * displayScale / CGFloat(widest)).rounded(.down))
    return model.thumbnails.fonts(cellWidth: cell, scale: displayScale, family: family ?? FontSet.family)
  }
}

/// What a tile's long press offers for its tmux session.
struct TileActions {
  var rename: (() -> Void)?
  var kill: (() -> Void)?
  var detachOthers: (() -> Void)?
}

/// A host's name over its sessions: its session count, + for a new tmux
/// session there; a host without open tabs opens and closes from here.
private struct HostHead: View {
  let group: SessionMap.Group
  let server: TmuxStore.Server?
  let model: MenuModel
  /// Scrolls the group up into view once it has opened.
  var reveal: () -> Void = {}

  var body: some View {
    HStack(spacing: 8) {
      if let host = group.host {
        let hasTabs = group.items.contains { if case .tab = $0 { true } else { false } }
        Button {
          let store = TmuxStore.shared
          store.setExpanded(host.serverKey, group.collapsed)
          if group.collapsed {
            store.refresh(host)
            reveal()
          }
        } label: {
          HStack(spacing: 8) {
            Text(host.alias)
              .font(Helm.mono(12.5, .semibold))
              .foregroundStyle(Helm.fg2)
            if !group.collapsed, server?.status == .ready, let count = server?.sessions.count, count > 0 {
              Text("\(count)")
                .font(Helm.mono(12))
                .foregroundStyle(Helm.muted)
            }
            if !group.collapsed, server?.status == .loading {
              ProgressView().controlSize(.mini).tint(Helm.muted)
            }
            if !hasTabs {
              Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Helm.faint)
            }
          }
          .frame(height: 34)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hasTabs)
        .accessibilityLabel(host.alias)
        Spacer(minLength: 0)
        if !group.collapsed, server.map({ $0.status != .notInstalled && !$0.isUnreachable }) ?? true {
          Button {
            model.sessionsPage = .newTmux(host)
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(Helm.fg2)
              .frame(width: 44, height: 34)
              .contentShape(Rectangle())
          }
          .buttonStyle(PressScale(0.9))
          // Under the panel's close button.
          .padding(.trailing, -14)
          .accessibilityLabel("New tmux session on \(host.alias)")
        }
      } else {
        Text("This phone")
          .font(Helm.sans(12.5, .semibold))
          .foregroundStyle(Helm.fg2)
          .frame(height: 34)
        Spacer(minLength: 0)
      }
    }
    .frame(height: 34)
  }
}

/// Why a host shows no sessions, in a few words.
private struct ServerState: View {
  let host: Host
  let server: TmuxStore.Server
  let hasTiles: Bool

  var body: some View {
    switch server.status {
    case .loading:
      EmptyView()
    case .ready:
      if server.sessions.isEmpty, !hasTiles { line("No sessions") }
    case .notRunning:
      if !hasTiles { line("tmux not running") }
    case .notInstalled:
      line("tmux not installed")
    case .failed(let text):
      line(text.isEmpty ? "tmux failed" : text)
    case .unreachable(let message):
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Unreachable")
            .font(Helm.sans(13.5))
            .foregroundStyle(Helm.fg2)
          Text(message)
            .font(Helm.mono(11.5))
            .foregroundStyle(Helm.muted)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Spacer(minLength: 0)
        Button("Retry") { TmuxStore.shared.refresh(host) }
          .font(Helm.sans(12.5, .medium))
          .foregroundStyle(Helm.fg)
          .padding(.horizontal, 12)
          .frame(height: 28)
          .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Helm.sel))
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
          .buttonStyle(PressScale())
      }
    }
  }

  private func line(_ text: String) -> some View {
    Text(text)
      .font(Helm.sans(13.5))
      .foregroundStyle(Helm.fg2)
      .lineLimit(2)
  }
}

/// The line under a tile: name, then what runs where, with a dot for an
/// open tab and a ring for clients elsewhere.
private struct TileLabel: View {
  let name: String
  /// What runs where, longest first: the longest that fits shows.
  let details: [String]
  let isCurrent: Bool
  var dot: Color?
  /// Other clients on the session (the Mac, another phone).
  var others = 0
  var age: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(name)
          .font(Helm.mono(12.5, .medium))
          .foregroundStyle(isCurrent ? Helm.fg : Helm.fg2)
        Spacer(minLength: 0)
        if let age {
          Text(age)
            .font(Helm.mono(11))
            .foregroundStyle(Helm.muted)
        }
      }
      HStack(spacing: 5) {
        if let dot, !details.isEmpty { Circle().fill(dot).frame(width: 6, height: 6) }
        if others > 0 {
          Circle().strokeBorder(Helm.muted, lineWidth: 1.25).frame(width: 7, height: 7)
            .accessibilityLabel(others == 1 ? "attached elsewhere" : "attached \(others) times elsewhere")
        }
        ViewThatFits(in: .horizontal) {
          ForEach(details, id: \.self) { Text($0) }
        }
        .font(Helm.mono(11))
        .foregroundStyle(Helm.muted)
        // Keeps the row's height for a tab with nothing to say here.
        if details.isEmpty { Text(" ").font(Helm.mono(11)) }
      }
    }
    .lineLimit(1)
  }
}

/// An open tab: its live thumbnail. Tap zooms into it; ✕ closes the tab (a
/// tmux session stays on its host and turns into a snapshot).
private struct TabTile: View {
  let model: MenuModel
  /// The window the tab is in; tapping and History go through the window
  /// showing the overview, which brings another window's tab forward.
  let owner: SpaceController
  let tab: Tab
  let session: Tmux.Session?
  let others: Int
  let isCurrent: Bool
  let size: CGSize
  let fonts: FontSet?
  let actions: TileActions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        ThumbnailView(source: { [weak tab] in tab?.current }, renderer: model.thumbnails, fonts: fonts)
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
        TileLabel(name: tab.sessionName, details: session.map(SessionMap.details) ?? tab.hostName.map { [$0] } ?? [],
                  isCurrent: isCurrent, dot: Self.dot(for: tab, isCurrent: isCurrent), others: others)
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
      if let rename = actions.rename {
        Button("Rename", systemImage: "pencil", action: rename)
      }
      if tab.isConnected {
        Button("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") { model.space?.showHistory(for: tab) }
      }
      if others > 0, let detach = actions.detachOthers {
        Button("Detach Others", systemImage: "rectangle.portrait.and.arrow.right", action: detach)
      }
      Button("Close Tab", systemImage: "xmark") { owner.close(tab) }
      if let kill = actions.kill {
        Button("Kill Session", systemImage: "trash", role: .destructive, action: kill)
      }
    }
  }

  /// An open tab's dot: out of contact (amber), else the current tab (accent)
  /// or another open one (fg-2).
  static func dot(for tab: Tab, isCurrent: Bool) -> Color {
    if tab.unreachable { return Helm.warn }
    return isCurrent || tab.connecting != nil ? Helm.accent : Helm.fg2
  }
}

/// A tmux session no tab is attached to: the last capture of its screen,
/// quieter than the live tiles. Tap attaches a tab that grows out of it.
private struct SnapshotTile: View {
  let model: MenuModel
  let host: Host
  let session: Tmux.Session
  let others: Int
  let size: CGSize
  let fonts: FontSet?
  let actions: TileActions

  private var key: String { host.serverKey + "\t" + session.id }

  var body: some View {
    let serverKey = host.serverKey, id = session.id
    VStack(alignment: .leading, spacing: 8) {
      ThumbnailView(source: { TmuxStore.shared.engine(serverKey, id) }, renderer: model.thumbnails, fonts: fonts)
        .frame(width: size.width, height: size.height)
        .opacity(0.55)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Helm.line, lineWidth: 1)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          model.snapshotFrames[key] = frame
        }
      TileLabel(name: session.name, details: SessionMap.details(session), isCurrent: false, others: others,
                age: SessionMap.age(session.lastActivity, now: .now))
        .frame(width: size.width, height: 36, alignment: .leading)
    }
    .contentShape(Rectangle())
    .onTapGesture { open() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(session.name), \(host.alias)")
    .accessibilityAddTraits(.isButton)
    .contextMenu {
      Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: open)
      if let rename = actions.rename {
        Button("Rename", systemImage: "pencil", action: rename)
      }
      Button("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
        model.space?.showHistory(host: host, session: session.name)
      }
      if others > 0, let detach = actions.detachOthers {
        Button("Detach Others", systemImage: "rectangle.portrait.and.arrow.right", action: detach)
      }
      if let kill = actions.kill {
        Button("Kill Session", systemImage: "trash", role: .destructive, action: kill)
      }
    }
  }

  private func open() {
    model.space?.attach(host, session: session.name, tile: model.snapshotFrames[key])
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
private struct ThumbnailView: UIViewRepresentable {
  let source: @MainActor () -> Session?
  let renderer: ThumbnailRenderer
  let fonts: FontSet?

  func makeUIView(context: Context) -> SessionThumbnailView {
    let view = SessionThumbnailView(source: source)
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

/// A host's + : a tmux session with a name, started in a folder, then attached.
private struct NewTmuxPage: View {
  let model: MenuModel
  let host: Host
  @State private var name = ""
  @State private var folder = ""
  @State private var busy = false
  @State private var error: String?
  @FocusState private var naming: Bool

  var body: some View {
    let folders = SessionMap.folders(TmuxStore.shared.servers[host.serverKey]?.sessions ?? [])
    PageScaffold(title: "New on \(host.alias)", back: { model.sessionsPage = .grid }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          field("Name", text: $name, prompt: "name")
            .focused($naming)
          field("Folder", text: $folder, prompt: "~")
          if let error {
            Text(error)
              .font(Helm.sans(13))
              .foregroundStyle(Helm.bad)
              .padding(.horizontal, 16)
              .padding(.top, 10)
          }
          Button(action: create) {
            ZStack {
              Text("Open").opacity(busy ? 0 : 1)
              if busy { ProgressView().controlSize(.small).tint(Helm.onAccent) }
            }
            .font(Helm.sans(14, .semibold))
            .foregroundStyle(Helm.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Helm.accent))
            .contentShape(Rectangle())
          }
          .buttonStyle(PressScale())
          .disabled(busy)
          .padding(16)
          if !folders.isEmpty {
            GroupHead("Recent")
            ForEach(folders, id: \.self) { path in
              Row(title: path, mono: true) { folder = path }
            }
          }
        }
      }
      .scrollIndicators(.hidden)
    }
    .onAppear { naming = true }
  }

  private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(Helm.sans(12.5, .medium))
        .foregroundStyle(Helm.muted)
      TextField("", text: text, prompt: Text(prompt).foregroundStyle(Helm.muted))
        .font(Helm.mono(16))
        .foregroundStyle(Helm.fg)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit(create)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Helm.bg.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }

  private func create() {
    guard !busy else { return }
    busy = true
    error = nil
    Task {
      let result = await TmuxStore.shared.create(name: name, folder: folder, on: host)
      busy = false
      switch result {
      case .success(let created):
        model.space?.attach(host, session: created)
      case .failure(let failure):
        error = failure.message
      }
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
