import XCTest
@testable import Term

/// Turning notifications on and off, pairing and unpairing, against a local
/// stand-in for the relay answering with the Worker's statuses, a registrar
/// in place of APNs, and host files that can fail. Secrets go to the real
/// Keychain under a service of the test's own.
@MainActor
final class PushPairingsTests: XCTestCase {
  private final class Registrar: PushRegistrar {
    var allowed = true
    var tokenFailure: PushPairings.Failure?
    var unregistered = false
    var environment = "sandbox"
    func authorize() async -> Bool { allowed }
    func token() async throws(PushPairings.Failure) -> String {
      if let tokenFailure { throw tokenFailure }
      return String(repeating: "ab", count: 32)
    }
    func unregister() { unregistered = true }
  }

  private final class Files: NotifyFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var _written: [HostPairing] = []
    private var _removed: [String] = []
    var failure: PushPairings.Failure?
    var written: [HostPairing] { lock.withLock { _written } }
    var removed: [String] { lock.withLock { _removed } }
    func write(_ pairing: HostPairing, to spec: ConnectSpec) async throws(PushPairings.Failure) {
      if let failure { throw failure }
      lock.withLock { _written.append(pairing) }
    }
    func remove(pairingID: String, from spec: ConnectSpec) async { lock.withLock { _removed.append(pairingID) } }
  }

  /// The Worker's answers (relay agent): 200 {registered:true} for a device,
  /// 201/200 with the pairing id, 204 for deletes, 401 for a device secret it refuses.
  private final class Relay: @unchecked Sendable {
    let lock = NSLock()
    var refuseDevice = false
    var pairingID: (@Sendable (String) -> String)?
    /// Replaces the answer to POST /devices.
    var deviceReply: RelayStub.Reply?
    /// Replaces the answer to DELETE /pairings.
    var revokeReply: RelayStub.Reply?
    /// Stores each POST /devices, then closes without answering.
    var loseDeviceAnswer = false
    /// Sees each POST /devices before it is answered.
    var onDevice: (@Sendable (RelayStub.Request) -> Void)?
    func answer(_ request: RelayStub.Request) -> RelayStub.Reply? {
      lock.withLock {
        if refuseDevice, request.authorization != nil || request.body["device_secret"] != nil {
          return RelayStub.Reply(status: 401, body: #"{"error":"unauthorized"}"#)
        }
        switch (request.method, request.path) {
        case ("POST", "/devices"):
          onDevice?(request)
          if loseDeviceAnswer { return nil }
          return deviceReply ?? RelayStub.Reply(status: 200, body: #"{"registered":true}"#)
        case ("DELETE", "/pairings"): return revokeReply ?? RelayStub.Reply(status: 204)
        case ("DELETE", "/devices"): return RelayStub.Reply(status: 204)
        case ("POST", "/pairings"):
          let secret = request.body["secret"] as? String ?? ""
          return RelayStub.Reply(status: 201, body: #"{"pairing_id":"\#(pairingID?(secret) ?? Hex.sha256(secret))"}"#)
        default: return RelayStub.Reply(status: 404)
        }
      }
    }
  }

  private var stub: RelayStub!
  private let relay = Relay()
  private let registrar = Registrar()
  private let files = Files()
  private var service = ""
  private var pinned: String? = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
  private let host = Host(alias: "mac", hostname: "mac.local", user: "user")

  override func setUp() async throws {
    service = "push-tests-" + UUID().uuidString
    let relay = relay
    stub = try await RelayStub { relay.answer($0) }
  }

  override func tearDown() async throws {
    stub.stop()
    for account in Keychain.items(service: service).keys { Keychain.setItem(nil, service: service, account: account) }
  }

  private func pairings() -> PushPairings {
    PushPairings(service: service, relay: RelayClient(base: stub.baseURL), registrar: registrar, files: files,
                 spec: { [unowned self] host in
                   var spec = ConnectSpec(transport: .ssh, hostname: host.hostname, port: host.port, user: host.user,
                                          prediction: .adaptive, label: host.alias)
                   spec.hostKey = pinned
                   return spec
                 })
  }

  private func failure(_ body: () async throws(PushPairings.Failure) -> Void) async -> PushPairings.Failure? {
    do { try await body() } catch { return error }
    return nil
  }

  func testTurningOnRegistersAndKeepsTheDeviceInTheKeychain() async throws {
    let store = pairings()
    try await store.turnOn()
    let request = try XCTUnwrap(stub.requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/devices")
    XCTAssertEqual(Set(request.body.keys), ["device_id", "device_secret", "token", "environment"])
    XCTAssertEqual(request.body["token"] as? String, String(repeating: "ab", count: 32))
    XCTAssertEqual(request.body["environment"] as? String, "sandbox")
    XCTAssertTrue(Hex.isDigest(request.body["device_secret"] as? String ?? ""))
    XCTAssertNil(request.authorization)
    XCTAssertEqual(pairings().device, store.device, "a relaunch reads it back")
    let stored = try XCTUnwrap(Keychain.items(service: service)["device"])
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), ["id", "secret"], "the APNs token is held by the relay alone")
  }

  func testDeclinedPermissionRegistersNothing() async {
    registrar.allowed = false
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.turnOn() }
    XCTAssertEqual(error, .notificationsDenied)
    XCTAssertTrue(stub.requests.isEmpty)
    XCTAssertFalse(store.isOn)
  }

  func testNoAPNsTokenLeavesNotificationsOff() async {
    registrar.tokenFailure = .registration("no valid aps-environment entitlement")
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.turnOn() }
    XCTAssertEqual(error, .registration("no valid aps-environment entitlement"))
    XCTAssertFalse(store.isOn)
  }

  // The relay sees the pairing secret under the device's bearer; the routing
  // key goes only to the host. A relaunch knows the pairing.
  func testPairingSendsOnlyTheSecretAndWritesTheHost() async throws {
    let store = pairings()
    try await store.pair(host)
    let pairing = try XCTUnwrap(store.pairing(for: host))
    let request = try XCTUnwrap(stub.requests.last)
    XCTAssertEqual(request.path, "/pairings")
    XCTAssertEqual(request.authorization, "Bearer \(store.device?.secret ?? "")")
    XCTAssertEqual(Set(request.body.keys), ["device_id", "secret"])
    XCTAssertEqual(request.body["secret"] as? String, pairing.secret)
    XCTAssertEqual(pairing.pairingID, Hex.sha256(pairing.secret))
    for sent in stub.requests { XCTAssertFalse(sent.raw.contains(pairing.routingKey), "routing key reached the relay") }
    XCTAssertEqual(files.written, [pairing])
    XCTAssertEqual(pairings().pairing(id: pairing.pairingID), pairing)
  }

  func testUnpinnedHostIsNotPaired() async {
    pinned = nil
    let store = pairings()
    try? await store.turnOn()
    let before = stub.requests.count
    let error = await failure { () async throws(PushPairings.Failure) in try await store.pair(host) }
    XCTAssertEqual(error, .hostKeyNotPinned("mac"))
    XCTAssertEqual(stub.requests.count, before)
    XCTAssertNil(store.pairing(for: host))
  }

  // Bug: a host that couldn't take the file left a live secret at the relay.
  func testAFailedHostWriteRevokesTheSecret() async throws {
    files.failure = .host("mac", "Permission denied")
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.pair(host) }
    XCTAssertEqual(error, .host("mac", "Permission denied"))
    let registered = try XCTUnwrap(stub.requests.first { $0.method == "POST" && $0.path == "/pairings" })
    let revoked = try XCTUnwrap(stub.requests.first { $0.method == "DELETE" && $0.path == "/pairings" })
    XCTAssertEqual(revoked.body["secret"] as? String, registered.body["secret"] as? String)
    XCTAssertNil(store.pairing(for: host))
    XCTAssertTrue(pairings().pairings.isEmpty)
  }

  // Bug: when the host write failed and the relay could not take the secret
  // back either, the phone dropped its only record of a live secret.
  func testAPairingThatCannotBeRevokedIsKeptToUnpairLater() async throws {
    files.failure = .host("mac", "chmod failed")
    relay.lock.withLock { relay.revokeReply = RelayStub.Reply(status: 503) }
    let error = await failure { () async throws(PushPairings.Failure) in try await self.pairings().pair(self.host) }
    XCTAssertEqual(error, .host("mac", "chmod failed"))
    let relaunched = pairings()
    let kept = try XCTUnwrap(relaunched.pairing(for: host), "a relaunch no longer knows the secret")

    relay.lock.withLock { relay.revokeReply = nil }
    try await relaunched.unpair(host)
    let revoked = try XCTUnwrap(stub.requests.last)
    XCTAssertEqual("\(revoked.method) \(revoked.path)", "DELETE /pairings")
    XCTAssertEqual(revoked.body["secret"] as? String, kept.secret)
    XCTAssertNil(pairings().pairing(for: host))
  }

  // Pair never replaces a pairing: one he has must be unpaired (and revoked) first.
  func testPairingAPairedHostChangesNothing() async throws {
    let store = pairings()
    try await store.pair(host)
    let pairing = store.pairing(for: host)
    let before = stub.requests.count
    try await store.pair(host)
    XCTAssertEqual(stub.requests.count, before)
    XCTAssertEqual(store.pairing(for: host), pairing)
  }

  // A pairing id that is not SHA-256 of our secret means another relay or a bug: nothing is written.
  func testWrongPairingIDIsRefused() async {
    relay.lock.withLock { relay.pairingID = { _ in String(repeating: "0", count: 64) } }
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.pair(host) }
    XCTAssertEqual(error, .relay(.malformed))
    XCTAssertTrue(files.written.isEmpty)
    XCTAssertNil(store.pairing(for: host))
  }

  // A relay that refuses the device secret has forgotten the device and its pairings.
  func testRefusedDeviceIsForgottenHere() async throws {
    let store = pairings()
    try await store.pair(host)
    relay.lock.withLock { relay.refuseDevice = true }
    let other = Host(alias: "linux", hostname: "box", user: "user")
    let error = await failure { () async throws(PushPairings.Failure) in try await store.pair(other) }
    XCTAssertEqual(error, .relay(.deviceUnknown))
    XCTAssertFalse(store.isOn)
    XCTAssertTrue(store.pairings.isEmpty)
    XCTAssertTrue(Keychain.items(service: service).isEmpty)
  }

  func testUnpairRevokesAndRemovesTheHostFile() async throws {
    let store = pairings()
    try await store.pair(host)
    let pairing = try XCTUnwrap(store.pairing(for: host))
    try await store.unpair(host)
    let revoked = try XCTUnwrap(stub.requests.last)
    XCTAssertEqual(revoked.method, "DELETE")
    XCTAssertEqual(revoked.path, "/pairings")
    XCTAssertEqual(revoked.body["secret"] as? String, pairing.secret)
    XCTAssertEqual(files.removed, [pairing.pairingID])
    XCTAssertNil(pairings().pairing(for: host))
    XCTAssertTrue(store.isOn)
  }

  func testTurningOffForgetsTheDeviceEverywhere() async throws {
    let store = pairings()
    try await store.pair(host)
    let device = try XCTUnwrap(store.device)
    try await store.turnOff()
    let deleted = try XCTUnwrap(stub.requests.last)
    XCTAssertEqual(deleted.method, "DELETE")
    XCTAssertEqual(deleted.path, "/devices")
    XCTAssertEqual(deleted.authorization, "Bearer \(device.secret)")
    XCTAssertEqual(deleted.body as? [String: String], ["device_id": device.id])
    XCTAssertTrue(registrar.unregistered)
    XCTAssertFalse(store.isOn)
    XCTAssertTrue(Keychain.items(service: service).isEmpty)
  }

  // Bug: a relay that cannot be reached left the switch off here while the relay still pushed.
  func testTurningOffWithTheRelayDownKeepsItOn() async throws {
    let store = pairings()
    try await store.turnOn()
    stub.stop()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.turnOff() }
    guard case .relay(.unreachable) = error else { return XCTFail("expected unreachable, got \(String(describing: error))") }
    XCTAssertTrue(store.isOn)
  }

  func testNewTokenReachesTheRelayUnderTheSameDevice() async throws {
    let store = pairings()
    try await store.turnOn()
    let device = try XCTUnwrap(store.device)
    await store.renew(token: String(repeating: "cd", count: 32))
    let update = try XCTUnwrap(stub.requests.last)
    XCTAssertEqual(update.body["device_id"] as? String, device.id)
    XCTAssertEqual(update.body["device_secret"] as? String, device.secret)
    XCTAssertEqual(update.body["token"] as? String, String(repeating: "cd", count: 32))
    XCTAssertEqual(pairings().device, device)
  }

  // Bug: an unchanged token was never sent again, so the relay's 90-day
  // device lease (and the pairings it holds) lapsed while Term kept being opened.
  func testSameTokenStillRenewsTheDevice() async throws {
    let store = pairings()
    try await store.pair(host)
    let device = try XCTUnwrap(store.device)
    let pairing = try XCTUnwrap(store.pairing(for: host))
    let before = stub.requests.count
    await store.renew(token: String(repeating: "ab", count: 32))
    let renewed = Array(stub.requests.dropFirst(before))
    XCTAssertEqual(renewed.map { "\($0.method) \($0.path)" }, ["POST /devices"])
    XCTAssertEqual(renewed.first?.body["device_id"] as? String, device.id)
    XCTAssertEqual(renewed.first?.body["device_secret"] as? String, device.secret)
    XCTAssertEqual(renewed.first?.body["token"] as? String, String(repeating: "ab", count: 32))
    XCTAssertEqual(renewed.first?.body["environment"] as? String, "sandbox")
    XCTAssertEqual(store.pairing(for: host), pairing)
  }

  func testRenewalTheRelayRefusesForgetsTheDevice() async throws {
    let store = pairings()
    try await store.pair(host)
    relay.lock.withLock { relay.refuseDevice = true }
    await store.renew(token: String(repeating: "ab", count: 32))
    XCTAssertFalse(store.isOn)
    XCTAssertTrue(store.pairings.isEmpty)
    XCTAssertTrue(Keychain.items(service: service).isEmpty)
  }

  // Bug: the secret reached the relay before the Keychain held it; a failed
  // save then left a registration this phone could never delete.
  func testDeviceSecretIsKeptBeforeTheRelayHearsIt() async throws {
    let service = service
    let kept = Kept()
    relay.lock.withLock {
      relay.onDevice = { request in
        let saved = Keychain.items(service: service)["device"]
          .flatMap { try? JSONDecoder().decode(PushDevice.self, from: $0) }
        kept.value = saved?.secret == request.body["device_secret"] as? String
      }
    }
    try await pairings().turnOn()
    XCTAssertEqual(kept.value, true)
  }

  func testRefusedRegistrationLeavesNoSecretBehind() async {
    relay.lock.withLock { relay.deviceReply = RelayStub.Reply(status: 400, body: #"{"error":"invalid"}"#) }
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.turnOn() }
    XCTAssertEqual(error, .relay(.rejected(status: 400)))
    XCTAssertFalse(store.isOn)
    XCTAssertTrue(Keychain.items(service: service).isEmpty)
  }

  // Bug: the relay stored the registration but its answer was lost, and the
  // phone erased the only secret that could ever delete it.
  func testALostAnswerKeepsTheDeviceThatMayBeRegistered() async throws {
    relay.lock.withLock { relay.loseDeviceAnswer = true }
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.turnOn() }
    guard case .relay(.unreachable) = error else { return XCTFail("expected unreachable, got \(String(describing: error))") }
    let registered = try XCTUnwrap(stub.requests.first { $0.method == "POST" && $0.path == "/devices" })
    let kept = try XCTUnwrap(pairings().device, "a relaunch lost the registered identity")
    XCTAssertEqual(kept.id, registered.body["device_id"] as? String)
    XCTAssertEqual(kept.secret, registered.body["device_secret"] as? String)
    XCTAssertTrue(store.isOn)

    // No new identity: turning on again keeps it, and Off deletes exactly that registration.
    relay.lock.withLock { relay.loseDeviceAnswer = false }
    try await store.turnOn()
    XCTAssertEqual(store.device, kept)
    try await store.turnOff()
    let deleted = try XCTUnwrap(stub.requests.last)
    XCTAssertEqual("\(deleted.method) \(deleted.path)", "DELETE /devices")
    XCTAssertEqual(deleted.authorization, "Bearer \(kept.secret)")
    XCTAssertEqual(deleted.body["device_id"] as? String, kept.id)
    XCTAssertEqual(stub.requests.filter { $0.method == "POST" && $0.path == "/devices" }.count, 1)
  }

  // A server error may come after the relay stored it: kept the same way.
  func testAServerErrorKeepsTheDevice() async {
    relay.lock.withLock { relay.deviceReply = RelayStub.Reply(status: 503) }
    let store = pairings()
    _ = await failure { () async throws(PushPairings.Failure) in try await store.turnOn() }
    XCTAssertTrue(store.isOn)
    XCTAssertNotNil(pairings().device)
  }

  // Bug: URLSession followed a 307 and resent the device secret to whatever origin the redirect named.
  func testRedirectsAreRefusedNotFollowed() async throws {
    let elsewhere = try await RelayStub { _ in RelayStub.Reply(status: 200, body: #"{"registered":true}"#) }
    defer { elsewhere.stop() }
    let target = elsewhere.baseURL.appending(path: "devices").absoluteString
    relay.lock.withLock { relay.deviceReply = RelayStub.Reply(status: 307, location: target) }
    let store = pairings()
    let error = await failure { () async throws(PushPairings.Failure) in try await store.turnOn() }
    XCTAssertEqual(error, .relay(.rejected(status: 307)))
    XCTAssertTrue(elsewhere.requests.isEmpty, "the secret went to the redirect's origin")
    XCTAssertFalse(store.isOn)
  }

  private final class Kept: @unchecked Sendable {
    var value: Bool?
  }

  func testHostFileIsTheContractsShape() throws {
    let pairing = HostPairing(hostID: UUID(), pairingID: Hex.sha256("a"), secret: String(repeating: "1", count: 64),
                              routingKey: String(repeating: "2", count: 64), relayURL: "https://relay.example")
    XCTAssertEqual(String(decoding: pairing.hostFile, as: UTF8.self),
                   #"{"relay_url":"https://relay.example","routing_key":"2222222222222222222222222222222222222222222222222222222222222222","secret":"1111111111111111111111111111111111111111111111111111111111111111","version":1}"#)
  }
}

final class RelayConfigTests: XCTestCase {
  func testAcceptsHTTPSAndLocalDevelopment() {
    XCTAssertEqual(RelayConfig.parse("https://term-relay.example.workers.dev")?.host(), "term-relay.example.workers.dev")
    XCTAssertNotNil(RelayConfig.parse("http://127.0.0.1:8787"))
    XCTAssertNotNil(RelayConfig.parse("http://localhost:8787"))
  }

  func testRejectsWhatWouldLeakOrIsUnset() {
    XCTAssertNil(RelayConfig.parse(nil))
    XCTAssertNil(RelayConfig.parse(""))
    XCTAssertNil(RelayConfig.parse("http://relay.example"))
    XCTAssertNil(RelayConfig.parse("https://relay.example/?id=1"))
    XCTAssertNil(RelayConfig.parse("https://user@relay.example"))
    XCTAssertNil(RelayConfig.parse("https:"))
  }
}

final class PushEnvironmentTests: XCTestCase {
  private func profile(_ environment: String) -> Data {
    Data(("junk<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict>"
      + "<key>aps-environment</key><string>\(environment)</string></dict></dict></plist>junk").utf8)
  }

  // Bug: a token registered under the wrong environment never gets a push.
  func testEnvironmentFollowsTheProfile() {
    XCTAssertEqual(PushNotifications.environment(provision: profile("development"), simulator: false), "sandbox")
    XCTAssertEqual(PushNotifications.environment(provision: profile("production"), simulator: false), "production")
    XCTAssertEqual(PushNotifications.environment(provision: nil, simulator: false), "production")
    XCTAssertEqual(PushNotifications.environment(provision: nil, simulator: true), "sandbox")
  }
}
