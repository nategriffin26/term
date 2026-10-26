import SwiftUI

/// The tmux tab: every tmux session on the saved hosts, one section per
/// host, most recently active first. Tap attaches a tab (or brings forward
/// the one already on it), swipe closes, Select closes many, a long press
/// shows the screen larger.
struct TmuxTab: View {
  let model: MenuModel
  @State private var confirming = false
  @State private var failure: String?
  /// Bumped when the menu closes, so each opening starts at the top with no
  /// row left swiped open.
  @State private var generation = 0

  /// The excerpts' size: the terminal's own font, read at a glance.
  static let excerptPointSize: CGFloat = 11
  private static var excerptFontCache: FontSet?

  var body: some View {
    let store = TmuxStore.shared
    let hosts = TmuxList.servers(ConfigStore.shared.hosts, first: model.tmuxTarget)
    VStack(spacing: 0) {
      if hosts.isEmpty {
        VStack(spacing: 14) {
          Text("No saved hosts")
            .font(Helm.sans(15, .semibold))
            .foregroundStyle(Helm.fg)
          Button("Add Host") { model.tab = .settings }
            .font(Helm.sans(12.5, .medium))
            .foregroundStyle(Helm.fg)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Helm.sel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
            .buttonStyle(PressScale())
        }
        .padding(.top, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
        list(hosts, store: store)
      }
      if model.tmuxSelecting {
        selectBar(store: store)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .task(id: model.isOpen && model.tab == .tmux) {
      guard model.isOpen, model.tab == .tmux else { return }
      await store.watch { TmuxList.servers(ConfigStore.shared.hosts) }
    }
    .onChange(of: model.isOpen) { _, open in
      if !open { generation += 1 }
    }
    .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
      Button("OK", role: .cancel) {}
    }
  }

  private func list(_ hosts: [Host], store: TmuxStore) -> some View {
    let fonts = Self.excerptFonts(family: model.currentTab?.view.fontFamily ?? FontSet.family)
    return List {
      ForEach(hosts) { host in
        let server = store.servers[host.serverKey]
        TmuxHostHead(host: host, server: server)
          .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        ForEach(server?.sessions ?? []) { session in
          row(session, on: host, fonts: fonts, store: store)
        }
        if let server {
          TmuxServerState(host: host, server: server)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
      }
    }
    .id(generation)
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 0)
    .animation(Helm.ease(0.26), value: hosts.map { store.servers[$0.serverKey]?.sessions.map(\.id) ?? [] })
  }

  private func row(_ session: Tmux.Session, on host: Host, fonts: FontSet, store: TmuxStore) -> some View {
    let id = Self.rowID(host, session)
    let mine = model.tabs(on: host, session: session.name)
    let others = TmuxList.others(on: session, term: mine.filter(\.isConnected).count)
    let unread = store.agent(host.serverKey, session.id)?.unread == true
    let open: () -> Void = {
      store.markSeen([session.id], on: host)
      model.space?.attach(host, session: session.name, preview: store.screen(host.serverKey, session.id))
    }
    let close: () -> Void = { self.close([session], on: host) }
    let detach: (() -> Void)? = others > 0 ? { detachOthers(session, on: host, keeping: mine) } : nil
    return Button {
      if model.tmuxSelecting {
        withAnimation(Helm.ease(0.15)) {
          if model.tmuxSelection.contains(id) { model.tmuxSelection.remove(id) } else { model.tmuxSelection.insert(id) }
        }
      } else {
        open()
      }
    } label: {
      TmuxRow(session: session, excerpt: store.excerpt(host.serverKey, session.id), fonts: fonts,
              dot: !mine.isEmpty ? Helm.accent : session.attached > 0 ? Helm.fg2 : nil,
              checked: model.tmuxSelecting ? model.tmuxSelection.contains(id) : nil)
    }
    .buttonStyle(RowStyle())
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listRowSeparatorTint(Helm.line)
    .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Close", role: .destructive, action: close)
        .tint(Helm.bad)
    }
    .contextMenu {
      Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: open)
      if unread {
        Button("Clear Notification", systemImage: "bell.slash") { store.markSeen([session.id], on: host) }
      }
      if let detach {
        Button("Detach Others", systemImage: "rectangle.portrait.and.arrow.right", action: detach)
      }
      Button("Close", systemImage: "xmark", role: .destructive, action: close)
    } preview: {
      TmuxPreview(model: model, host: host, session: session)
    }
    .accessibilityLabel("\(session.name), \(host.alias)")
    .accessibilityAddTraits(model.tmuxSelecting && model.tmuxSelection.contains(id) ? .isSelected : [])
  }

  private func selectBar(store: TmuxStore) -> some View {
    let picked = selected(store)
    let count = picked.reduce(0) { $0 + $1.1.count }
    let unread = picked.reduce(0) { total, pick in total + pick.1.count { store.agent(pick.0.serverKey, $0.id)?.unread == true } }
    return VStack(spacing: 0) {
      Rectangle().fill(Helm.line).frame(height: 1)
      HStack(spacing: 0) {
        if store.unreadCount > 0 {
          Button(unread > 0 ? "Clear \(unread)" : "Clear") { clearSelected(store) }
            .font(Helm.sans(14, .medium))
            .foregroundStyle(Helm.fg)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
            .buttonStyle(PressScale())
            .disabled(unread == 0)
            .opacity(unread == 0 ? 0.4 : 1)
          Rectangle().fill(Helm.line).frame(width: 1, height: 24)
        }
        Button(count > 0 ? "Close \(count)" : "Close") { confirming = true }
          .font(Helm.sans(14, .medium))
          .foregroundStyle(Helm.bad)
          .frame(maxWidth: .infinity)
          .frame(height: 50)
          .contentShape(Rectangle())
          .buttonStyle(PressScale())
          .disabled(count == 0)
          .opacity(count == 0 ? 0.4 : 1)
          .confirmationDialog(count == 1 ? "Close 1 tmux session?" : "Close \(count) tmux sessions?",
                              isPresented: $confirming, titleVisibility: .visible) {
            Button("Close \(count)", role: .destructive) { closeSelected(store) }
            Button("Cancel", role: .cancel) {}
          }
      }
    }
  }

  /// The checked sessions still listed, with their hosts.
  private func selected(_ store: TmuxStore) -> [(Host, [Tmux.Session])] {
    TmuxList.servers(ConfigStore.shared.hosts).compactMap { host in
      let picked = (store.servers[host.serverKey]?.sessions ?? []).filter { model.tmuxSelection.contains(Self.rowID(host, $0)) }
      return picked.isEmpty ? nil : (host, picked)
    }
  }

  private func closeSelected(_ store: TmuxStore) {
    let picked = selected(store)
    withAnimation(Helm.spring(0.4)) { model.tmuxSelecting = false }
    for (host, sessions) in picked { close(sessions, on: host) }
  }

  private func clearSelected(_ store: TmuxStore) {
    let picked = selected(store)
    withAnimation(Helm.spring(0.4)) { model.tmuxSelecting = false }
    for (host, sessions) in picked { store.markSeen(sessions.map(\.id), on: host) }
  }

  private func close(_ sessions: [Tmux.Session], on host: Host) {
    Task {
      if let error = await TmuxStore.shared.close(sessions, on: host) { failure = error }
    }
  }

  /// Term's own clients on the session stay: they are told apart by size.
  private func detachOthers(_ session: Tmux.Session, on host: Host, keeping tabs: [Tab]) {
    let keep = Set(tabs.filter(\.isConnected).map { "\($0.current.cols)x\($0.current.rows)" })
    Task {
      if let error = await TmuxStore.shared.detachOthers(session, keep: keep, on: host) { failure = error }
    }
  }

  static func rowID(_ host: Host, _ session: Tmux.Session) -> String {
    host.serverKey + "\t" + session.id
  }

  private static func excerptFonts(family: String) -> FontSet {
    if let cached = excerptFontCache, cached.family == family { return cached }
    let fonts = FontSet(family: family, pointSize: excerptPointSize, scale: 1)
    excerptFontCache = fonts
    return fonts
  }
}

/// One session: its name, what runs where, how long since it last changed,
/// and the last lines of its screen.
private struct TmuxRow: View {
  let session: Tmux.Session
  let excerpt: ScreenExcerpt?
  let fonts: FontSet
  /// Accent: a Term tab is on it; fg-2: another client is.
  let dot: Color?
  /// Select mode's checkbox; nil outside it.
  let checked: Bool?

  var body: some View {
    HStack(spacing: 12) {
      if let checked {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 20, weight: .light))
          .foregroundStyle(checked ? Helm.accent : Helm.faint)
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(session.name)
            .font(Helm.mono(13.5, .medium))
            .foregroundStyle(Helm.fg)
            .layoutPriority(1)
          if let dot {
            Circle().fill(dot).frame(width: 7, height: 7)
              .accessibilityLabel(dot == Helm.accent ? "open in Term" : "attached")
          }
          ViewThatFits(in: .horizontal) {
            ForEach(TmuxList.details(session), id: \.self) { Text($0) }
            Color.clear.frame(width: 0, height: 0)
          }
          .font(Helm.mono(11.5))
          .foregroundStyle(Helm.muted)
          .padding(.leading, 4)
          Spacer(minLength: 8)
          TimelineView(.everyMinute) { context in
            Text(TmuxList.age(session.lastActivity, now: context.date))
              .font(Helm.mono(11.5))
              .foregroundStyle(Helm.muted)
          }
          .fixedSize()
        }
        .lineLimit(1)
        ExcerptLines(excerpt: excerpt, fonts: fonts)
      }
    }
    .opacity(TmuxList.isIdle(session, now: .now) ? 0.5 : 1)
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// A session's last lines in the terminal's font and colours, each cut at
/// the row's edge. Always as tall as its lines, so a row keeps its height
/// before its first capture lands.
private struct ExcerptLines: View {
  let excerpt: ScreenExcerpt?
  let fonts: FontSet

  var body: some View {
    let height = CGFloat(fonts.metrics.height)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(0..<ScreenExcerpt.lineCount, id: \.self) { i in
        Text(line(i))
          .lineLimit(1)
          .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
      }
    }
    .accessibilityHidden(true)
  }

  private func line(_ i: Int) -> AttributedString {
    guard let lines = excerpt?.lines, i < lines.count else { return AttributedString() }
    return lines[i].reduce(into: AttributedString()) { out, run in
      var part = AttributedString(run.text)
      let color = run.fg.map { Color(uiColor: UIColor(argb: $0 | 0xFF00_0000)) } ?? Helm.fg2
      part.foregroundColor = run.faint ? color.opacity(0.55) : color
      if let bg = run.bg { part.backgroundColor = Color(uiColor: UIColor(argb: bg | 0xFF00_0000)) }
      part.font = Font(fonts.face(run.bold ? 1 : 0))
      out += part
    }
  }
}

/// A host's name over its sessions, with their count once listed.
private struct TmuxHostHead: View {
  let host: Host
  let server: TmuxStore.Server?

  var body: some View {
    HStack(spacing: 8) {
      Text(host.alias)
        .font(Helm.mono(12.5, .semibold))
        .foregroundStyle(Helm.fg2)
      if let count = server?.sessions.count, count > 0 {
        Text("\(count)")
          .font(Helm.mono(12))
          .foregroundStyle(Helm.muted)
      }
      if server == nil || server?.status == .loading {
        ProgressView().controlSize(.mini).tint(Helm.muted)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 10)
    .frame(height: 40, alignment: .bottom)
    .padding(.bottom, 6)
  }
}

/// Why a host lists no sessions, in a few words.
private struct TmuxServerState: View {
  let host: Host
  let server: TmuxStore.Server

  var body: some View {
    switch server.status {
    case .loading:
      EmptyView()
    case .ready:
      if server.sessions.isEmpty { line("No tmux sessions") }
    case .notRunning:
      line("tmux not running")
    case .notInstalled:
      line("tmux not installed")
    case .failed(let text):
      line(text.isEmpty ? "tmux failed" : Tmux.readableError(text))
    case .unreachable(let message):
      // The reason on its own line: cut beside the word, its useful end
      // ("Connection refused") was lost on a phone.
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Unreachable")
            .font(Helm.sans(13.5))
            .foregroundStyle(Helm.fg2)
          Text(message)
            .font(Helm.mono(11.5))
            .foregroundStyle(Helm.muted)
            .lineLimit(2)
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
      .padding(.vertical, 6)
      .frame(minHeight: 44)
    }
  }

  private func line(_ text: String) -> some View {
    Text(text)
      .font(Helm.sans(13.5))
      .foregroundStyle(Helm.fg2)
      .lineLimit(2)
      .frame(minHeight: 44)
  }
}

/// The long press's preview: the session's screen at a readable size.
private struct TmuxPreview: View {
  let model: MenuModel
  let host: Host
  let session: Tmux.Session
  @Environment(\.displayScale) private var displayScale

  static let width: CGFloat = 340
  static let inset: CGFloat = 8

  var body: some View {
    let serverKey = host.serverKey, id = session.id
    let fonts = model.tmuxPreviews.fonts(cellWidth: cellWidth, scale: displayScale,
                                         family: model.currentTab?.view.fontFamily ?? FontSet.family, minimum: 2)
    let cell = fonts.metrics
    let width = CGFloat(max(session.width, 1) * cell.width) / displayScale + 2 * Self.inset
    let height = CGFloat(max(session.height, 1) * cell.height) / displayScale + 2 * Self.inset
    ThumbnailView(source: { TmuxStore.shared.engine(serverKey, id) }, renderer: model.tmuxPreviews, fonts: fonts,
                  inset: Self.inset)
      .frame(width: width, height: min(height, width * 1.6))
      .background(Color.black)
  }

  private var cellWidth: Int {
    Int(((Self.width - 2 * Self.inset) * displayScale / CGFloat(max(session.width, 1))).rounded(.down))
  }
}
