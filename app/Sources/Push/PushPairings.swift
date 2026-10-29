import Foundation
import Observation

/// This iPhone as the relay knows it. The secret manages the device and its
/// pairings; it stays on the phone. The APNs token is not kept: each launch's
/// token goes straight to the relay, the only place it is held.
struct PushDevice: Codable, Equatable, Sendable {
  var id: String
  var secret: String
}

/// One host paired with this phone. The host holds the secret (to send) and
/// the routing key (to name panes); the relay sees only the secret.
struct HostPairing: Codable, Equatable, Sendable {
  var hostID: UUID
  var pairingID: String
  var secret: String
  var routingKey: String
  var relayURL: String

  /// The host's file, `~/.config/term/notify/<pairing_id>.json` (contract HostPairing).
  var hostFile: Data {
    struct File: Encodable {
      var version = 1
      var relay_url: String
      var secret: String
      var routing_key: String
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(File(relay_url: relayURL, secret: secret, routing_key: routingKey))) ?? Data()
  }
}

/// How the phone gets its APNs token: PushNotifications, or a test's.
@MainActor
protocol PushRegistrar: AnyObject {
  /// Asks for permission to show notifications; false when he declined.
  func authorize() async -> Bool
  /// The APNs device token, lowercase hex.
  func token() async throws(PushPairings.Failure) -> String
  /// "sandbox" or "production": the APNs environment the token belongs to.
  var environment: String { get }
  func unregister()
}

/// Writes and removes the pairing file on a host: SSHNotifyFiles, or a test's.
protocol NotifyFiles: Sendable {
  func write(_ pairing: HostPairing, to spec: ConnectSpec) async throws(PushPairings.Failure)
  func remove(pairingID: String, from spec: ConnectSpec) async
}

/// Notifications' state: whether this iPhone is registered with the relay,
/// and which hosts are paired. Every secret lives in the Keychain.
@MainActor @Observable
final class PushPairings {
  static let shared = PushPairings(service: AppIdentity.bundleID + ".push",
                                   relay: RelayConfig.url.map { RelayClient(base: $0) },
                                   registrar: PushNotifications.shared, files: SSHNotifyFiles())

  enum Failure: Error, Equatable {
    case noRelay
    case notificationsDenied
    case registration(String)
    case relay(RelayClient.Failure)
    case hostKeyNotPinned(String)
    case host(String, String)
    case keychain

    var message: String {
      switch self {
      case .noRelay: "This build has no relay. Set TERM_RELAY_URL in app/Config/Local.xcconfig and rebuild."
      case .notificationsDenied: "Notifications are off for Term. Allow them in iOS Settings › Notifications › Term."
      case .registration(let why): "Apple's push service didn't register this iPhone: \(why)"
      case .relay(let failure): failure.message
      case .hostKeyNotPinned(let alias): "Connect to \(alias) once so Term knows its host key, then pair it."
      case .host(let alias, let why): "Couldn't write the pairing to \(alias): \(why)"
      case .keychain: "The Keychain didn't save the pairing. Try again."
      }
    }
  }

  private(set) var device: PushDevice?
  private(set) var pairings: [UUID: HostPairing]

  @ObservationIgnored private let service: String
  @ObservationIgnored let relay: RelayClient?
  @ObservationIgnored private let registrar: PushRegistrar
  @ObservationIgnored private let files: NotifyFiles
  @ObservationIgnored private let spec: @MainActor (Host) -> ConnectSpec
  private static let deviceAccount = "device"

  init(service: String, relay: RelayClient?, registrar: PushRegistrar, files: NotifyFiles,
       spec: @escaping @MainActor (Host) -> ConnectSpec = Tab.spec(for:)) {
    self.service = service
    self.relay = relay
    self.registrar = registrar
    self.files = files
    self.spec = spec
    let items = Keychain.items(service: service)
    let decoder = JSONDecoder()
    device = items[Self.deviceAccount].flatMap { try? decoder.decode(PushDevice.self, from: $0) }
    pairings = [:]
    for (account, data) in items where account != Self.deviceAccount {
      if let pairing = try? decoder.decode(HostPairing.self, from: data) { pairings[pairing.hostID] = pairing }
    }
  }

  var isOn: Bool { device != nil }

  func pairing(for host: Host) -> HostPairing? { pairings[host.id] }

  func pairing(id: String) -> HostPairing? { pairings.values.first { $0.pairingID == id } }

  /// Registers this iPhone with the relay under a new device id and secret.
  /// The secret is in the Keychain before the relay hears of it. A refusal
  /// the relay answered (a redirect or 4xx) stored nothing and is undone; any other failure
  /// (no answer, a lost answer, a server error) may have registered it, so the
  /// device stays: notifications read as on with the error shown, the next
  /// launch registers it again, and Off can delete it.
  func turnOn() async throws(Failure) {
    guard let relay else { throw .noRelay }
    guard device == nil else { return }
    guard await registrar.authorize() else { throw .notificationsDenied }
    let token = try await registrar.token()
    let fresh = PushDevice(id: UUID().uuidString.lowercased(), secret: Hex.random())
    guard save(fresh, account: Self.deviceAccount) else { throw .keychain }
    do throws(RelayClient.Failure) {
      try await relay.registerDevice(RelayClient.Device(device_id: fresh.id, device_secret: fresh.secret,
                                                        token: token, environment: registrar.environment))
    } catch {
      if Self.refused(error) { erase(account: Self.deviceAccount) } else { device = fresh }
      throw .relay(error)
    }
    device = fresh
  }

  /// The relay answered and stored nothing.
  private static func refused(_ failure: RelayClient.Failure) -> Bool {
    switch failure {
    case .deviceUnknown, .rateLimited: true
    case .rejected(let status): (300..<500).contains(status)
    case .unreachable, .malformed: false
    }
  }

  /// The relay forgets this iPhone and its pairings; the hosts' files go too.
  func turnOff() async throws(Failure) {
    guard let device else { return }
    if let relay {
      do throws(RelayClient.Failure) {
        try await relay.deleteDevice(id: device.id, secret: device.secret)
      } catch {
        throw .relay(error)
      }
    }
    registrar.unregister()
    await forgetAll()
  }

  /// Pairs an unpaired `host`: a new secret and routing key, kept in the
  /// Keychain first, then registered with the relay and written to the host
  /// over SSH with its pinned key. A failure takes the pairing back through
  /// `unpair`; when that cannot reach the relay the pairing stays, and the
  /// host shows Unpair, so no live secret is ever left without a way to revoke it.
  func pair(_ host: Host) async throws(Failure) {
    guard let relay else { throw .noRelay }
    guard pairings[host.id] == nil else { return }
    if device == nil { try await turnOn() }
    guard let device else { return }
    let connection = spec(host)
    guard connection.hostKey != nil else { throw .hostKeyNotPinned(host.alias) }
    let secret = Hex.random()
    let pairing = HostPairing(hostID: host.id, pairingID: Hex.sha256(secret), secret: secret,
                              routingKey: Hex.random(), relayURL: relay.base.absoluteString)
    guard remember(pairing) else { throw .keychain }
    do throws(RelayClient.Failure) {
      _ = try await relay.pair(deviceID: device.id, deviceSecret: device.secret, secret: secret)
    } catch {
      if error == .deviceUnknown { await forgetAll() } else { try? await unpair(host) }
      throw .relay(error)
    }
    do throws(Failure) {
      try await files.write(pairing, to: connection)
    } catch {
      try? await unpair(host)
      throw error
    }
  }

  /// Keeps a pairing in the Keychain and here. False when the Keychain
  /// refused it, and nothing changed.
  func remember(_ pairing: HostPairing) -> Bool {
    guard save(pairing, account: Self.account(pairing.hostID)) else { return false }
    pairings[pairing.hostID] = pairing
    return true
  }

  /// Revokes `host`'s pairing at the relay, then removes its file from the host.
  func unpair(_ host: Host) async throws(Failure) {
    guard let pairing = pairings[host.id] else { return }
    if let relay, let device {
      do throws(RelayClient.Failure) {
        try await relay.unpair(deviceID: device.id, deviceSecret: device.secret, secret: pairing.secret)
      } catch {
        if error == .deviceUnknown { return await forgetAll() }
        throw .relay(error)
      }
    }
    await files.remove(pairingID: pairing.pairingID, from: spec(host))
    erase(account: Self.account(host.id))
    pairings[host.id] = nil
  }

  /// APNs gave a token (each launch while on, the same or a new one): the
  /// device is registered again, which hands the relay the current token and
  /// renews its 90-day lease, and with it the pairings'. A relay that no
  /// longer knows this device has dropped its pairings.
  func renew(token: String) async {
    guard let relay, let device else { return }
    do throws(RelayClient.Failure) {
      try await relay.registerDevice(RelayClient.Device(device_id: device.id, device_secret: device.secret,
                                                        token: token, environment: registrar.environment))
    } catch {
      if error == .deviceUnknown { await forgetAll() }
      DiagnosticLog.record(.notification, "device-renew-failed", "reason=\(error)")
    }
  }

  /// Drops the device and every pairing here, and the files on hosts that answer.
  private func forgetAll() async {
    let gone = pairings.values
    erase(account: Self.deviceAccount)
    for pairing in gone { erase(account: Self.account(pairing.hostID)) }
    device = nil
    pairings = [:]
    let hosts = ConfigStore.shared.hosts
    for pairing in gone {
      guard let host = hosts.first(where: { $0.id == pairing.hostID }) else { continue }
      await files.remove(pairingID: pairing.pairingID, from: spec(host))
    }
  }

  private static func account(_ host: UUID) -> String { "host-" + host.uuidString }

  private func save(_ value: some Encodable, account: String) -> Bool {
    guard let data = try? JSONEncoder().encode(value) else { return false }
    return Keychain.setItem(data, service: service, account: account)
  }

  private func erase(account: String) {
    Keychain.setItem(nil, service: service, account: account)
  }
}

/// The pairing file over the host's SSH connection: the folder made private
/// first, the file uploaded into it (SFTP, so the secret never sits in a
/// command line) and then made owner-only.
struct SSHNotifyFiles: NotifyFiles {
  static let directory = ".config/term/notify"

  static var prepareCommand: String {
    #"umask 077; d="$HOME/\#(directory)"; mkdir -p "$d" && [ -d "$d" ] && [ ! -L "$d" ] && chmod 700 "$d" 2>&1"#
  }

  static func path(_ pairingID: String) -> String { "~/\(directory)/\(pairingID).json" }

  static func finishCommand(_ pairingID: String) -> String {
    #"chmod 600 "$HOME/\#(directory)/\#(pairingID).json" 2>&1"#
  }

  static func removeCommand(_ pairingID: String) -> String {
    #"rm -f "$HOME/\#(directory)/\#(pairingID).json""#
  }

  func write(_ pairing: HostPairing, to spec: ConnectSpec) async throws(PushPairings.Failure) {
    guard Hex.isDigest(pairing.pairingID) else { throw .host(spec.label, "bad pairing id") }
    let fs = RemoteFS(spec: spec)
    let local = URL.temporaryDirectory.appending(path: "pairing-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: local) }
    do {
      let prepared = try await fs.exec(Self.prepareCommand)
      guard prepared.status == 0 else {
        throw RemoteFSError.failed(Self.output(prepared.stdout, or: "~/\(Self.directory) is not a private folder"))
      }
      try pairing.hostFile.write(to: local, options: [.atomic, .completeFileProtection])
      try await fs.upload(local, to: Self.path(pairing.pairingID), ifMtime: nil) { _ in }
      let finished = try await fs.exec(Self.finishCommand(pairing.pairingID))
      guard finished.status == 0 else { throw RemoteFSError.failed(Self.output(finished.stdout, or: "chmod failed")) }
    } catch let error as RemoteFSError {
      throw .host(spec.label, error.message)
    } catch {
      throw .host(spec.label, error.localizedDescription)
    }
  }

  func remove(pairingID: String, from spec: ConnectSpec) async {
    guard Hex.isDigest(pairingID) else { return }
    _ = await RemoteExec.run(spec, Self.removeCommand(pairingID))
  }

  private static func output(_ data: Data, or fallback: String) -> String {
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? fallback : text
  }
}
