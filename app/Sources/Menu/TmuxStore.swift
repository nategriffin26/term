import Foundation
import Observation

extension Host {
  /// The tmux server a host reaches: hosts that differ only in transport or
  /// alias share it, so their sessions show once.
  var serverKey: String { "\(user)@\(hostname):\(port)" }
}

/// What the Sessions overview shows: Term's open tabs and every tmux session
/// on their hosts, grouped by host. Pure, so the merge is tested on its own.
enum SessionMap {
  /// An open tab as the merge needs it.
  struct TabRef: Equatable {
    var id: UUID
    /// The host it runs on; nil at the local prompt.
    var host: Host?
    var tmuxSession: String?
    /// Attached right now (not still connecting).
    var isConnected: Bool
  }

  enum Item: Equatable, Identifiable {
    /// An open tab, with the tmux session it is attached to when the host
    /// lists it, and how many clients besides Term's are on that session.
    case tab(UUID, session: Tmux.Session?, others: Int)
    /// A session no tab is attached to.
    case session(Tmux.Session, others: Int)

    var id: String {
      switch self {
      case .tab(let id, _, _): "tab:\(id.uuidString)"
      case .session(let s, _): "tmux:\(s.id)"
      }
    }
  }

  struct Group: Equatable, Identifiable {
    /// The server key, or "local".
    var id: String
    /// The host sessions attach through; nil for the local group.
    var host: Host?
    var items: [Item]
    /// A host without open tabs that he has not opened in the overview.
    var collapsed: Bool
  }

  static let localID = "local"

  /// Groups in order: the current tab's, then the others' as their tabs come,
  /// then the local group (always: it holds the +), then saved hosts without
  /// tabs, which are mostly one-line heads.
  /// In a host group, its tabs come first, then its other sessions, most
  /// recently active first.
  static func groups(tabs: [TabRef], current: UUID?, hosts: [Host], sessions: [String: [Tmux.Session]],
                     expanded: Set<String>) -> [Group] {
    let ordered = tabs.filter { $0.id == current } + tabs.filter { $0.id != current }
    var order: [String] = []
    var host: [String: Host] = [:]
    var tabsIn: [String: [TabRef]] = [:]
    for tab in ordered {
      let key = tab.host?.serverKey ?? localID
      if tabsIn[key] == nil { order.append(key) }
      tabsIn[key, default: []].append(tab)
      if host[key] == nil, let h = tab.host { host[key] = h }
    }
    // Back in tab order inside each group.
    for key in order { tabsIn[key] = tabs.filter { ($0.host?.serverKey ?? localID) == key } }
    if !order.contains(localID) { order.append(localID) }
    for saved in hosts where host[saved.serverKey] == nil {
      host[saved.serverKey] = saved
      order.append(saved.serverKey)
    }

    return order.map { key in
      let groupTabs = tabsIn[key] ?? []
      let listed = sessions[key] ?? []
      var items: [Item] = []
      var shown = Set<String>()
      for tab in groupTabs {
        let session = tab.tmuxSession.flatMap { name in listed.first { $0.name == name } }
        if let session { shown.insert(session.id) }
        items.append(.tab(tab.id, session: session, others: session.map { others(on: $0, tabs: groupTabs) } ?? 0))
      }
      for session in listed where !shown.contains(session.id) {
        items.append(.session(session, others: others(on: session, tabs: groupTabs)))
      }
      let isLocal = key == localID
      return Group(id: key, host: isLocal ? nil : host[key], items: items,
                   collapsed: !isLocal && groupTabs.isEmpty && !expanded.contains(key))
    }
  }

  /// Clients on `session` that are not Term's tabs: the Mac, another phone.
  static func others(on session: Tmux.Session, tabs: [TabRef]) -> Int {
    max(0, session.attached - tabs.filter { $0.isConnected && $0.tmuxSession == session.name }.count)
  }

  /// Folders to start a new session in: where the host's sessions are, most
  /// recently active first, then home.
  static func folders(_ sessions: [Tmux.Session]) -> [String] {
    var seen = Set<String>()
    return (sessions.sorted { $0.lastActivity > $1.lastActivity }.map(\.path) + ["~"])
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// "nvim · ~/Projects/api": what runs in the session's active pane, and where.
  static func detail(_ session: Tmux.Session) -> String {
    [session.command, shortPath(session.path)].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// A remote home ("/Users/NAME", "/home/NAME", "/root") shown as "~".
  static func shortPath(_ path: String) -> String {
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
}

/// Every host's tmux sessions and their snapshots, refreshed while the
/// overview shows. One store for the app: sessions belong to hosts, not windows.
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
  }

  private(set) var servers: [String: Server] = [:]
  /// Hosts without tabs he opened in the overview (server keys), kept across launches.
  private(set) var expanded: Set<String>

  /// One terminal engine per snapshot, fed each new capture.
  @ObservationIgnored private var engines: [String: Session] = [:]
  @ObservationIgnored private var captured: [String: Date] = [:]
  @ObservationIgnored private var inFlight: Set<String> = []

  static let expandedKey = "sessions.expandedHosts"
  /// While the overview shows: often enough to follow a build scrolling by,
  /// cheap because only sessions with new activity are captured again.
  static let interval: Duration = .seconds(3)

  private init() {
    expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
  }

  var sessionsByServer: [String: [Tmux.Session]] { servers.mapValues(\.sessions) }

  func setExpanded(_ key: String, _ on: Bool) {
    if on { expanded.insert(key) } else { expanded.remove(key) }
    UserDefaults.standard.set(expanded.sorted(), forKey: Self.expandedKey)
  }

  /// The snapshot engine of a session, once it has been captured.
  func engine(_ key: String, _ id: String) -> Session? { engines[key + "\t" + id] }

  /// Refreshes `hosts` now and every `interval` until the task is cancelled
  /// (the overview hides). The first pass also retries unreachable hosts.
  func watch(_ hosts: @MainActor () -> [Host]) async {
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

  /// One overview exec on `host`, unless one is already running.
  func refresh(_ host: Host) {
    let key = host.serverKey
    guard !inFlight.contains(key) else { return }
    inFlight.insert(key)
    if servers[key] == nil { servers[key] = Server() }
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
    switch result {
    case .failure(let failure):
      server = Server(status: .unreachable(failure.message))
    case .success(let output):
      switch Tmux.parseOverview(status: output.status, output: output.stdout) {
      case .success(let overview):
        server = Server(status: .ready, sessions: overview.sessions)
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
    for id in engines.keys where id.hasPrefix(key + "\t") && !alive.contains(id) {
      engines[id] = nil
      captured[id] = nil
    }
    if servers[key] != server { servers[key] = server }
  }

  private func show(_ screen: String, of session: Tmux.Session, key: String) {
    let id = key + "\t" + session.id
    let cols = max(session.width, 2), rows = max(session.height, 1)
    let engine: Session
    if let known = engines[id], known.cols == cols, known.rows == rows {
      engine = known
    } else if let made = Session(localCols: cols, rows: rows) {
      engine = made
      engines[id] = made
    } else {
      return
    }
    engine.feed(Tmux.screenBytes(screen, cursorX: session.cursorX, cursorY: session.cursorY))
    captured[id] = session.lastActivity
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
      return text.isEmpty ? "tmux exited with status \(out.status)" : text
    case .success: return nil
    }
  }

  /// A new detached session; the name tmux gave it, or why not.
  func create(name: String, folder: String, on host: Host) async -> Result<String, RemoteExec.Failure> {
    let result = await RemoteExec.run(Tab.spec(for: host), Tmux.newCommand(name: Tmux.cleanName(name), folder: folder))
    refresh(host)
    switch result {
    case .failure(let failure): return .failure(failure)
    case .success(let out):
      let text = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if out.status == 0, !text.isEmpty { return .success(text) }
      return .failure(.init(message: text.isEmpty ? "tmux exited with status \(out.status)" : text))
    }
  }

  func rename(_ session: Tmux.Session, to name: String, on host: Host) async -> String? {
    await run(Tmux.renameCommand(id: session.id, to: Tmux.cleanName(name)), on: host)
  }

  func kill(_ session: Tmux.Session, on host: Host) async -> String? {
    await run(Tmux.killCommand(id: session.id), on: host)
  }

  /// `keep`: sizes of Term's own clients on the session ("COLSxROWS").
  func detachOthers(_ session: Tmux.Session, keep: Set<String>, on host: Host) async -> String? {
    await run(Tmux.detachOthersCommand(id: session.id, keep: keep), on: host)
  }
}
