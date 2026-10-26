import Foundation

/// tmux is the session store shared with the Mac; the phone lists its
/// sessions with a snapshot of each, attaches, closes and detaches them, and
/// reads history over SSH exec.
enum Tmux {
  struct Session: Identifiable, Equatable, Sendable {
    /// tmux's own id ("$3"): exact as a target and stable across renames.
    var id: String
    var name: String
    var windows: Int
    /// Number of clients attached right now.
    var attached: Int
    var created: Date
    /// Last output in its current window (what its snapshot shows).
    var lastActivity: Date
    /// The active pane of the current window: what runs there and where.
    var command: String
    var path: String
    /// That pane's size and cursor, for its snapshot.
    var width: Int
    var height: Int
    var cursorX: Int
    var cursorY: Int
    /// Rows tmux's status line takes above the pane on its clients.
    var statusRows = 0
  }

  /// One refresh of a host: its sessions, most recently active first, the
  /// screens captured this time (by session id), and each session's agent.
  struct Overview: Equatable, Sendable {
    var sessions: [Session]
    var screens: [String: String]
    var agents: [String: AgentInfo] = [:]
  }

  enum ListError: Error, Equatable {
    case notInstalled
    /// No tmux server: nothing has started one, or its last session ended.
    case notRunning
    case failed(status: Int32, output: String)
  }

  /// Commands run in a non-interactive shell, whose PATH often lacks Homebrew.
  static let path = #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin""#

  /// list-sessions fields, tab-separated. The name goes last so a tab in it
  /// stays in it; id and activity go first for the capture loop. Activity is
  /// window_activity: session_activity moves only on key input, so a session
  /// printing output would keep its first snapshot.
  static let fields = [
    "session_id", "window_activity", "session_windows", "session_attached", "session_created",
    "pane_width", "pane_height", "cursor_x", "cursor_y", "pane_current_command", "pane_current_path",
    // The status line's rows when it sits on top ("on", or a count), else "off".
    "?#{==:#{status-position},top},#{status},off",
    "session_name",
  ]

  /// Starts each captured screen in the overview output: ASCII record separator.
  static let screenMark: UInt8 = 0x1E

  /// One exec per refresh: the session list, the agent panes, then the
  /// visible screen of each session's active pane, except sessions in `skip`
  /// (id → activity) whose activity has not moved since their last capture.
  /// Once the list is read the exec succeeds: an empty server, or a session
  /// gone before its capture, still shows the list.
  static func overviewCommand(skip: [String: Date] = [:]) -> String {
    let format = fields.map { "#{\($0)}" }.joined(separator: "\t")
    let known = skip.sorted { $0.key < $1.key }.map { "\($0.key):\(Int($0.value.timeIntervalSince1970))" }
    return [
      path,
      "l=$(tmux list-sessions -F '\(format)' 2>&1)",
      "s=$?",
      #"printf '%s\n' "$l""#,
      "[ $s = 0 ] || exit $s",
      agentsScript,
      #"printf '%s\n' "$l" | while IFS='\#t' read -r i a r; do [ -n "$i" ] || continue; case ' \#(known.joined(separator: " ")) ' in *" $i:$a "*) ;; *) printf '\036%s\n' "$i"; tmux capture-pane -p -e -J -t "$i" 2>/dev/null;; esac; done"#,
      "exit 0",
    ].joined(separator: "; ")
  }

  static func parseOverview(status: Int32, output: Data, now: Date = .now) -> Result<Overview, ListError> {
    let parts = output.split(separator: screenMark, omittingEmptySubsequences: false)
    let head = (parts.first ?? Data()).split(separator: agentMark, maxSplits: 1, omittingEmptySubsequences: false)
    let list = String(decoding: head.first ?? Data(), as: UTF8.self)
    if status == 127 { return .failure(.notInstalled) }
    if status != 0 {
      if list.contains("no server running") || list.contains("error connecting") {
        return .failure(.notRunning)
      }
      return .failure(.failed(status: status, output: list.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    let sessions = list.split(whereSeparator: \.isNewline).compactMap(parseSession)
    let agents = head.count > 1 ? parseAgents(String(decoding: head[1], as: UTF8.self), now: now) : [:]
    var screens: [String: String] = [:]
    for part in parts.dropFirst() {
      let text = String(decoding: part, as: UTF8.self)
      guard let newline = text.firstIndex(of: "\n") else { continue }
      var screen = text[text.index(after: newline)...]
      if screen.hasSuffix("\n") { screen = screen.dropLast() }
      screens[String(text[..<newline])] = String(screen)
    }
    return .success(Overview(sessions: sessions.sorted { $0.lastActivity > $1.lastActivity }, screens: screens, agents: agents))
  }

  private static func parseSession(_ line: Substring) -> Session? {
    let f = line.split(separator: "\t", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
    guard f.count == fields.count, f[0].hasPrefix("$"),
          let activity = TimeInterval(f[1]), let windows = Int(f[2]), let attached = Int(f[3]),
          let created = TimeInterval(f[4]), let width = Int(f[5]), let height = Int(f[6]),
          let cx = Int(f[7]), let cy = Int(f[8]) else { return nil }
    return Session(id: f[0], name: f[12], windows: windows, attached: attached,
                   created: Date(timeIntervalSince1970: created), lastActivity: Date(timeIntervalSince1970: activity),
                   command: f[9], path: f[10], width: width, height: height, cursorX: cx, cursorY: cy,
                   statusRows: f[11] == "on" ? 1 : Int(f[11]) ?? 0)
  }

  /// What a terminal engine is fed to show a captured screen as it was:
  /// cleared, rows from the top (below `top` blank rows, where tmux's status
  /// line goes), the cursor where the pane had it.
  static func screenBytes(_ screen: String, cursorX: Int, cursorY: Int, top: Int = 0) -> Data {
    let rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
    return Data(("\u{1b}[0m\u{1b}[H\u{1b}[2J" + String(repeating: "\r\n", count: top) + rows.joined(separator: "\u{1b}[0m\r\n")
      + "\u{1b}[0m\u{1b}[\(cursorY + top + 1);\(cursorX + 1)H").utf8)
  }

  // MARK: - Actions

  static func attachCommand(_ name: String) -> String {
    "tmux new -A -s \(Command.shellQuote(name))"
  }

  /// The session a startup command is Term's own attach to, else nil: only
  /// then may a reconnect assume what it runs (a host's own command, say
  /// `tmux -L work new -A -s main`, is left as configured).
  static func attachedSession(_ command: String?, session: String?) -> String? {
    guard let session, command == attachCommand(session) else { return nil }
    return session
  }

  /// What a reconnect's new server runs: attach only, so a session closed
  /// meanwhile (from the tmux tab, the Mac) is not made again, empty, by
  /// `new -A`.
  static func reattachCommand(_ name: String) -> String {
    "tmux attach -t \(Command.shellQuote("=" + name))"
  }

  /// Exits 0 while session `name` exists, 1 once it has ended or tmux has
  /// stopped.
  static func hasSessionCommand(_ name: String) -> String {
    "\(path); tmux has-session -t \(Command.shellQuote("=" + name))"
  }

  /// Ends each session; one that fails says why on its own line.
  static func killCommand(ids: [String]) -> String {
    ([path] + ids.map { "tmux kill-session -t \(Command.shellQuote($0)) 2>&1" }).joined(separator: "; ")
  }

  /// Detaches the session's clients except Term's own, told apart by size
  /// (`keep`, "COLSxROWS" of each Term tab on it): the phone can't name its
  /// tmux client, and another client of exactly its size is rare and only
  /// stays attached. With nothing to keep, every client goes.
  static func detachOthersCommand(id: String, keep: Set<String>) -> String {
    let target = Command.shellQuote(id)
    guard !keep.isEmpty else { return "\(path); tmux detach-client -s \(target) 2>&1" }
    let sizes = keep.sorted().joined(separator: " ")
    return "\(path); tmux list-clients -t \(target) -F '#{client_width}x#{client_height} #{client_tty}' | "
      + #"while read -r z t; do case ' \#(sizes) ' in *" $z "*) ;; *) tmux detach-client -t "$t";; esac; done"#
  }

  /// What a failed action prints, in a few words: tmux's own complaints
  /// name ids ("$3") and sockets he never sees.
  static func readableError(_ output: String) -> String {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("can't find session") { return "That session has ended" }
    if text.hasPrefix("no server running") || text.hasPrefix("error connecting to") { return "tmux isn't running" }
    return text
  }

  /// Scrollback plus screen of the session's active pane, with colors, wrapped
  /// lines joined so they rewrap at the phone's width.
  static func historyCommand(_ name: String?, lines: Int = 3000) -> String {
    var cmd = "tmux capture-pane -p -e -J -S -\(lines)"
    if let name { cmd += " -t \(Command.shellQuote(name))" }
    return cmd
  }

  /// The session a startup command attaches to (`tmux new -A -s NAME`,
  /// `tmux new -As NAME`, `tmux attach -t NAME`, `tmux a -tNAME`), so history
  /// knows its target. Flags are read the way tmux's getopt reads them.
  static func sessionName(inCommand command: String) -> String? {
    guard case .success(let words) = Command.tokenize(command), words.first == "tmux" else { return nil }
    // Flags of new-session/attach-session that take a value.
    let takesValue: Set<Character> = ["c", "e", "f", "F", "n", "s", "t", "x", "y"]
    var found: [Character: String] = [:]
    var i = 1
    while i < words.count {
      let word = words[i]
      i += 1
      guard word.count > 1, word.hasPrefix("-"), word != "--" else { continue }
      var chars = Substring(word.dropFirst())
      while let flag = chars.first {
        chars = chars.dropFirst()
        guard takesValue.contains(flag) else { continue }
        var value = String(chars)
        if value.isEmpty, i < words.count {
          value = words[i]
          i += 1
        }
        if !value.isEmpty { found[flag] = value }
        break
      }
    }
    return found["s"] ?? found["t"]
  }
}

/// term_exec as async: one command on a host over SSH, output and status back.
enum RemoteExec {
  struct Output: Sendable {
    var status: Int32
    var stdout: Data
  }

  struct Failure: Error, Equatable {
    var message: String
  }

  private final class Box: Sendable {
    let continuation: CheckedContinuation<Result<Output, Failure>, Never>
    init(_ c: CheckedContinuation<Result<Output, Failure>, Never>) { continuation = c }
  }

  static func run(_ spec: ConnectSpec, _ command: String) async -> Result<Output, Failure> {
    await withCheckedContinuation { continuation in
      let ctx = Unmanaged.passRetained(Box(continuation)).toOpaque()
      spec.withTermConnect(cols: 0, rows: 0) { c in
        term_exec(c, command, ctx) { ctx, status, out, len, error in
          let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
          if let error {
            box.continuation.resume(returning: .failure(Failure(message: String(cString: error))))
          } else {
            let data = out.map { Data(bytes: $0, count: len) } ?? Data()
            box.continuation.resume(returning: .success(Output(status: status, stdout: data)))
          }
        }
      }
    }
  }
}
