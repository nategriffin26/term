import Foundation
import Observation

/// Hosts and pinned host keys, saved as JSON in Application Support.
struct Config: Codable, Equatable, Sendable {
  var hosts: [Host] = []
  /// "hostname:port" -> "ssh-ed25519 AAAA..." pinned on first connect.
  var knownHosts: [String: String] = [:]
}

@MainActor @Observable
final class ConfigStore {
  static let shared = ConfigStore(url: AppDirectories.support.appending(path: "config.json"))

  private(set) var config: Config
  @ObservationIgnored let url: URL

  init(url: URL) {
    self.url = url
    config = Self.load(url)
  }

  var hosts: [Host] { config.hosts }

  func host(alias: String) -> Host? {
    config.hosts.first { $0.alias == alias }
  }

  /// Inserts or replaces by id.
  func save(_ host: Host) {
    if let i = config.hosts.firstIndex(where: { $0.id == host.id }) {
      config.hosts[i] = host
    } else {
      config.hosts.append(host)
    }
    write()
  }

  func delete(_ host: Host) {
    config.hosts.removeAll { $0.id == host.id }
    Keychain.setPassword(nil, for: host.id)
    write()
  }

  func moveHosts(from: IndexSet, to: Int) {
    config.hosts.move(fromOffsets: from, toOffset: to)
    write()
  }

  func hostKey(for knownHostsKey: String) -> String? {
    config.knownHosts[knownHostsKey]
  }

  func pinHostKey(_ key: String?, for knownHostsKey: String) {
    config.knownHosts[knownHostsKey] = key
    write()
  }

  private func write() {
    do {
      let data = try JSONEncoder.pretty.encode(config)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      assertionFailure("config write failed: \(error)")
    }
  }

  /// A file that exists but cannot be decoded is moved aside, never overwritten.
  private static func load(_ url: URL) -> Config {
    guard let data = try? Data(contentsOf: url) else { return Config() }
    do {
      return try JSONDecoder().decode(Config.self, from: data)
    } catch {
      let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
      try? FileManager.default.removeItem(at: aside)
      try? FileManager.default.moveItem(at: url, to: aside)
      return Config()
    }
  }
}

enum AppDirectories {
  /// Application Support, created on first use.
  static let support: URL = {
    let url = URL.applicationSupportDirectory
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  /// Saved mosh session state, one file per tab.
  static let sessions: URL = make("sessions")

  private static func make(_ name: String) -> URL {
    let url = support.appending(path: name, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

extension JSONEncoder {
  static var pretty: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }
}
