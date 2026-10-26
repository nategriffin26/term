import SwiftUI

/// The tmux tab: every tmux session on the saved hosts, one section per
/// host, most recently active first, one line each. Tap attaches a tab (or
/// brings forward the one already on it), swipe closes or clears, Select
/// clears or closes many, a long press shows the agent's answer or question
/// in full, or the screen.
struct TmuxTab: View {
  let model: MenuModel
  @State private var confirming = false
  @State private var failure: String?
  /// Bumped when the menu closes, so each opening starts at the top with no
  /// row left swiped open.
  @State private var generation = 0

  /// The session names' type, and one character's width in it.
  static let nameStep = Chrome.TextStep.body
  private static var nameCharWidth: CGFloat {
    ("M" as NSString).size(withAttributes: [.font: Chrome.uiMono(nameStep, .medium)]).width
  }

  var body: some View {
    let store = TmuxStore.shared
    let hosts = store.shownHosts(first: model.tmuxTarget)
    VStack(spacing: 0) {
      if hosts.isEmpty {
        VStack(spacing: Chrome.Space.m) {
          Text("No saved hosts")
            .font(Chrome.font(.body, .semibold))
            .foregroundStyle(Chrome.fg)
          Button("Add Host") { model.tab = .settings }
            .buttonStyle(CapsuleButtonStyle())
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
      await store.watch { ConfigStore.shared.hosts }
    }
    .onChange(of: model.isOpen) { _, open in
      if !open { generation += 1 }
    }
    .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
      Button("OK", role: .cancel) {}
    }
  }

  private func list(_ hosts: [Host], store: TmuxStore) -> some View {
    let names = hosts.flatMap { store.servers[$0.serverKey]?.sessions.map(\.name) ?? [] }
    let nameWidth = (CGFloat(TmuxList.nameColumn(names)) * Self.nameCharWidth).rounded(.up)
    return List {
      ForEach(hosts) { host in
        let server = store.servers[host.serverKey]
        let sessions = server?.sessions ?? []
        let stateRow = server.map(TmuxServerState.shows) ?? false
        Section {
          ForEach(sessions) { session in
            row(session, on: host, nameWidth: nameWidth, store: store,
                ends: GroupEnds(top: session.id == sessions.first?.id, bottom: !stateRow && session.id == sessions.last?.id))
          }
          if let server, stateRow {
            TmuxServerState(host: host, server: server)
              .listRowInsets(EdgeInsets(top: 0, leading: Chrome.Space.l, bottom: 0, trailing: Chrome.Space.l))
              .listRowBackground(GroupEnds(top: sessions.isEmpty, bottom: true).shape.fill(Chrome.fill))
          }
        } header: {
          TmuxHostHead(host: host, server: server)
            .listRowInsets(EdgeInsets(top: 0, leading: Chrome.Space.l, bottom: Chrome.Space.s, trailing: Chrome.Space.l))
        }
        // With no side margins the list draws square section lines across the rounded group.
        .listSectionSeparator(.hidden)
      }
    }
    .id(generation)
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .contentMargins(.horizontal, 0, for: .scrollContent)
    .contentMargins(.top, Chrome.Space.s, for: .scrollContent)
    .listSectionSpacing(Chrome.Space.s)
    .environment(\.defaultMinListRowHeight, 0)
    .animation(Chrome.fade, value: hosts.map { store.servers[$0.serverKey]?.sessions.map(\.id) ?? [] })
    // The groups' edges are the list's: a row swiped open slides its text
    // past the group's leading edge, and the list's bounds cut it there. With
    // no side margins the list draws square groups, so the rows round the ends.
    .clipped()
    .padding(.horizontal, Chrome.Space.m)
  }

  private func row(_ session: Tmux.Session, on host: Host, nameWidth: CGFloat, store: TmuxStore, ends: GroupEnds) -> some View {
    let id = Self.rowID(host, session)
    let mine = model.tabs(on: host, session: session.name)
    let others = TmuxList.others(on: session, term: mine.filter(\.isConnected).count)
    let agent = store.agent(host.serverKey, session.id)
    let unread = agent?.unread == true
    let clear: () -> Void = { store.markSeen([session.id], on: host) }
    let open: () -> Void = {
      store.markSeen([session.id], on: host)
      model.space?.attach(host, session: session.name, preview: store.screen(host.serverKey, session.id))
    }
    let close: () -> Void = { self.close([session], on: host) }
    let detach: (() -> Void)? = others > 0 ? { detachOthers(session, on: host, keeping: mine) } : nil
    return Button {
      if model.tmuxSelecting {
        withAnimation(Chrome.quick) {
          if model.tmuxSelection.contains(id) { model.tmuxSelection.remove(id) } else { model.tmuxSelection.insert(id) }
        }
      } else {
        open()
      }
    } label: {
      TmuxRow(session: session, agent: agent, nameWidth: nameWidth,
              dot: !mine.isEmpty ? .term : session.attached > 0 ? .elsewhere : nil,
              checked: model.tmuxSelecting ? model.tmuxSelection.contains(id) : nil)
    }
    .buttonStyle(RowStyle())
    .clipShape(ends.shape)
    .listRowInsets(EdgeInsets())
    .listRowBackground(ends.shape.fill(Chrome.fill))
    .listRowSeparatorTint(Chrome.line)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Close", role: .destructive) { Haptics.firm(); close() }
        .tint(Chrome.swipeBad)
      if unread {
        Button("Clear") { Haptics.firm(); clear() }
          .tint(Chrome.swipeAccent)
      }
    }
    .contextMenu {
      Button("Open", systemImage: "arrow.up.right.square", action: open)
      if unread {
        Button("Clear Notification", systemImage: "bell.slash", action: clear)
      }
      if let detach {
        Button("Detach Others", systemImage: "rectangle.portrait.and.arrow.right", action: detach)
      }
      Button("Close", systemImage: "xmark", role: .destructive, action: close)
    } preview: {
      if let agent, !agent.fromTitle {
        TmuxAgentPreview(session: session, agent: agent)
      } else {
        TmuxPreview(model: model, host: host, session: session)
      }
    }
    // The menu's icons take the tint: the system menu's text colour, not the accent.
    .tint(.primary)
    .accessibilityLabel("\(session.name), \(host.alias)")
    .accessibilityValue([agent?.title ?? session.command, agent.flatMap { TmuxList.stateWord($0.state) }, TmuxList.note(agent)]
      .compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(model.tmuxSelecting && model.tmuxSelection.contains(id) ? .isSelected : [])
  }

  private func selectBar(store: TmuxStore) -> some View {
    let picked = selected(store)
    let count = picked.reduce(0) { $0 + $1.1.count }
    let unread = picked.reduce(0) { total, pick in total + pick.1.count { store.agent(pick.0.serverKey, $0.id)?.unread == true } }
    return HStack(spacing: Chrome.Space.m) {
      if store.unreadCount > 0 {
        Button { clearSelected(store) } label: {
          Text(unread > 0 ? "Clear \(unread)" : "Clear").frame(maxWidth: .infinity)
        }
        .buttonStyle(CapsuleButtonStyle())
        .disabled(unread == 0)
        .opacity(unread == 0 ? 0.4 : 1)
      }
      Button { confirming = true } label: {
        Text(count > 0 ? "Close \(count)" : "Close").frame(maxWidth: .infinity)
      }
      .buttonStyle(CapsuleButtonStyle(kind: .destructive))
      .disabled(count == 0)
      .opacity(count == 0 ? 0.4 : 1)
      .confirmationDialog(count == 1 ? "Close 1 tmux session?" : "Close \(count) tmux sessions?",
                          isPresented: $confirming, titleVisibility: .visible) {
        Button("Close \(count)", role: .destructive) { closeSelected(store) }
        Button("Cancel", role: .cancel) {}
      }
    }
    .padding(Chrome.Space.m)
  }

  /// Every listed session's row id: what Select's All checks.
  static func rowIDs(_ store: TmuxStore) -> Set<String> {
    Set(store.shownHosts().flatMap { host in
      (store.servers[host.serverKey]?.sessions ?? []).map { rowID(host, $0) }
    })
  }

  /// The checked sessions still listed, with their hosts.
  private func selected(_ store: TmuxStore) -> [(Host, [Tmux.Session])] {
    store.shownHosts().compactMap { host in
      let picked = (store.servers[host.serverKey]?.sessions ?? []).filter { model.tmuxSelection.contains(Self.rowID(host, $0)) }
      return picked.isEmpty ? nil : (host, picked)
    }
  }

  private func closeSelected(_ store: TmuxStore) {
    let picked = selected(store)
    withAnimation(Chrome.spring) { model.tmuxSelecting = false }
    for (host, sessions) in picked { close(sessions, on: host) }
  }

  private func clearSelected(_ store: TmuxStore) {
    let picked = selected(store)
    withAnimation(Chrome.spring) { model.tmuxSelecting = false }
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
}

/// Which ends of a group a row sits at: those corners take the group radius.
private struct GroupEnds {
  let top: Bool
  let bottom: Bool

  var shape: UnevenRoundedRectangle {
    let top = top ? Chrome.Radius.group : 0, bottom = bottom ? Chrome.Radius.group : 0
    return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                  bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
  }
}

/// One session on one line: its name, the agent's title or what runs where,
/// and at the right edge the agent's progress or state, or the age of the
/// last output. A stop he hasn't seen adds the question or the answer below.
private struct TmuxRow: View {
  enum Dot { case term, elsewhere }

  let session: Tmux.Session
  let agent: AgentInfo?
  let nameWidth: CGFloat
  /// A Term tab is on it (filled), or another client is (ring).
  let dot: Dot?
  /// Select mode's checkbox; nil outside it.
  let checked: Bool?

  /// The first line's height: with the padding, a row is 50 tall at Text Size Default.
  private static var lineHeight: CGFloat { Chrome.TextStep.body.size(in: AppSettings.shared.textSize) + 5 }

  var body: some View {
    let note = TmuxList.note(agent)
    HStack(alignment: .top, spacing: Chrome.Space.s) {
      if let checked {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
          .font(Chrome.symbol(.control))
          .foregroundStyle(checked ? Chrome.fg : Chrome.muted)
          .frame(height: Self.lineHeight)
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      dotView
        .frame(width: Chrome.Space.m, height: Self.lineHeight)
      Text(session.name)
        .font(Chrome.mono(TmuxTab.nameStep, .medium))
        .foregroundStyle(Chrome.fg)
        .truncationMode(.tail)
        .frame(width: nameWidth, height: Self.lineHeight, alignment: .leading)
        // Rows are split from the names' leading edge.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .padding(.trailing, Chrome.Space.xs)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Chrome.Space.s) {
          title
          Spacer(minLength: 0)
          TimelineView(.everyMinute) { context in
            TmuxStatusView(status: TmuxList.status(agent, session, now: context.date))
          }
          .fixedSize()
        }
        .frame(height: Self.lineHeight)
        if let note {
          Text(note)
            .font(Chrome.font(.body))
            .foregroundStyle([.ask, .approval].contains(agent?.state) ? Chrome.fg : Chrome.muted)
            .truncationMode(.tail)
            .frame(height: Self.lineHeight)
        }
      }
    }
    .lineLimit(1)
    .opacity(TmuxList.isIdle(session, now: .now) ? 0.5 : 1)
    .padding(.leading, Chrome.Space.m)
    .padding(.trailing, Chrome.Space.l)
    .padding(.vertical, (Chrome.Size.row - Self.lineHeight) / 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder private var dotView: some View {
    switch dot {
    case .term:
      Circle().fill(Chrome.fg).frame(width: 7, height: 7)
        .accessibilityLabel("open in Term")
    case .elsewhere:
      Circle().strokeBorder(Chrome.fg2, lineWidth: 1.4).frame(width: 7, height: 7)
        .accessibilityLabel("attached")
    case nil:
      Color.clear
    }
  }

  /// The agent's title in prose, or what runs where in the terminal's terms,
  /// the longest of it that fits.
  @ViewBuilder private var title: some View {
    if let title = agent?.title {
      Text(title)
        .font(Chrome.font(.body))
        .foregroundStyle(Chrome.fg2)
        .truncationMode(.tail)
    } else {
      ViewThatFits(in: .horizontal) {
        ForEach(TmuxList.details(session), id: \.self) { Text($0) }
        Color.clear.frame(width: 0, height: 0)
      }
      .font(Chrome.mono(.secondary))
      .foregroundStyle(Chrome.muted)
    }
  }
}

/// A row's right edge: a pill when the agent waits on him, a check when it
/// finished, a ring at its todo's progress while it works, else an age.
private struct TmuxStatusView: View {
  let status: TmuxList.Status

  var body: some View {
    switch status {
    case .age(let age):
      Text(age)
        .font(Chrome.font(.secondary, .medium))
        .monospacedDigit()
        .foregroundStyle(Chrome.muted)
    case .working(let done, let total, let elapsed):
      HStack(spacing: Chrome.Space.s) {
        ProgressRing(fraction: total.flatMap { total in done.map { total > 0 ? Double($0) / Double(total) : 0 } })
        Text(elapsed)
          .font(Chrome.font(.secondary, .medium))
          .monospacedDigit()
          .foregroundStyle(Chrome.muted)
      }
    case .waits(let word):
      NeedsYouPill(text: word)
    case .finished:
      HStack(spacing: Chrome.Space.xs) {
        Image(systemName: "checkmark").font(Chrome.symbol(.inline))
        Text(TmuxList.stateWord(.done) ?? "").font(Chrome.font(.secondary, .semibold))
      }
      .foregroundStyle(Chrome.done)
    case .failed(let word):
      HStack(spacing: Chrome.Space.xs) {
        Image(systemName: "exclamationmark.circle.fill").font(Chrome.symbol(.inline))
        Text(word).font(Chrome.font(.secondary, .semibold))
      }
      .foregroundStyle(Chrome.failed)
    case .stopped:
      Text(TmuxList.stateWord(.aborted) ?? "")
        .font(Chrome.font(.secondary, .medium))
        .foregroundStyle(Chrome.fg2)
    }
  }
}

/// A host's name over its sessions, with their count once listed.
private struct TmuxHostHead: View {
  let host: Host
  let server: TmuxStore.Server?

  var body: some View {
    HStack(spacing: Chrome.Space.s) {
      Text(host.alias)
        .font(Chrome.font(.body, .semibold))
        .foregroundStyle(Chrome.fg)
      if let count = server?.sessions.count, count > 0 {
        Text("\(count)")
          .font(Chrome.font(.body, .medium))
          .monospacedDigit()
          .foregroundStyle(Chrome.muted)
      }
      if server == nil || server?.status == .loading {
        ProgressView().controlSize(.mini).tint(Chrome.muted)
      }
      Spacer(minLength: 0)
    }
    .textCase(nil)
    .lineLimit(1)
  }
}

/// Why a host lists no sessions, in a few words, as a row of its group.
private struct TmuxServerState: View {
  let host: Host
  let server: TmuxStore.Server

  /// Whether there is something to say: not while loading or listing sessions.
  static func shows(_ server: TmuxStore.Server) -> Bool {
    switch server.status {
    case .loading: false
    case .ready: server.sessions.isEmpty
    default: true
    }
  }

  var body: some View {
    switch server.status {
    case .loading, .ready:
      line("No tmux sessions")
    case .notRunning:
      line("tmux not running")
    case .notInstalled:
      line("tmux not installed")
    case .failed(let text):
      line(text.isEmpty ? "tmux failed" : Tmux.readableError(text))
    case .unreachable(let message):
      // The reason on its own line: cut beside the word, its useful end
      // ("Connection refused") was lost on a phone.
      HStack(spacing: Chrome.Space.m) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Unreachable")
            .font(Chrome.font(.body))
            .foregroundStyle(Chrome.fg)
          Text(message)
            .font(Chrome.mono(.secondary))
            .foregroundStyle(Chrome.muted)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        Button("Retry") { TmuxStore.shared.refresh(host) }
          .buttonStyle(CapsuleButtonStyle())
      }
      .padding(.vertical, Chrome.Space.s)
      .frame(minHeight: Chrome.Size.row)
    }
  }

  private func line(_ text: String) -> some View {
    Text(text)
      .font(Chrome.font(.body))
      .foregroundStyle(Chrome.fg2)
      .lineLimit(2)
      .frame(maxWidth: .infinity, minHeight: Chrome.Size.row, alignment: .leading)
  }
}

/// The long press's preview for a session without a published agent: its
/// screen at a readable size.
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
      .background(Color(uiColor: AppSettings.shared.theme.backgroundColor))
  }

  private var cellWidth: Int {
    Int(((Self.width - 2 * Self.inset) * displayScale / CGFloat(max(session.width, 1))).rounded(.down))
  }
}

/// The long press's preview for an agent: what it is doing or asks, or its
/// whole answer, over the facts a row has no room for.
private struct TmuxAgentPreview: View {
  let session: Tmux.Session
  let agent: AgentInfo

  var body: some View {
    let now = Date.now
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(session.name)
          .font(Chrome.mono(TmuxTab.nameStep, .medium))
          .foregroundStyle(Chrome.fg)
        if let word = TmuxList.stateWord(agent.state) {
          Text(word)
            .font(Chrome.font(.secondary, .medium))
            .foregroundStyle([.error, .exited].contains(agent.state) ? Chrome.bad : Chrome.accent)
        }
        Spacer(minLength: 8)
        // While it works, the table's elapsed says it.
        if agent.state != .working {
          Text(TmuxList.age(agent.stoppedAt ?? agent.since ?? session.lastActivity, now: now))
            .font(Chrome.mono(.caption))
            .foregroundStyle(Chrome.muted)
        }
      }
      .lineLimit(1)
      if let title = agent.title {
        Text(title)
          .font(Chrome.font(.body, .semibold))
          .foregroundStyle(Chrome.fg)
          .padding(.top, 12)
      }
      message
        .padding(.top, agent.title == nil ? 12 : 6)
      let facts = TmuxList.facts(agent, session, now: now)
      if !facts.isEmpty {
        VStack(spacing: 0) {
          ForEach(facts, id: \.label) { fact in
            Rectangle().fill(Chrome.line).frame(height: 1)
            HStack(spacing: 12) {
              Text(fact.label).foregroundStyle(Chrome.muted)
              Spacer(minLength: 0)
              Text(fact.value).foregroundStyle(Chrome.fg2).truncationMode(.middle)
            }
            .font(Chrome.mono(.caption))
            .lineLimit(1)
            .frame(height: 28)
          }
        }
        .padding(.top, 14)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(16)
    .frame(width: TmuxPreview.width, alignment: .leading)
    .background(Chrome.raised)
  }

  /// The question and its choices, the step it is on, or its answer.
  @ViewBuilder private var message: some View {
    switch agent.state {
    case .ask, .approval:
      VStack(alignment: .leading, spacing: 6) {
        if let question = agent.question {
          Text(question).font(Chrome.font(.secondary)).foregroundStyle(Chrome.fg)
        }
        // Read, not answered here: numbered like omp lists them, not buttons.
        ForEach(Array(agent.options.enumerated()), id: \.offset) { index, option in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1)").font(Chrome.mono(.caption)).foregroundStyle(Chrome.muted)
            Text(option).font(Chrome.font(.secondary)).foregroundStyle(Chrome.fg2)
          }
        }
      }
    case .working:
      VStack(alignment: .leading, spacing: 4) {
        if let doing = agent.doing {
          Text(doing).font(Chrome.font(.secondary)).foregroundStyle(Chrome.fg2)
        }
        if let todo = agent.todo {
          Text(["\(todo.done)/\(todo.total)", todo.current].compactMap { $0 }.joined(separator: " · "))
            .font(Chrome.font(.secondary))
            .foregroundStyle(Chrome.muted)
        }
      }
    default:
      if let answer = agent.answer {
        Text(answer).font(Chrome.font(.secondary)).foregroundStyle(Chrome.fg2)
      }
    }
  }
}
