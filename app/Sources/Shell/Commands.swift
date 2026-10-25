import Foundation

/// The local prompt's command language (Blink's built-ins).
enum Command: Equatable {
  case empty
  case help
  case clear
  case hosts
  case config
  case exit
  case testpage
  case connect(ConnectRequest)
  /// `tmux <host> [session]`: pick a tmux session on the host, or attach one.
  case tmux(host: String, session: String?)

  static let names = ["help", "clear", "hosts", "config", "exit", "mosh", "ssh", "tmux"]

  enum ParseError: Error, Equatable {
    case unknown(String)
    case usage(String)
    case unterminatedQuote
  }

  static let moshUsage = "usage: mosh [-P port] [-i key] [-a|-n] [--server=path] [user@]host [--] [command]"
  static let sshUsage = "usage: ssh [-p port] [-i key] [-l user] [user@]host [command]"
  static let tmuxUsage = "usage: tmux host [session]"

  static func parse(_ line: String) -> Result<Command, ParseError> {
    let words: [String]
    switch tokenize(line) {
    case .success(let w): words = w
    case .failure(let e): return .failure(e)
    }
    guard let name = words.first else { return .success(.empty) }
    let args = Array(words.dropFirst())
    switch name {
    case "help": return .success(.help)
    case "clear": return .success(.clear)
    case "hosts": return .success(.hosts)
    case "config": return .success(.config)
    case "exit", "logout": return .success(.exit)
    case "testpage": return .success(.testpage)
    case "mosh": return parseConnect(args, transport: .mosh).map(Command.connect)
    case "ssh": return parseConnect(args, transport: .ssh).map(Command.connect)
    case "tmux":
      guard (1...2).contains(args.count) else { return .failure(.usage(tmuxUsage)) }
      return .success(.tmux(host: args[0], session: args.count == 2 ? args[1] : nil))
    default: return .failure(.unknown(name))
    }
  }

  private static func parseConnect(_ args: [String], transport: Host.Transport) -> Result<ConnectRequest, ParseError> {
    let usage = ParseError.usage(transport == .mosh ? moshUsage : sshUsage)
    var req = ConnectRequest(transport: transport, target: "")
    var i = 0
    func value() -> String? {
      i += 1
      return i < args.count ? args[i] : nil
    }
    while i < args.count, req.target.isEmpty {
      let a = args[i]
      switch (transport, a) {
      case (_, "--"): break
      case (.mosh, "-P"), (.ssh, "-p"):
        guard let v = value(), let p = Int(v), (1...65535).contains(p) else { return .failure(usage) }
        req.port = p
      case (_, "-i"):
        guard let v = value() else { return .failure(usage) }
        req.keyName = v
      case (.ssh, "-l"):
        guard let v = value() else { return .failure(usage) }
        req.user = v
      case (.mosh, "-a"): req.prediction = .always
      case (.mosh, "-n"): req.prediction = .never
      case (.ssh, "-t"), (.ssh, "-tt"), (.ssh, "-v"), (.ssh, "-vv"), (.ssh, "-vvv"): break
      default:
        if transport == .mosh, a.hasPrefix("--predict=") {
          guard let p = Host.Prediction(rawValue: String(a.dropFirst("--predict=".count))) else { return .failure(usage) }
          req.prediction = p
        } else if transport == .mosh, a.hasPrefix("--server=") {
          req.moshServer = String(a.dropFirst("--server=".count))
        } else if a.hasPrefix("-") {
          return .failure(usage)
        } else if let at = a.lastIndex(of: "@") {
          req.user = String(a[..<at])
          req.target = String(a[a.index(after: at)...])
          guard !req.user!.isEmpty, !req.target.isEmpty else { return .failure(usage) }
        } else {
          req.target = a
        }
      }
      i += 1
    }
    guard !req.target.isEmpty else { return .failure(usage) }
    var rest = Array(args[i...])
    if rest.first == "--" { rest.removeFirst() }
    if !rest.isEmpty { req.command = rest.map(shellQuote).joined(separator: " ") }
    return .success(req)
  }

  /// Splits like a POSIX shell: single quotes literal; inside double quotes a
  /// backslash escapes only $ ` " \ and newline (else it stays); outside
  /// quotes a backslash escapes the next character.
  static func tokenize(_ line: String) -> Result<[String], ParseError> {
    var words: [String] = []
    var current = ""
    var inWord = false
    var quote: Character?
    var escaped = false
    for c in line {
      if escaped {
        if quote == "\"", !"$`\"\\\n".contains(c) {
          current.append("\\")
        }
        current.append(c)
        escaped = false
        continue
      }
      if let q = quote {
        if c == q {
          quote = nil
        } else if c == "\\", q == "\"" {
          escaped = true
        } else {
          current.append(c)
        }
        continue
      }
      switch c {
      case "'", "\"":
        quote = c
        inWord = true
      case "\\":
        escaped = true
        inWord = true
      case _ where c.isWhitespace:
        if inWord { words.append(current) }
        current = ""
        inWord = false
      default:
        current.append(c)
        inWord = true
      }
    }
    if quote != nil || escaped { return .failure(.unterminatedQuote) }
    if inWord { words.append(current) }
    return .success(words)
  }

  /// Quotes a word for a remote POSIX shell only when it needs it.
  static func shellQuote(_ word: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_-+=:,./")
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacing("'", with: "'\\''") + "'"
  }

  /// Tab completion: command names first, then host aliases.
  static func complete(_ before: String, aliases: [String]) -> (start: Int, candidates: [String]) {
    let start = before.lastIndex(where: \.isWhitespace).map { before.distance(from: before.startIndex, to: $0) + 1 } ?? 0
    let word = String(before.dropFirst(start))
    let previous = before.prefix(start).split(whereSeparator: \.isWhitespace)
    let pool: [String]
    if previous.isEmpty {
      pool = names
    } else if ["mosh", "ssh", "tmux"].contains(String(previous[0])), previous.count == 1 {
      pool = aliases
    } else {
      return (start, [])
    }
    return (start, pool.filter { $0.hasPrefix(word) }.sorted())
  }
}

/// What `mosh`/`ssh` asked for, before saved hosts and keys fill the rest.
struct ConnectRequest: Equatable {
  var transport: Host.Transport
  /// Host alias or hostname.
  var target: String
  var user: String?
  var port: Int?
  var keyName: String?
  var command: String?
  var prediction: Host.Prediction?
  var moshServer: String?

  enum ResolveError: Error, Equatable {
    case needsUser(String)
  }

  /// The saved host named by the alias with flags applied on top, or an
  /// ad-hoc host when no alias matches (then a user is required).
  func resolve(in hosts: [Host]) -> Result<Host, ResolveError> {
    var host: Host
    if let saved = hosts.first(where: { $0.alias == target }) {
      host = saved
    } else {
      guard let user else { return .failure(.needsUser(target)) }
      host = Host(alias: target, hostname: target, user: user)
    }
    host.transport = transport
    if let user { host.user = user }
    if let port { host.port = port }
    if let keyName { host.keyName = keyName }
    if let command { host.startupCommand = command }
    if let prediction { host.prediction = prediction }
    if let moshServer { host.moshServer = moshServer }
    return .success(host)
  }
}
