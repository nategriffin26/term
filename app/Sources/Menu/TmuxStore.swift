import Foundation
import Observation
import UIKit

extension Host {
  /// The tmux server a host reaches: hosts that differ only in transport or
  /// alias share it, so their sessions show once.
  var serverKey: String { "\(user)@\(hostname):\(port)" }
}

/// What the tmux tab shows, pure so it is tested on its own.
enum TmuxList {
  /// One section per tmux server among the saved hosts, in their order, the
  /// server `first` (`tmux host` asked for it) leading: hosts that reach the
  /// same server show once, as the first saved.
  static func servers(_ hosts: [Host], first: String? = nil) -> [Host] {
    var seen = Set<String>()
    var servers = hosts.filter { seen.insert($0.serverKey).inserted }
    if let lead = servers.firstIndex(where: { $0.serverKey == first }) { servers.insert(servers.remove(at: lead), at: 0) }
    return servers
  }

  /// Clients on `session` that are not Term's: the Mac, another phone.
  /// `term` counts Term's tabs attached to it right now.
  static func others(on session: Tmux.Session, term: Int) -> Int {
    max(0, session.attached - term)
  }

  /// What runs in the session's active pane, where, and its windows when it
  /// has more than one, from the whole path down to its last folder
  /// ("nvim · ~/Projects/api · 3 windows", "nvim · …/api · 3 windows"): a
  /// narrow line shows the longest that fits, cut at a folder, never mid-name.
  static func details(_ session: Tmux.Session) -> [String] {
    let paths = session.path.isEmpty ? [""] : pathTails(session.path)
    let windows = session.windows > 1 ? "\(session.windows) windows" : ""
    return paths.map { [session.command, $0, windows].filter { !$0.isEmpty }.joined(separator: " · ") }
  }

  /// A session nobody has touched for more than a day reads dimmer.
  static func isIdle(_ session: Tmux.Session, now: Date) -> Bool {
    now.timeIntervalSince(session.lastActivity) > 86400
  }

  /// A refresh's list while sessions (ids) are being closed: they stay out
  /// even when the refresh started before they ended. tmux never reuses an
  /// id, so one no longer listed is done and leaves `closing`.
  static func hide(_ closing: Set<String>, from sessions: [Tmux.Session]) -> ([Tmux.Session], Set<String>) {
    (sessions.filter { !closing.contains($0.id) }, closing.intersection(sessions.map(\.id)))
  }

  /// A refresh's sessions in the order already shown, so a row never moves
  /// under his finger as sessions print; ones new since then go first.
  static func keepOrder(_ shown: [Tmux.Session], _ fresh: [Tmux.Session]) -> [Tmux.Session] {
    let known = Set(shown.map(\.id))
    let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return fresh.filter { !known.contains($0.id) } + shown.compactMap { byID[$0.id] }
  }

  /// Why closing failed, from the kills' output; a session already gone is closed.
  static func closeComplaint(_ output: Data) -> String? {
    String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
      .first { !$0.hasPrefix("can't find session") }.map { Tmux.readableError(String($0)) }
  }

  /// A path shown in full, then shortened from the front a folder at a time:
  /// "/tmp/demo/api", "…/demo/api", "…/api".
  static func pathTails(_ path: String) -> [String] {
    let short = shortPath(path)
    let parts = short.split(separator: "/")
    guard parts.count > 1 else { return [short] }
    // "~/a" → "…/a" saves nothing: each tail must be shorter than the last.
    return (1..<parts.count).reversed().reduce(into: [short]) { tails, n in
      let tail = "…/" + parts.suffix(n).joined(separator: "/")
      if tail.count < tails[tails.count - 1].count { tails.append(tail) }
    }
  }

  /// A remote home ("/Users/NAME", "/home/NAME", "/root") shown as "~", and
  /// macOS's /private/tmp, /private/var and /private/etc as the /tmp, /var
  /// and /etc one types.
  static func shortPath(_ path: String) -> String {
    for root in ["/tmp", "/var", "/etc"] where path == "/private" + root || path.hasPrefix("/private" + root + "/") {
      return String(path.dropFirst("/private".count))
    }
    if path == "/root" || path.hasPrefix("/root/") { return "~" + path.dropFirst(5) }
    for base in ["/Users/", "/home/"] where path.hasPrefix(base) {
      let rest = path.dropFirst(base.count)
      guard let user = rest.split(separator: "/", maxSplits: 1).first, !user.isEmpty else { continue }
      return "~" + rest.dropFirst(user.count)
    }
    return path
  }

  /// Time since a session's last activity, compactly: "now", "4m", "2h", "3d".
  static func age(_ date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86400)d"
    }
  }

  /// Agents as a host just reported them, less the stops he has seen on
  /// this phone (`seen`: session id → the stop he saw) before the host's
  /// `@seen` caught up: a later stop is new again.
  static func unseen(_ agents: [String: AgentInfo], seen: [String: Date]) -> [String: AgentInfo] {
    var agents = agents
    for (id, agent) in agents where agent.unread {
      if let saw = seen[id], let stop = agent.stoppedAt, stop <= saw { agents[id]?.unread = false }
    }
    return agents
  }
}

/// Every saved host's tmux sessions and their snapshots, refreshed while the
/// tmux tab shows. One store for the app: sessions belong to hosts, not windows.
@MainActor @Observable
final class TmuxStore {
  static let shared = TmuxStore()

  enum Status: Equatable {
    case loading
    case ready
    case notRunning
    case notInstalled
    case failed(String)
    case unreachable(String)
  }

  struct Server: Equatable {
    var status = Status.loading
    var sessions: [Tmux.Session] = []

    var isUnreachable: Bool { if case .unreachable = status { true } else { false } }
  }

  private(set) var servers: [String: Server] = [:]
  /// Each snapshot's last lines, for its row.
  private(set) var excerpts: [String: ScreenExcerpt] = [:]
  /// Each session's agent, by server key, then session id.
  private(set) var agents: [String: [String: AgentInfo]] = [:]

  /// One terminal engine per snapshot, fed each new capture.
  @ObservationIgnored private var engines: [String: Session] = [:]
  @ObservationIgnored private var captured: [String: Date] = [:]
  /// The last capture of each snapshot, for the tab that attaches to it to show until it draws.
  @ObservationIgnored private var screens: [String: Data] = [:]
  @ObservationIgnored private var inFlight: Set<String> = []
  /// Sessions being closed or closed, by server key: the list leaves them
  /// out, even from a refresh that started before they ended.
  @ObservationIgnored private var closing: [String: Set<String>] = [:]
  /// Servers listed since the tab opened: their order holds until it closes.
  @ObservationIgnored private var ordered: Set<String> = []
  /// Stops he saw or cleared here (server key → session id → stop time),
  /// held until the host's `@seen` says so too.
  @ObservationIgnored private var cleared: [String: [String: Date]] = [:]
  /// The tmux tab is refreshing: its exec lists the agents too.
  @ObservationIgnored private var watching = false

  /// While the tmux tab shows: often enough to follow a build scrolling by,
  /// cheap because only sessions with new activity are captured again.
  static let interval: Duration = .seconds(3)
  /// While it doesn't: the agent panes alone, to keep the badge true.
  static let agentInterval: Duration = .seconds(10)

  private init() {}

  var hasSessions: Bool { servers.values.contains { !$0.sessions.isEmpty } }

  /// Sessions whose agent stopped for him since he last saw them: the tmux tab's badge.
  var unreadCount: Int { agents.values.reduce(0) { $0 + $1.values.count(where: \.unread) } }

  func agent(_ key: String, _ id: String) -> AgentInfo? { agents[key]?[id] }

  /// The snapshot engine of a session, once it has been captured.
  func engine(_ key: String, _ id: String) -> Session? { engines[key + "\t" + id] }
  func excerpt(_ key: String, _ id: String) -> ScreenExcerpt? { excerpts[key + "\t" + id] }
  /// The last capture of a session, as terminal bytes.
  func screen(_ key: String, _ id: String) -> Data? { screens[key + "\t" + id] }

  /// Refreshes `hosts` now and every `interval` until the task is cancelled
  /// (the tmux tab hides). The first pass also retries unreachable hosts and
  /// lists each host most recently active first.
  func watch(_ hosts: @MainActor () -> [Host]) async {
    ordered = []
    watching = true
    defer { watching = false }
    var first = true
    while !Task.isCancelled {
      for host in hosts() {
        if !first, case .unreachable = servers[host.serverKey]?.status { continue }
        refresh(host)
      }
      first = false
      try? await Task.sleep(for: Self.interval)
    }
  }

  /// Checks the agents every `agentInterval` while Term is in front and the
  /// tmux tab isn't refreshing. Runs for the app's life; coming to the front
  /// checks at once (AppDelegate).
  func watchAgents() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: Self.agentInterval)
      if UIApplication.shared.applicationState == .active { checkAgents() }
    }
  }

  /// One agent-panes exec on each saved host not already running one;
  /// unreachable hosts only on `retry` (Term coming to the front).
  func checkAgents(retry: Bool = false) {
    guard !watching else { return }
    for host in TmuxList.servers(ConfigStore.shared.hosts) {
      let key = host.serverKey
      guard !inFlight.contains(key), retry || servers[key]?.isUnreachable != true else { continue }
      inFlight.insert(key)
      Task {
        let result = await RemoteExec.run(Tab.spec(for: host), Tmux.agentsCommand())
        inFlight.remove(key)
        switch result {
        case .success(let output):
          if servers[key]?.isUnreachable == true { servers[key] = nil }
          let hidden = closing[key] ?? []
          setAgents(Tmux.parseAgents(output.stdout).filter { !hidden.contains($0.key) }, for: key)
        case .failure(let failure):
          servers[key] = Server(status: .unreachable(failure.message))
          setAgents([:], for: key)
        }
      }
    }
  }

  /// One overview exec on `host`, unless one is already running. A retry of
  /// an unreachable host shows as loading until it answers.
  func refresh(_ host: Host) {
    let key = host.serverKey
    guard !inFlight.contains(key) else { return }
    inFlight.insert(key)
    if servers[key] == nil || servers[key]?.isUnreachable == true { servers[key] = Server() }
    let skip = captured.filter { $0.key.hasPrefix(key + "\t") }
      .reduce(into: [String: Date]()) { $0[String($1.key.dropFirst(key.count + 1))] = $1.value }
    let command = Tmux.overviewCommand(skip: skip)
    Task {
      let result = await RemoteExec.run(Tab.spec(for: host), command)
      inFlight.remove(key)
      apply(result, to: key)
    }
  }

  private func apply(_ result: Result<RemoteExec.Output, RemoteExec.Failure>, to key: String) {
    var server = servers[key] ?? Server()
    var agents: [String: AgentInfo] = [:]
    switch result {
    case .failure(let failure):
      server = Server(status: .unreachable(failure.message))
    case .success(let output):
      switch Tmux.parseOverview(status: output.status, output: output.stdout) {
      case .success(let overview):
        let sessions = ordered.contains(key) ? TmuxList.keepOrder(servers[key]?.sessions ?? [], overview.sessions) : overview.sessions
        ordered.insert(key)
        server = Server(status: .ready, sessions: sessions)
        agents = overview.agents
        for session in overview.sessions {
          guard let screen = overview.screens[session.id] else { continue }
          show(screen, of: session, key: key)
        }
      case .failure(.notRunning): server = Server(status: .notRunning)
      case .failure(.notInstalled): server = Server(status: .notInstalled)
      case .failure(.failed(_, let text)): server = Server(status: .failed(text))
      }
    }
    let alive = Set(server.sessions.map { key + "\t" + $0.id })
    (server.sessions, closing[key]) = TmuxList.hide(closing[key] ?? [], from: server.sessions)
    for id in engines.keys where id.hasPrefix(key + "\t") && !alive.contains(id) {
      engines[id] = nil
      captured[id] = nil
      screens[id] = nil
      excerpts[id] = nil
    }
    if servers[key] != server { servers[key] = server }
    // Sessions being closed take their agents with them.
    let listed = Set(server.sessions.map(\.id))
    setAgents(agents.filter { listed.contains($0.key) }, for: key)
  }

  /// A host's agents as just read, less the stops he has seen here since.
  private func setAgents(_ fresh: [String: AgentInfo], for key: String) {
    cleared[key] = cleared[key]?.filter { fresh[$0.key] != nil }
    let fresh = TmuxList.unseen(fresh, seen: cleared[key] ?? [:])
    if agents[key] ?? [:] != fresh { agents[key] = fresh.isEmpty ? nil : fresh }
    seeViewed()
  }

  /// He has seen these sessions' stops (ids on `host`): gone from the badge
  /// at once, and from his other devices once the host's `@seen` moves.
  func markSeen(_ ids: [String], on host: Host) {
    let key = host.serverKey
    let ids = ids.filter { agents[key]?[$0]?.unread == true }
    guard !ids.isEmpty else { return }
    for id in ids {
      cleared[key, default: [:]][id] = agents[key]?[id]?.stoppedAt
      agents[key]?[id]?.unread = false
    }
    let command = Tmux.seenCommand(ids: ids)
    Task { _ = await RemoteExec.run(Tab.spec(for: host), command) }
  }

  /// A session he is looking at (focused in a Term window in front) has
  /// nothing new for him.
  func seeViewed() {
    for (host, name) in SpaceController.viewedTmuxSessions {
      let ids = (agents[host.serverKey] ?? [:]).filter { $0.value.unread && $0.value.session == name }.map(\.key)
      if !ids.isEmpty { markSeen(ids, on: host) }
    }
  }

  private func show(_ screen: String, of session: Tmux.Session, key: String) {
    let id = key + "\t" + session.id
    let cols = max(session.width, 2), rows = max(session.height, 1)
    let engine: Session
    if let known = engines[id], known.cols == cols, known.rows == rows {
      engine = known
    } else if let made = Session(localCols: cols, rows: rows) {
      // Drawn as the tab that attaches will draw it.
      made.setTheme(AppSettings.shared.termTheme)
      engine = made
      engines[id] = made
    } else {
      return
    }
    engine.feed(Tmux.screenBytes(screen, cursorX: session.cursorX, cursorY: session.cursorY))
    screens[id] = Tmux.screenBytes(screen, cursorX: session.cursorX, cursorY: session.cursorY, top: session.statusRows)
    captured[id] = session.lastActivity
    let excerpt = ScreenExcerpt(engine)
    if excerpts[id] != excerpt { excerpts[id] = excerpt }
  }

  // MARK: - Actions

  /// Runs an action on `host`, refreshes it, and returns tmux's complaint if it failed.
  private func run(_ command: String, on host: Host) async -> String? {
    let result = await RemoteExec.run(Tab.spec(for: host), command)
    refresh(host)
    switch result {
    case .failure(let failure): return failure.message
    case .success(let out) where out.status != 0:
      let text = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? "tmux exited with status \(out.status)" : Tmux.readableError(text)
    case .success: return nil
    }
  }

  /// Ends `sessions` on `host`. They leave the list at once and stay out of
  /// it unless tmux could not end them; one already gone counts as closed.
  /// Returns why the rest are still there.
  func close(_ sessions: [Tmux.Session], on host: Host) async -> String? {
    let key = host.serverKey
    let ids = Set(sessions.map(\.id))
    closing[key, default: []].formUnion(ids)
    servers[key]?.sessions.removeAll { ids.contains($0.id) }
    agents[key] = agents[key]?.filter { !ids.contains($0.key) }
    let result = await RemoteExec.run(Tab.spec(for: host), Tmux.killCommand(ids: sessions.map(\.id)))
    let complaint: String?
    switch result {
    case .failure(let failure): complaint = failure.message
    case .success(let out): complaint = TmuxList.closeComplaint(out.stdout)
    }
    if complaint != nil { closing[key]?.subtract(ids) }
    refresh(host)
    return complaint
  }

  /// `keep`: sizes of Term's own clients on the session ("COLSxROWS").
  func detachOthers(_ session: Tmux.Session, keep: Set<String>, on host: Host) async -> String? {
    await run(Tmux.detachOthersCommand(id: session.id, keep: keep), on: host)
  }
}
