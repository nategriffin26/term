import Foundation

/// A probe distinguishes a detached shell from a process that has already died.
enum TmuxAttachment: Equatable {
  case unavailable
  case detached
  case attached(String)

  /// Only client ancestor chains cross the network, not the host's process list.
  /// The root's presence distinguishes a detached shell from a lost SSH process.
  static func probeCommand(roots: [UInt32]) -> String {
    let roots = roots.map(String.init).joined(separator: " ")
    return """
    \(Tmux.path); c=$(tmux list-clients -F '#{client_pid}\t#{session_name}' 2>/dev/null); \
    printf '%s\\n\\036\\n' "$c"; ids=$(printf '%s\\n' "$c" | cut -f1 | tr '\\n' ' '); \
    ps -A -o pid=,ppid=,stat=,comm= | awk -v roots='\(roots)' -v ids="$ids" \
    '$3 !~ /^Z/ { p[$1]=$2; c[$1]=$4 } END { \
    n=split(roots,r," "); for(i=1;i<=n;i++) { root=r[i]; \
    if(root in p) { print root,p[root]; printf "R\\t%s\\t%s\\n",root,c[root] } } \
    n=split(ids,a," "); for(i=1;i<=n;i++) { id=a[i]; \
    while(id>1 && id in p && !seen[id]++) { print id,p[id]; id=p[id] } } }'; \
    printf '\\035\\n'; tmux list-clients -F '#{client_pid}\t#{pane_id}\t#{@agent}' 2>/dev/null; true
    """
  }

  static func parse(_ output: String, root: UInt32) -> TmuxAttachment {
    resolve(output, root: root).attachment
  }

  /// The agent in the pane the tab's own tmux client shows, from the probe's
  /// last section (client pid, pane id, `@agent`); nil when the tab is not
  /// attached or the host's probe predates the section.
  static func shownAgent(_ output: String, root: UInt32) -> ShownAgent? {
    guard let client = resolve(output, root: root).client,
          let mark = output.firstIndex(of: "\u{1d}") else { return nil }
    for row in output[output.index(after: mark)...].split(whereSeparator: \.isNewline) {
      let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count >= 2, UInt32(fields[0]) == client, fields[1].hasPrefix("%") else { continue }
      return ShownAgent(pane: String(fields[1]), payload: fields.count > 2 ? fields[2] : "")
    }
    return nil
  }

  /// The attachment, and the pid of the tmux client that makes it.
  private static func resolve(_ output: String, root: UInt32) -> (attachment: TmuxAttachment, client: UInt32?) {
    let sections = output.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
    guard root > 1, sections.count == 2 else { return (.unavailable, nil) }
    let processes = sections[1].split(separator: "\u{1d}", maxSplits: 1, omittingEmptySubsequences: false)[0]
    var parents: [UInt32: UInt32] = [:]
    var processName: Substring?
    for row in processes.split(whereSeparator: \.isNewline) {
      let fields = row.split(whereSeparator: \.isWhitespace)
      if fields.count == 3, fields[0] == "R", UInt32(fields[1]) == root { processName = fields[2] }
      if fields.count == 2, let pid = UInt32(fields[0]), let parent = UInt32(fields[1]) {
        parents[pid] = parent
      }
    }
    guard parents[root] != nil, let processName else { return (.unavailable, nil) }
    var executable = (String(processName) as NSString).lastPathComponent
    if executable.hasSuffix(":") { executable.removeLast() }
    guard executable == "mosh-server" || executable == "sshd" || executable == "sshd-session" else { return (.unavailable, nil) }
    for row in sections[0].split(separator: "\n") {
      let fields = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard fields.count == 2, let client = UInt32(fields[0]), !fields[1].isEmpty else { continue }
      var pid = client
      var remaining = parents.count + 1
      while pid > 1, remaining > 0 {
        remaining -= 1
        if pid == root { return (.attached(String(fields[1])), client) }
        guard let parent = parents[pid] else { break }
        pid = parent
      }
    }
    return (.detached, nil)
  }

  static func reconnectCommand(startup: String?, session: String?) -> String? {
    guard let session else {
      if let startup, let configured = Tmux.sessionName(inCommand: startup),
         Tmux.attachedSession(startup, session: configured) != nil {
        return Tmux.reattachCommand(configured)
      }
      return startup
    }
    let attach = Tmux.reattachCommand(session)
    if Tmux.attachedSession(startup, session: session) != nil { return attach }
    // Hand-entered tmux returned to a login shell when it ended. Keep that
    // behavior, including when the session disappears before attach runs.
    let body = "\(Tmux.path); \(attach); exec \"$SHELL\" -l"
    return "sh -c \(Command.shellQuote(body))"
  }

  /// Every tab on one host shares one process snapshot. Different hosts run
  /// concurrently, and a timed-out snapshot never changes a tab's identity.
  @MainActor
  static func refresh(_ tabs: [Tab], timeout: Duration = .seconds(2)) async {
    var hosts: [String: [Tab]] = [:]
    for tab in tabs {
      if let host = tab.target { hosts[host.serverKey, default: []].append(tab) }
    }
    let tasks = hosts.values.map { tabs in
      Task { @MainActor in await refreshHost(tabs, timeout: timeout) }
    }
    await withTaskCancellationHandler {
      for task in tasks { await task.value }
    } onCancel: {
      for task in tasks { task.cancel() }
    }
  }

  @MainActor
  private static func refreshHost(_ tabs: [Tab], timeout: Duration) async {
    let snapshots = tabs.compactMap { tab -> (Tab, Session, UInt32)? in
      guard let remote = tab.remote, let host = tab.target, tab.connecting == nil, remote.processID > 1,
            host.transport != .ssh || remote.status.kind == TERM_STATUS_CONNECTED.rawValue else { return nil }
      return (tab, remote, remote.processID)
    }
    guard let first = snapshots.first, let host = first.0.target,
          case .success(let out)? = await RemoteExec.run(Tab.spec(for: host),
            probeCommand(roots: snapshots.map { $0.2 }), timeout: timeout),
          out.status == 0, !Task.isCancelled else { return }
    let output = String(decoding: out.stdout, as: UTF8.self)
    for (tab, session, root) in snapshots {
      tab.applyTmuxAttachment(parse(output, root: root), session: session, root: root)
      tab.applyShownAgent(shownAgent(output, root: root), session: session)
    }
  }
}

/// The agent in the pane a tab's own tmux client shows, as one probe saw it.
struct ShownAgent: Equatable, Sendable {
  var pane: String
  /// nil when the pane publishes no agent.
  var state: AgentInfo.State?
  /// When its current stop began (`stop.at`), which tells one ask from the next.
  var stop: Double?

  init(pane: String, state: AgentInfo.State?, stop: Double?) {
    self.pane = pane
    self.state = state
    self.stop = stop
  }

  /// From the pane's `@agent` payload (integrations/omp/term-agent.ts).
  init(pane: String, payload: Substring) {
    let p = payload.first == "{" ? (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] : nil
    self.init(pane: pane, state: (p?["state"] as? String).flatMap(AgentInfo.State.init(rawValue:)),
              stop: (p?["stop"] as? [String: Any])?["at"] as? Double)
  }

  var waits: Bool { state == .ask || state == .approval }
}

/// The usage count's `ask_answered`, only as it happens: Return without
/// modifiers, typed while the tab's pane waits on an ask or approval, arms the
/// watch; a later probe of that same pane showing that stop over records it.
/// Seeing, opening or clearing a stop never does.
struct AnswerWatch: Equatable {
  private(set) var shown: ShownAgent?
  private var armed: ShownAgent?

  mutating func submitted() {
    if let shown, shown.waits { armed = shown }
  }

  /// The next probe's view of the pane; true when it shows the armed stop answered.
  mutating func observe(_ next: ShownAgent?) -> Bool {
    defer { shown = next }
    guard let armed else { return false }
    guard let next, next.pane == armed.pane, next.state != nil else {
      self.armed = nil
      return false
    }
    if next.waits, next.stop == armed.stop { return false }
    self.armed = nil
    return true
  }
}

extension RemoteExec {
  @MainActor
  private final class Deadline {
    var continuation: CheckedContinuation<Result<Output, Failure>?, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Result<Output, Failure>?, Never>) {
      self.continuation = continuation
    }

    func finish(_ result: Result<Output, Failure>?) {
      guard let continuation else { return }
      self.continuation = nil
      timer?.cancel()
      timer = nil
      continuation.resume(returning: result)
    }
  }

  /// The C callback cannot be cancelled. Stop waiting at the deadline and
  /// discard its eventual result rather than keeping Reconnect blocked.
  @MainActor
  static func run(_ spec: ConnectSpec, _ command: String, timeout: Duration) async -> Result<Output, Failure>? {
    await withCheckedContinuation { continuation in
      let deadline = Deadline(continuation)
      deadline.timer = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { deadline.finish(nil) }
      }
      Task { deadline.finish(await run(spec, command)) }
    }
  }
}
