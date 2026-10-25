import Foundation

/// tmux is the session store shared with the Mac; the phone lists, attaches
/// and reads history from it over SSH exec.
enum Tmux {
  struct Session: Identifiable, Equatable, Sendable {
    var name: String
    var windows: Int
    /// Number of clients attached right now.
    var attached: Int
    var lastActivity: Date
    var id: String { name }
  }

  enum ListError: Error, Equatable {
    case notInstalled
    case failed(status: Int32, output: String)
  }

  static let listCommand = "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}'"

  static func attachCommand(_ name: String) -> String {
    "tmux new -A -s \(Command.shellQuote(name))"
  }

  /// Scrollback plus screen of the session's active pane, with colors, wrapped
  /// lines joined so they rewrap at the phone's width.
  static func historyCommand(_ name: String?, lines: Int = 3000) -> String {
    var cmd = "tmux capture-pane -p -e -J -S -\(lines)"
    if let name { cmd += " -t \(Command.shellQuote(name))" }
    return cmd
  }

  /// Sessions from `listCommand`, most recently active first. tmux exits 1
  /// with "no server running" when there are no sessions at all.
  static func parseList(status: Int32, output: Data) -> Result<[Session], ListError> {
    let text = String(decoding: output, as: UTF8.self)
    if status == 127 { return .failure(.notInstalled) }
    if status != 0 {
      if text.contains("no server running") || text.contains("error connecting") || text.isEmpty {
        return .success([])
      }
      return .failure(.failed(status: status, output: text))
    }
    let sessions = text.split(whereSeparator: \.isNewline).compactMap { line -> Session? in
      let f = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard f.count == 4, let windows = Int(f[1]), let attached = Int(f[2]),
            let activity = TimeInterval(f[3]) else { return nil }
      return Session(name: String(f[0]), windows: windows, attached: attached,
                     lastActivity: Date(timeIntervalSince1970: activity))
    }
    return .success(sessions.sorted { $0.lastActivity > $1.lastActivity })
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
