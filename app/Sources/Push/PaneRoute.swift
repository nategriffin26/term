import CryptoKit
import Foundation

/// What a push from the relay names (relay/src/contract.ts, PushPayload.term):
/// the pairing it came through and an opaque reference to one pane. The
/// phone alone turns these back into a host, session and pane.
struct PushRoute: Equatable, Sendable {
  enum Kind: String, Sendable {
    case ask, approval, done, error
  }

  var pairingID: String
  var sessionRef: String
  var kind: Kind

  init(pairingID: String, sessionRef: String, kind: Kind) {
    self.pairingID = pairingID
    self.sessionRef = sessionRef
    self.kind = kind
  }

  /// The `term` object of a notification's payload; nil for anything else.
  init?(userInfo: [AnyHashable: Any]) {
    guard let term = userInfo["term"] as? [String: Any],
          let pairing = term["pairing_id"] as? String, Hex.isDigest(pairing),
          let ref = term["session_ref"] as? String, Hex.isDigest(ref),
          let kind = (term["kind"] as? String).flatMap(Kind.init(rawValue:))
    else { return nil }
    self.init(pairingID: pairing, sessionRef: ref, kind: kind)
  }
}

/// A tmux pane as term-notify names it: the session and pane, and the
/// server generation (start time and pid) so a pane id reused after the
/// server restarts never matches an older push.
struct TmuxPane: Equatable, Sendable {
  var session: String
  var pane: String
  var serverStart: String
  var serverPID: String
}

enum PaneRoute {
  /// list-panes fields, tab-separated; the session name goes last so a tab in it stays in it.
  static let fields = ["pane_id", "start_time", "pid", "session_name"]

  /// Every pane on the host's default tmux server. `-u` makes tmux print
  /// session names as UTF-8 whatever the host's locale, as term-notify reads them.
  static var listCommand: String {
    let format = fields.map { "#{\($0)}" }.joined(separator: "\t")
    return "\(Tmux.path); tmux -u list-panes -a -F \(Command.shellQuote(format)) 2>&1"
  }

  static func parse(_ output: Data) -> [TmuxPane] {
    String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
      let f = line.split(separator: "\t", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
      guard f.count == fields.count, f[0].hasPrefix("%"), !f[1].isEmpty, !f[2].isEmpty else { return nil }
      return TmuxPane(session: f[3], pane: f[0], serverStart: f[1], serverPID: f[2])
    }
  }

  /// HMAC-SHA256(routing key, session NUL pane NUL server start NUL server pid), lowercase hex.
  static func reference(_ pane: TmuxPane, routingKey: SymmetricKey) -> String {
    let message = [pane.session, pane.pane, pane.serverStart, pane.serverPID].joined(separator: "\0")
    return Hex.string(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: routingKey))
  }

  /// The pane `ref` names, or nil when none on the server does.
  static func pane(_ ref: String, in panes: [TmuxPane], routingKey: SymmetricKey) -> TmuxPane? {
    panes.first { reference($0, routingKey: routingKey) == ref }
  }

  /// Exit status of the commands below when the pane is not the one routed:
  /// gone, moved to another session, or a reused id on a restarted server.
  static let goneStatus: Int32 = 3

  /// Makes `pane` the current window's active pane of its session, so every
  /// client on the session (an open tab) shows it. Fails with `goneStatus`,
  /// changing nothing, unless the pane is still in that session on the same
  /// server generation.
  static func selectCommand(_ pane: TmuxPane) -> String {
    "\(Tmux.path); \(verify(pane)); { \(select(pane)); } 2>&1"
  }

  /// A new tab's first command for a push: verifies the pane as
  /// `selectCommand` does, selects it, then attaches to its session, never
  /// creating one (`attach-session -t =name`). The check runs at connection
  /// time rather than relying on the earlier SSH resolution.
  static func attachCommand(_ pane: TmuxPane) -> String {
    let client = "sh -c \(Command.shellQuote(Tmux.clientScript)) tmux attach-session -t \(Command.shellQuote("=" + pane.session))"
    let script = "\(Tmux.path); \(verify(pane)); \(select(pane)) || exit \(goneStatus); exec \(client)"
    return "sh -c \(Command.shellQuote(script))"
  }

  /// Exits `goneStatus` unless `pane` is in its session on its server generation.
  private static func verify(_ pane: TmuxPane) -> String {
    let format = Command.shellQuote("#{start_time}\t#{pid}\t#{session_name}")
    let expected = Command.shellQuote("\(pane.serverStart)\t\(pane.serverPID)\t\(pane.session)")
    return "[ \"$(tmux -u display-message -p -t \(Command.shellQuote(pane.pane)) \(format) 2>/dev/null)\" = \(expected) ]"
      + " || { echo 'That agent’s pane has closed.'; exit \(goneStatus); }"
  }

  private static func select(_ pane: TmuxPane) -> String {
    let target = Command.shellQuote(pane.pane)
    return "tmux select-window -t \(target) && tmux select-pane -t \(target)"
  }
}

enum Hex {
  static func string<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// `count` random bytes, lowercase hex.
  static func random(bytes count: Int = 32) -> String {
    var generator = SystemRandomNumberGenerator()
    return string((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }

  static func data(_ hex: String) -> Data? {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    return data
  }

  /// 64 lowercase hex digits: a SHA-256 digest or 32-byte secret.
  static func isDigest(_ s: String) -> Bool {
    s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func sha256(_ hex: String) -> String {
    string(SHA256.hash(data: Data(hex.utf8)))
  }
}
