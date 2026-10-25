import CryptoKit
import Foundation

/// Key generation and parsing live in the core; these wrap the C calls.
enum SSHKeys {
  struct Generated: Sendable {
    var privateKey: String
    var publicKey: String
  }

  static func generate(comment: String) -> Generated? {
    var pubOut: UnsafeMutablePointer<CChar>?
    guard let priv = term_key_generate(comment, &pubOut) else { return nil }
    defer {
      term_string_free(priv)
      if let pubOut { term_string_free(pubOut) }
    }
    guard let pubOut else { return nil }
    return Generated(privateKey: String(cString: priv), publicKey: String(cString: pubOut))
  }

  /// Public line for an OpenSSH private key, nil when the core cannot parse it.
  static func publicKey(for privateKey: String) -> String? {
    guard let pub = term_key_public(privateKey) else { return nil }
    defer { term_string_free(pub) }
    return String(cString: pub)
  }

  /// OpenSSH-style fingerprint ("SHA256:...") of a public line such as
  /// "ssh-ed25519 AAAA... comment"; nil when the line has no base64 blob.
  static func fingerprint(_ publicLine: String) -> String? {
    let parts = publicLine.split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
  }
}
