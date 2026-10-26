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

  /// The session names' font, and one character's width in it.
  static let nameSize: CGFloat = 13.5
  private static let nameCharWidth = ("M" as NSString).size(withAttributes: [.font: Helm.uiMono(nameSize, .medium)]).width

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
    let names = hosts.flatMap { store.servers[$0.serverKey]?.sessions.map(\.name) ?? [] }
    let nameWidth = (CGFloat(TmuxList.nameColumn(names)) * Self.nameCharWidth).rounded(.up)
    return List {
      ForEach(hosts) { host in
        let server = store.servers[host.serverKey]
        TmuxHostHead(host: host, server: server)
          .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        ForEach(server?.sessions ?? []) { session in
          row(session, on: host, nameWidth: nameWidth, store: store)
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

  private func row(_ session: Tmux.Session, on host: Host, nameWidth: CGFloat, store: TmuxStore) -> some View {
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
        withAnimation(Helm.ease(0.15)) {
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
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listRowSeparatorTint(Helm.line)
    .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Close", role: .destructive, action: close)
        .tint(Helm.bad)
      if unread {
        Button("Clear", action: clear)
          .tint(Helm.accent)
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
    .accessibilityLabel("\(session.name), \(host.alias)")
    .accessibilityValue([agent?.title ?? session.command, agent.flatMap { TmuxList.stateWord($0.state) }, TmuxList.note(agent)]
      .compactMap { $0 }.joined(separator: ", "))
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

  /// Every listed session's row id: what Select's All checks.
  static func rowIDs(_ store: TmuxStore) -> Set<String> {
    Set(TmuxList.servers(ConfigStore.shared.hosts).flatMap { host in
      (store.servers[host.serverKey]?.sessions ?? []).map { rowID(host, $0) }
    })
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
}

/// One session on one line: its name, the agent's title or what runs where,
/// and at the right edge the agent's progress or state, or the age of the
/// last output. A stop he hasn't seen adds the question or the answer below.
private struct TmuxRow: View {
  enum Dot { case term, elsewhere }

  let session: Tmux.Session
  let agent: AgentInfo?
  let nameWidth: CGFloat
  /// A Term tab is on it (filled accent), or another client is (ring).
  let dot: Dot?
  /// Select mode's checkbox; nil outside it.
  let checked: Bool?

  /// The first line's height: every row is at least 44 pt tall.
  private static let lineHeight: CGFloat = 20

  var body: some View {
    let note = TmuxList.note(agent)
    HStack(alignment: .top, spacing: 0) {
      if let checked {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 20, weight: .light))
          .foregroundStyle(checked ? Helm.accent : Helm.faint)
          .frame(height: Self.lineHeight)
          .padding(.trailing, 10)
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      dotView
        .frame(width: 7, height: Self.lineHeight)
        .padding(.trailing, 5)
      Text(session.name)
        .font(Helm.mono(TmuxTab.nameSize, .medium))
        .foregroundStyle(Helm.fg)
        .truncationMode(.tail)
        .frame(width: nameWidth, height: Self.lineHeight, alignment: .leading)
        .padding(.trailing, 12)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
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
            .font(Helm.sans(13))
            .foregroundStyle([.ask, .approval].contains(agent?.state) ? Helm.fg : Helm.muted)
            .truncationMode(.tail)
        }
      }
    }
    .lineLimit(1)
    .opacity(TmuxList.isIdle(session, now: .now) ? 0.5 : 1)
    .padding(.leading, checked == nil ? 5 : 14)
    .padding(.trailing, 16)
    .padding(.vertical, note == nil ? 12 : 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder private var dotView: some View {
    switch dot {
    case .term:
      Circle().fill(Helm.accent).frame(width: 7, height: 7)
        .accessibilityLabel("open in Term")
    case .elsewhere:
      Circle().strokeBorder(Helm.fg2, lineWidth: 1.2).frame(width: 7, height: 7)
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
        .font(Helm.sans(13.5))
        .foregroundStyle(Helm.fg2)
        .truncationMode(.tail)
    } else {
      ViewThatFits(in: .horizontal) {
        ForEach(TmuxList.details(session), id: \.self) { Text($0) }
        Color.clear.frame(width: 0, height: 0)
      }
      .font(Helm.mono(12))
      .foregroundStyle(Helm.muted)
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
        .font(Helm.mono(11.5))
        .foregroundStyle(Helm.muted)
    case .working(let done, let total, let elapsed):
      HStack(spacing: 6) {
        ProgressRing(fraction: total.flatMap { total in done.map { total > 0 ? Double($0) / Double(total) : 0 } })
        Text([done.flatMap { done in total.map { "\(done)/\($0)" } }, elapsed].compactMap { $0 }.joined(separator: " · "))
          .font(Helm.mono(11.5))
          .foregroundStyle(Helm.muted)
      }
    case .waits(let word):
      Text(word)
        .font(Helm.sans(11.5, .semibold))
        .foregroundStyle(Helm.onAccent)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Helm.accent))
    case .finished:
      HStack(spacing: 4) {
        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
        Text("finished").font(Helm.sans(12, .medium))
      }
      .foregroundStyle(Helm.accent)
    case .failed(let word):
      HStack(spacing: 4) {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold))
        Text(word).font(Helm.sans(12, .medium))
      }
      .foregroundStyle(Helm.bad)
    case .stopped:
      Text("stopped")
        .font(Helm.sans(12, .medium))
        .foregroundStyle(Helm.fg2)
    }
  }
}

/// Todo progress as a small ring; with no todo, a fixed arc that reads as busy.
private struct ProgressRing: View {
  let fraction: Double?

  var body: some View {
    ZStack {
      Circle().stroke(Helm.line2, lineWidth: 1.6)
      Circle()
        .trim(from: 0, to: fraction ?? 0.3)
        .stroke(fraction == nil ? Helm.fg2 : Helm.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 11, height: 11)
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
      .background(Color.black)
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
          .font(Helm.mono(TmuxTab.nameSize, .medium))
          .foregroundStyle(Helm.fg)
        if let word = TmuxList.stateWord(agent.state) {
          Text(word)
            .font(Helm.sans(12, .medium))
            .foregroundStyle([.error, .exited].contains(agent.state) ? Helm.bad : Helm.accent)
        }
        Spacer(minLength: 8)
        // While it works, the table's elapsed says it.
        if agent.state != .working {
          Text(TmuxList.age(agent.stoppedAt ?? agent.since ?? session.lastActivity, now: now))
            .font(Helm.mono(11.5))
            .foregroundStyle(Helm.muted)
        }
      }
      .lineLimit(1)
      if let title = agent.title {
        Text(title)
          .font(Helm.sans(15, .semibold))
          .foregroundStyle(Helm.fg)
          .padding(.top, 12)
      }
      message
        .padding(.top, agent.title == nil ? 12 : 6)
      let facts = TmuxList.facts(agent, session, now: now)
      if !facts.isEmpty {
        VStack(spacing: 0) {
          ForEach(facts, id: \.label) { fact in
            Rectangle().fill(Helm.line).frame(height: 1)
            HStack(spacing: 12) {
              Text(fact.label).foregroundStyle(Helm.muted)
              Spacer(minLength: 0)
              Text(fact.value).foregroundStyle(Helm.fg2).truncationMode(.middle)
            }
            .font(Helm.mono(11.5))
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
    .background(Helm.raised)
  }

  /// The question and its choices, the step it is on, or its answer.
  @ViewBuilder private var message: some View {
    switch agent.state {
    case .ask, .approval:
      VStack(alignment: .leading, spacing: 6) {
        if let question = agent.question {
          Text(question).font(Helm.sans(13.5)).foregroundStyle(Helm.fg)
        }
        // Read, not answered here: numbered like omp lists them, not buttons.
        ForEach(Array(agent.options.enumerated()), id: \.offset) { index, option in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1)").font(Helm.mono(11.5)).foregroundStyle(Helm.muted)
            Text(option).font(Helm.sans(13)).foregroundStyle(Helm.fg2)
          }
        }
      }
    case .working:
      VStack(alignment: .leading, spacing: 4) {
        if let doing = agent.doing {
          Text(doing).font(Helm.sans(13.5)).foregroundStyle(Helm.fg2)
        }
        if let todo = agent.todo {
          Text(["\(todo.done)/\(todo.total)", todo.current].compactMap { $0 }.joined(separator: " · "))
            .font(Helm.sans(13))
            .foregroundStyle(Helm.muted)
        }
      }
    default:
      if let answer = agent.answer {
        Text(answer).font(Helm.sans(13.5)).foregroundStyle(Helm.fg2)
      }
    }
  }
}
