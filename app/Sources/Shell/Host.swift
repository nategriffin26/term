import Foundation

/// A saved connection target (Blink's host record).
struct Host: Codable, Identifiable, Hashable, Sendable {
  enum Transport: String, Codable, CaseIterable, Sendable {
    case mosh, ssh
  }

  enum Prediction: String, Codable, CaseIterable, Sendable {
    case adaptive, always, never
  }

  var id = UUID()
  var alias: String
  var hostname: String
  var port = 22
  var user: String
  /// Name of an SSH key in the Keychain; nil = use the password, or the first key.
  var keyName: String?
  var transport = Transport.mosh
  /// Empty = "mosh-server" on the remote PATH.
  var moshServer = ""
  /// Runs instead of the login shell, e.g. `tmux new -A -s main`.
  var startupCommand = ""
  var prediction = Prediction.adaptive

  /// Key under which the server's host key is pinned in `Config.knownHosts`.
  var knownHostsKey: String { "\(hostname):\(port)" }
}

extension Host {
  /// Fields with a default may be missing (a file written before the field
  /// existed), so adding a field never makes saved hosts unreadable. Declared
  /// in an extension so the memberwise initializer stays.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    alias = try c.decode(String.self, forKey: .alias)
    hostname = try c.decode(String.self, forKey: .hostname)
    user = try c.decode(String.self, forKey: .user)
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
    keyName = try c.decodeIfPresent(String.self, forKey: .keyName)
    transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .mosh
    moshServer = try c.decodeIfPresent(String.self, forKey: .moshServer) ?? ""
    startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
    prediction = try c.decodeIfPresent(Prediction.self, forKey: .prediction) ?? .adaptive
  }
}

/// Everything the core needs to open a remote session or run a command,
/// with secrets already read from the Keychain.
struct ConnectSpec: Sendable, Equatable {
  var transport: Host.Transport
  var hostname: String
  var port: Int
  var user: String
  var privateKey: String?
  var password: String?
  var hostKey: String?
  var command: String?
  var moshServer: String?
  var prediction: Host.Prediction
  /// Alias shown to the user ("mac"), or hostname for ad-hoc targets.
  var label: String

  var knownHostsKey: String { "\(hostname):\(port)" }

  /// Calls `body` with a TermConnect whose strings live for the call.
  func withTermConnect<R>(cols: Int, rows: Int, _ body: (UnsafePointer<TermConnect>) -> R) -> R {
    withOptionalCString(hostname) { host in
      withOptionalCString(user) { user in
        withOptionalCString(privateKey) { key in
          withOptionalCString(password) { password in
            withOptionalCString(hostKey) { hostKey in
              withOptionalCString(command) { command in
                withOptionalCString(moshServer) { server in
                  var c = TermConnect(
                    transport: transport == .mosh ? UInt32(TERM_TRANSPORT_MOSH.rawValue) : UInt32(TERM_TRANSPORT_SSH.rawValue),
                    host: host, port: UInt16(clamping: port),
                    cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
                    user: user, private_key: key, password: password, host_key: hostKey,
                    command: command, mosh_server: server,
                    predict: prediction.termValue,
                    idle_timeout: idleTimeout)
                  return withUnsafePointer(to: &c) { body($0) }
                }
              }
            }
          }
        }
      }
    }
  }

  /// Whether the remote command runs tmux, so the session outlives its connection.
  var runsInTmux: Bool {
    guard let command, case .success(let words) = Command.tokenize(command), let first = words.first else { return false }
    return (first as NSString).lastPathComponent == "tmux"
  }

  /// Seconds mosh-server waits without hearing from this phone before exiting.
  /// Inside tmux nothing is lost when it goes (the session stays and Term
  /// reattaches), so a day; a plain shell's work dies with its server, so a week.
  var idleTimeout: UInt32 { runsInTmux ? 86_400 : 604_800 }
}

extension Host.Prediction {
  var termValue: UInt32 {
    switch self {
    case .adaptive: UInt32(TERM_PREDICT_ADAPTIVE.rawValue)
    case .always: UInt32(TERM_PREDICT_ALWAYS.rawValue)
    case .never: UInt32(TERM_PREDICT_NEVER.rawValue)
    }
  }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
  guard let s, !s.isEmpty else { return body(nil) }
  return s.withCString { body($0) }
}
