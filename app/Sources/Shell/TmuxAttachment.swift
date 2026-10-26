import Foundation

/// A probe distinguishes a detached shell from a process that has already died.
enum TmuxAttachment: Equatable {
  case unavailable
  case detached
  case attached(String)

  /// Only client ancestor chains cross the network, not the host's process list.
  /// The root's presence distinguishes a detached shell from a lost SSH process.
  static func probeCommand(root: UInt32) -> String {
    """
    \(Tmux.path); c=$(tmux list-clients -F '#{client_pid}\t#{session_name}' 2>/dev/null); \
    printf '%s\\n\\036\\n' "$c"; ids=$(printf '%s\\n' "$c" | cut -f1); \
    ps -A -o pid=,ppid= | awk -v root=\(root) -v ids="$ids" \
    '{ p[$1]=$2 } END { if (root in p) print root,p[root]; \
    n=split(ids,a,"\\n"); for(i=1;i<=n;i++) { id=a[i]; \
    while(id>1 && id in p && !seen[id]++) { print id,p[id]; id=p[id] } } }'
    """
  }

  static func parse(_ output: String, root: UInt32) -> TmuxAttachment {
    let sections = output.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
    guard root > 1, sections.count == 2 else { return .unavailable }
    var parents: [UInt32: UInt32] = [:]
    for row in sections[1].split(whereSeparator: \.isNewline) {
      let fields = row.split(whereSeparator: \.isWhitespace)
      if fields.count == 2, let pid = UInt32(fields[0]), let parent = UInt32(fields[1]) {
        parents[pid] = parent
      }
    }
    guard parents[root] != nil else { return .unavailable }
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
    guard let session else { return startup }
    let attach = Tmux.reattachCommand(session)
    if Tmux.attachedSession(startup, session: session) != nil { return attach }
    // Hand-entered tmux returned to a login shell when it ended. Keep that
    // behavior, including when the session disappears before attach runs.
    return "\(Tmux.path); \(attach); exec \"$SHELL\" -l"
  }
}
