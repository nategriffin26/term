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
    while(id>1 && id in p && !seen[id]++) { print id,p[id]; id=p[id] } } }'
    """
  }

  static func parse(_ output: String, root: UInt32) -> TmuxAttachment {
    let sections = output.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
    guard root > 1, sections.count == 2 else { return .unavailable }
    var parents: [UInt32: UInt32] = [:]
    var processName: Substring?
    for row in sections[1].split(whereSeparator: \.isNewline) {
      let fields = row.split(whereSeparator: \.isWhitespace)
      if fields.count == 3, fields[0] == "R", UInt32(fields[1]) == root { processName = fields[2] }
      if fields.count == 2, let pid = UInt32(fields[0]), let parent = UInt32(fields[1]) {
        parents[pid] = parent
      }
    }
    guard parents[root] != nil, let processName else { return .unavailable }
    var executable = (String(processName) as NSString).lastPathComponent
    if executable.hasSuffix(":") { executable.removeLast() }
    guard executable == "mosh-server" || executable == "sshd" || executable == "sshd-session" else { return .unavailable }
    for row in sections[0].split(separator: "\n") {
      let fields = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard fields.count == 2, var pid = UInt32(fields[0]), !fields[1].isEmpty else { continue }
      var remaining = parents.count + 1
      while pid > 1, remaining > 0 {
        remaining -= 1
        if pid == root { return .attached(String(fields[1])) }
        guard let parent = parents[pid] else { break }
        pid = parent
      }
    }
    return .detached
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
    }
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
