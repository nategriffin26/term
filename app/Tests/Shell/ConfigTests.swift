import XCTest
@testable import Term

@MainActor
final class ConfigTests: XCTestCase {
  private var dir: URL!
  private var url: URL { dir.appending(path: "config.json") }

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appending(path: "term-config-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
  }

  private func host(_ alias: String, _ hostname: String = "h.example", user: String = "u") -> Host {
    Host(alias: alias, hostname: hostname, user: user)
  }

  // MARK: - First run

  func testFirstRunHasNoHostsAndWritesNothingUntilSomethingIsSaved() {
    let store = ConfigStore(url: url)
    XCTAssertTrue(store.hosts.isEmpty)
    XCTAssertTrue(store.config.knownHosts.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - Round trip

  func testEveryHostFieldSurvivesSaveAndReload() {
    let full = Host(alias: "ünï", hostname: "10.0.0.2", port: 60022, user: "me@corp", keyName: "work key",
                    transport: .ssh, moshServer: "/opt/mosh-server", startupCommand: "tmux new -A -s 'my work'",
                    prediction: .always)
    let store = ConfigStore(url: url)
    store.save(full)
    store.pinHostKey("ssh-ed25519 AAAAC3Nz", for: full.knownHostsKey)
    let again = ConfigStore(url: url)
    XCTAssertEqual(again.host(alias: "ünï"), full)
    XCTAssertEqual(again.hostKey(for: "10.0.0.2:60022"), "ssh-ed25519 AAAAC3Nz")
  }

  /// The file format is a contract with every future build: hand-written JSON must keep loading.
  func testHandWrittenConfigFileLoads() throws {
    let json = """
    {"hosts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","alias":"box","hostname":"box.lan","port":2222,
    "user":"root","keyName":"k1","transport":"ssh","moshServer":"","startupCommand":"htop","prediction":"never"}],
    "knownHosts":{"box.lan:2222":"ssh-ed25519 AAAA"}}
    """
    try Data(json.utf8).write(to: url)
    let store = ConfigStore(url: url)
    XCTAssertEqual(store.hosts, [Host(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, alias: "box",
                                      hostname: "box.lan", port: 2222, user: "root", keyName: "k1", transport: .ssh,
                                      moshServer: "", startupCommand: "htop", prediction: .never)])
    XCTAssertEqual(store.hostKey(for: "box.lan:2222"), "ssh-ed25519 AAAA")
  }

  func testUnknownKeysFromANewerBuildAreIgnored() throws {
    let json = """
    {"hosts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","alias":"box","hostname":"box.lan","port":22,
    "user":"root","transport":"mosh","moshServer":"","startupCommand":"","prediction":"adaptive","color":"red"}],
    "knownHosts":{},"theme":"x"}
    """
    try Data(json.utf8).write(to: url)
    XCTAssertEqual(ConfigStore(url: url).hosts.map(\.alias), ["box"])
  }

  /// A host saved before a field existed must still load; otherwise adding a
  /// setting would move every user's hosts aside as "unreadable".
  func testConfigFromBeforeAFieldWasAddedStillLoads() throws {
    let json = """
    {"hosts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","alias":"box","hostname":"box.lan","port":22,
    "user":"root","transport":"mosh","moshServer":"","startupCommand":""}],"knownHosts":{}}
    """
    try Data(json.utf8).write(to: url)
    let store = ConfigStore(url: url)
    XCTAssertEqual(store.hosts.map(\.alias), ["box"])
  }

  // MARK: - Editing

  func testSaveReplacesByIDAndKeepsOrder() {
    let store = ConfigStore(url: url)
    let first = host("first")
    var a = host("a"), b = host("b")
    store.save(first); store.save(a); store.save(b)
    a.alias = "renamed"; a.port = 2200
    store.save(a)
    XCTAssertEqual(store.hosts.map(\.alias), ["first", "renamed", "b"])
    XCTAssertEqual(ConfigStore(url: url).hosts.map(\.port), [22, 2200, 22])
    b.user = "other"
    store.save(b)
    XCTAssertEqual(store.host(alias: "b")?.user, "other")
  }

  func testDeleteRemovesOnlyThatHostAndItsPassword() {
    let store = ConfigStore(url: url)
    let first = host("first"), a = host("a"), b = host("b")
    store.save(first); store.save(a); store.save(b)
    Keychain.setPassword("secret", for: a.id)
    Keychain.setPassword("keep", for: b.id)
    defer { Keychain.setPassword(nil, for: b.id) }
    store.delete(a)
    XCTAssertEqual(ConfigStore(url: url).hosts.map(\.alias), ["first", "b"])
    XCTAssertNil(Keychain.password(for: a.id))
    XCTAssertEqual(Keychain.password(for: b.id), "keep")
  }

  func testMoveHostsPersistsTheNewOrder() {
    let store = ConfigStore(url: url)
    store.save(host("first")); store.save(host("a")); store.save(host("b"))
    store.moveHosts(from: IndexSet(integer: 2), to: 0)
    XCTAssertEqual(store.hosts.map(\.alias), ["b", "first", "a"])
    XCTAssertEqual(ConfigStore(url: url).hosts.map(\.alias), ["b", "first", "a"])
  }

  func testPinnedHostKeysAreKeyedByHostAndPortAndCanBeForgotten() {
    let store = ConfigStore(url: url)
    let h = host("a", "box.lan")
    store.pinHostKey("ssh-ed25519 ONE", for: h.knownHostsKey)
    store.pinHostKey("ssh-ed25519 TWO", for: "box.lan:2222")
    XCTAssertEqual(ConfigStore(url: url).hostKey(for: "box.lan:22"), "ssh-ed25519 ONE")
    XCTAssertEqual(ConfigStore(url: url).hostKey(for: "box.lan:2222"), "ssh-ed25519 TWO")
    XCTAssertNil(ConfigStore(url: url).hostKey(for: "box.lan"))
    store.pinHostKey(nil, for: h.knownHostsKey)
    XCTAssertNil(ConfigStore(url: url).hostKey(for: "box.lan:22"))
    XCTAssertEqual(ConfigStore(url: url).hostKey(for: "box.lan:2222"), "ssh-ed25519 TWO")
  }

  // MARK: - Damaged files

  func testUnreadableFileIsMovedAsideNotOverwritten() throws {
    let garbage = Data("{ this is not json".utf8)
    try garbage.write(to: url)
    let store = ConfigStore(url: url)
    XCTAssertEqual(store.hosts, [])
    let aside = dir.appending(path: "config.unreadable.json")
    XCTAssertEqual(try Data(contentsOf: aside), garbage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    store.save(host("fresh"))
    XCTAssertEqual(try Data(contentsOf: aside), garbage, "saving must not touch the saved-aside copy")
    XCTAssertEqual(ConfigStore(url: url).hosts.map(\.alias), ["fresh"])
  }

  func testEmptyFileIsTreatedAsUnreadable() throws {
    try Data().write(to: url)
    XCTAssertEqual(ConfigStore(url: url).hosts, [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "config.unreadable.json").path))
  }

  func testWrongTypesAreUnreadableNotPartiallyLoaded() throws {
    try Data(#"{"hosts":[{"alias":"a"}],"knownHosts":{}}"#.utf8).write(to: url)
    XCTAssertEqual(ConfigStore(url: url).hosts, [])
  }
}

final class ConnectSpecTests: XCTestCase {
  private func spec(_ transport: Host.Transport = .mosh, port: Int = 22, privateKey: String? = nil,
                    password: String? = nil, command: String? = nil, server: String? = nil,
                    prediction: Host.Prediction = .adaptive) -> ConnectSpec {
    ConnectSpec(transport: transport, hostname: "h.lan", port: port, user: "me", privateKey: privateKey,
                password: password, hostKey: nil, command: command, moshServer: server,
                prediction: prediction, label: "h")
  }

  func testStringsReachTheCoreAndEmptyOnesBecomeNull() {
    let s = spec(command: "", server: "")
    s.withTermConnect(cols: 80, rows: 24) { c in
      XCTAssertEqual(String(cString: c.pointee.host), "h.lan")
      XCTAssertEqual(String(cString: c.pointee.user), "me")
      XCTAssertNil(c.pointee.command, "empty command means the login shell")
      XCTAssertNil(c.pointee.mosh_server)
      XCTAssertNil(c.pointee.private_key)
      XCTAssertNil(c.pointee.password)
      XCTAssertNil(c.pointee.host_key)
      XCTAssertEqual(c.pointee.port, 22)
      XCTAssertEqual(c.pointee.cols, 80)
      XCTAssertEqual(c.pointee.rows, 24)
    }
    spec(privateKey: "KEY", password: "pw", command: "tmux a", server: "/x").withTermConnect(cols: 1, rows: 1) { c in
      XCTAssertEqual(String(cString: c.pointee.private_key), "KEY")
      XCTAssertEqual(String(cString: c.pointee.password), "pw")
      XCTAssertEqual(String(cString: c.pointee.command), "tmux a")
      XCTAssertEqual(String(cString: c.pointee.mosh_server), "/x")
    }
  }

  func testTransportAndPredictionMapToTheCValues() {
    spec(.ssh, prediction: .never).withTermConnect(cols: 1, rows: 1) { c in
      XCTAssertEqual(c.pointee.transport, UInt32(TERM_TRANSPORT_SSH.rawValue))
      XCTAssertEqual(c.pointee.predict, UInt32(TERM_PREDICT_NEVER.rawValue))
    }
    spec(.mosh, prediction: .always).withTermConnect(cols: 1, rows: 1) { c in
      XCTAssertEqual(c.pointee.transport, UInt32(TERM_TRANSPORT_MOSH.rawValue))
      XCTAssertEqual(c.pointee.predict, UInt32(TERM_PREDICT_ALWAYS.rawValue))
    }
    spec(prediction: .adaptive).withTermConnect(cols: 1, rows: 1) { c in
      XCTAssertEqual(c.pointee.predict, UInt32(TERM_PREDICT_ADAPTIVE.rawValue))
    }
  }

  func testSizesAreClampedNotWrapped() {
    spec(port: 70000).withTermConnect(cols: 100_000, rows: -5) { c in
      XCTAssertEqual(c.pointee.port, 65535)
      XCTAssertEqual(c.pointee.cols, 65535)
      XCTAssertEqual(c.pointee.rows, 0)
    }
  }

  func testKnownHostsKeyIsHostColonPort() {
    XCTAssertEqual(spec(port: 2222).knownHostsKey, "h.lan:2222")
    XCTAssertEqual(Host(alias: "a", hostname: "h.lan", user: "u").knownHostsKey, "h.lan:22")
  }
}
