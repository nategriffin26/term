import Foundation

/// tmux is the session store shared with the Mac; the phone lists its
/// sessions with a snapshot of each, attaches, manages them and reads
/// history over SSH exec.
enum Tmux {
  struct Session: Identifiable, Equatable, Sendable {
    /// tmux's own id ("$3"): exact as a target and stable across renames.
    var id: String
    var name: String
    var windows: Int
    /// Number of clients attached right now.
    var attached: Int
    var created: Date
    var lastActivity: Date
    /// The active pane of the current window: what runs there and where.
    var command: String
    var path: String
    /// That pane's size and cursor, for its snapshot.
    var width: Int
    var height: Int
    var cursorX: Int
    var cursorY: Int
  }

  /// One refresh of a host: its sessions, most recently active first, and
  /// the screens captured this time (by session id).
  struct Overview: Equatable, Sendable {
    var sessions: [Session]
    var screens: [String: String]
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
  /// stays in it; id and activity go first for the capture loop.
  static let fields = [
    "session_id", "session_activity", "session_windows", "session_attached", "session_created",
    "pane_width", "pane_height", "cursor_x", "cursor_y", "pane_current_command", "pane_current_path",
    "session_name",
  ]

  /// Starts each captured screen in the overview output: ASCII record separator.
  static let screenMark: UInt8 = 0x1E

  /// One exec per refresh: the session list, then the visible screen of each
  /// session's active pane, except sessions in `skip` (id → activity) whose
  /// activity has not moved since their last capture.
  static func overviewCommand(skip: [String: Date] = [:]) -> String {
    let format = fields.map { "#{\($0)}" }.joined(separator: "\t")
    let known = skip.sorted { $0.key < $1.key }.map { "\($0.key):\(Int($0.value.timeIntervalSince1970))" }
    return [
      path,
      "l=$(tmux list-sessions -F '\(format)' 2>&1)",
      "s=$?",
      #"printf '%s\n' "$l""#,
      "[ $s = 0 ] || exit $s",
      #"printf '%s\n' "$l" | while IFS='\#t' read -r i a r; do case ' \#(known.joined(separator: " ")) ' in *" $i:$a "*) ;; *) printf '\036%s\n' "$i"; tmux capture-pane -p -e -J -t "$i";; esac; done"#,
    ].joined(separator: "; ")
  }

  static func parseOverview(status: Int32, output: Data) -> Result<Overview, ListError> {
    let parts = output.split(separator: screenMark, omittingEmptySubsequences: false)
    let list = String(decoding: parts.first ?? Data(), as: UTF8.self)
    if status == 127 { return .failure(.notInstalled) }
    if status != 0 {
      if list.contains("no server running") || list.contains("error connecting") {
        return .failure(.notRunning)
      }
      return .failure(.failed(status: status, output: list.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    let sessions = list.split(whereSeparator: \.isNewline).compactMap(parseSession)
    var screens: [String: String] = [:]
    for part in parts.dropFirst() {
      let text = String(decoding: part, as: UTF8.self)
      guard let newline = text.firstIndex(of: "\n") else { continue }
      var screen = text[text.index(after: newline)...]
      if screen.hasSuffix("\n") { screen = screen.dropLast() }
      screens[String(text[..<newline])] = String(screen)
    }
    return .success(Overview(sessions: sessions.sorted { $0.lastActivity > $1.lastActivity }, screens: screens))
  }

  private static func parseSession(_ line: Substring) -> Session? {
    let f = line.split(separator: "\t", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
    guard f.count == fields.count, f[0].hasPrefix("$"),
          let activity = TimeInterval(f[1]), let windows = Int(f[2]), let attached = Int(f[3]),
          let created = TimeInterval(f[4]), let width = Int(f[5]), let height = Int(f[6]),
          let cx = Int(f[7]), let cy = Int(f[8]) else { return nil }
    return Session(id: f[0], name: f[11], windows: windows, attached: attached,
                   created: Date(timeIntervalSince1970: created), lastActivity: Date(timeIntervalSince1970: activity),
                   command: f[9], path: f[10], width: width, height: height, cursorX: cx, cursorY: cy)
  }

  /// What a terminal engine is fed to show a captured screen as it was:
  /// cleared, rows from the top, the cursor where the pane had it.
  static func screenBytes(_ screen: String, cursorX: Int, cursorY: Int) -> Data {
    let rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
    return Data(("\u{1b}[0m\u{1b}[H\u{1b}[2J" + rows.joined(separator: "\u{1b}[0m\r\n")
      + "\u{1b}[0m\u{1b}[\(cursorY + 1);\(cursorX + 1)H").utf8)
  }

  // MARK: - Actions

  static func attachCommand(_ name: String) -> String {
    "tmux new -A -s \(Command.shellQuote(name))"
  }

  /// A detached session in `folder` (a missing folder fails instead of
  /// falling back to home); prints the name tmux gave it, which attach uses.
  static func newCommand(name: String, folder: String) -> String {
    let dir = folder.trimmingCharacters(in: .whitespaces)
    let named = name.isEmpty ? "" : " -s \(Command.shellQuote(name))"
    return "cd \(shellPath(dir.isEmpty ? "~" : dir)) 2>/dev/null || { echo 'No such folder'; exit 2; }; \(path); "
      + #"tmux new -d -P -F '#{session_name}'\#(named) -c "$PWD" 2>&1"#
  }

  static func renameCommand(id: String, to name: String) -> String {
    "\(path); tmux rename-session -t \(Command.shellQuote(id)) \(Command.shellQuote(name)) 2>&1"
  }

  static func killCommand(id: String) -> String {
    "\(path); tmux kill-session -t \(Command.shellQuote(id)) 2>&1"
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

  /// tmux turns "." and ":" in session names into "_"; the phone does the
  /// same up front so the name it attaches to is the name tmux keeps.
  static func cleanName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespaces).replacing(/[.:]/, with: "_")
  }

  /// A folder for a remote shell: "~" and "~/…" stay expandable, the rest is quoted.
  static func shellPath(_ dir: String) -> String {
    if dir == "~" { return "~" }
    if dir.hasPrefix("~/") { return "~/" + Command.shellQuote(String(dir.dropFirst(2))) }
    return Command.shellQuote(dir)
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
