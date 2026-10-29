import CryptoKit
import UIKit
import XCTest
@testable import Term

/// Opt-in proof on a simulator that a real tapped notification opens the
/// exact pane, through the app's own notification delegate. Runs only when
/// local/push-proof/enabled exists, against the private sshd in local/e2e
/// (reconnect.json, client_key, host_key.pub; its `tmux` uses socket termtest).
///
/// It saves host "push-proof" with its key pinned and a pairing for it, makes
/// tmux session "push-proof" with the target pane neither in the current
/// window nor active, and writes local/push-proof/push.apns and ready.json.
/// The runner then pushes and taps the banner; this waits (up to
/// local/push-proof/wait seconds, default 300) for a new tab attached to the
/// session with the target pane active. It then makes another window current,
/// writes ready-existing.json, and waits for a second push of the same file to
/// select the pane again in that same tab before writing passed.json. Host,
/// key, pairing and session stay for the runner's background and cold-launch
/// taps; local/push-proof/clean makes testRemoveProofFixture take them away.
@MainActor
final class PushProofTests: XCTestCase {
  private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private var proof: URL { root.appending(path: "local/push-proof") }
  private var fixture: URL { root.appending(path: "local/e2e") }
  private static let alias = "push-proof"
  private static let session = "push-proof"
  private static let keyName = "push-proof"

  private struct Fixture: Decodable {
    var user: String
    var port: Int
  }

  private func require(_ flag: String) throws -> Fixture {
    guard FileManager.default.fileExists(atPath: proof.appending(path: flag).path) else {
      throw XCTSkip("local/push-proof/\(flag) is absent")
    }
    let url = fixture.appending(path: "reconnect.json")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private sshd fixture is not configured") }
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  /// The saved host, its key and pinned host key, as a user's would be after a first connection.
  private func savedHost(_ config: Fixture) throws -> Host {
    let key = try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8)
    Keychain.deleteKey(named: Self.keyName)
    try Keychain.addKey(name: Self.keyName, privateKey: key, publicKey: try XCTUnwrap(SSHKeys.publicKey(for: key)))
    let hostKey = try String(contentsOf: fixture.appending(path: "host_key.pub"), encoding: .utf8)
      .split(separator: " ").prefix(2).joined(separator: " ")
    var host = ConfigStore.shared.host(alias: Self.alias)
      ?? Host(alias: Self.alias, hostname: "127.0.0.1", port: config.port, user: config.user)
    host.port = config.port
    host.user = config.user
    host.keyName = Self.keyName
    host.transport = .ssh
    ConfigStore.shared.save(host)
    ConfigStore.shared.pinHostKey(hostKey, for: host.knownHostsKey)
    return host
  }

  private func run(_ host: Host, _ command: String) async throws -> String {
    let output = try await RemoteExec.run(Tab.spec(for: host), command).get()
    let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.status == 0 else { throw ProofFailure(message: "status \(output.status): \(text)") }
    return text
  }

  private struct ProofFailure: Error { var message: String }

  func testTappedNotificationOpensTheExactPane() async throws {
    let config = try require("enabled")
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
    for name in ["ready.json", "ready-existing.json", "push.apns", "passed.json", "failed.txt"] {
      try? FileManager.default.removeItem(at: proof.appending(path: name))
    }
    let host = try savedHost(config)

    // Decoy pane active in window one; target split beside it; another window current.
    let quoted = Command.shellQuote("=" + Self.session)
    let made = try await run(host, [
      Tmux.path,
      "tmux kill-session -t \(quoted) 2>/dev/null",
      "d=$(tmux -u new-session -d -P -F '#{pane_id}' -s \(Command.shellQuote(Self.session)) -x 100 -y 30"
        + " \(Command.shellQuote("echo PUSH-PROOF-DECOY; exec sleep 86400")))",
      "t=$(tmux split-window -P -F '#{pane_id}' -t \"$d\" \(Command.shellQuote("echo PUSH-PROOF-TARGET; exec sleep 86400")))",
      "tmux select-pane -t \"$d\"",
      "o=$(tmux new-window -P -F '#{pane_id}' -t \(quoted) \(Command.shellQuote("echo PUSH-PROOF-ELSEWHERE; exec sleep 86400")))",
      "printf '%s %s %s' \"$d\" \"$t\" \"$o\"",
    ].joined(separator: "; "))
    let ids = made.split(separator: " ").map(String.init)
    guard ids.count == 3 else { throw ProofFailure(message: "tmux setup printed \(made)") }
    let (decoy, target, elsewhere) = (ids[0], ids[1], ids[2])

    // The pairing a real Pair leaves, without a relay: the host file is not needed to receive a push.
    let secret = Hex.random()
    let pairing = HostPairing(hostID: host.id, pairingID: Hex.sha256(secret), secret: secret,
                              routingKey: Hex.random(), relayURL: "https://relay.invalid")
    XCTAssertTrue(PushPairings.shared.remember(pairing))
    // Banners show only with permission: the first run asks, and the runner taps Allow.
    let allowed = await PushNotifications.shared.authorize()
    XCTAssertTrue(allowed, "Allow notifications for Term, then run again")

    let listed = PaneRoute.parse(Data(try await run(host, PaneRoute.listCommand).utf8))
    let pane = try XCTUnwrap(listed.first { $0.pane == target && $0.session == Self.session })
    let key = try XCTUnwrap(Hex.data(pairing.routingKey).map { SymmetricKey(data: $0) })
    let ref = PaneRoute.reference(pane, routingKey: key)
    let payload: [String: Any] = [
      "Simulator Target Bundle": AppIdentity.bundleID,
      "aps": ["alert": ["title": "Term", "body": "An agent needs you"], "sound": "default"],
      "term": ["pairing_id": pairing.pairingID, "session_ref": ref, "kind": "ask"],
    ]
    try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      .write(to: proof.appending(path: "push.apns"))
    let ready: [String: Any] = [
      "bundle_id": AppIdentity.bundleID, "session": Self.session, "socket": "termtest",
      "target_pane": target, "decoy_pane": decoy, "elsewhere_pane": elsewhere,
      "pairing_id": pairing.pairingID, "session_ref": ref,
    ]
    try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
      .write(to: proof.appending(path: "ready.json"))

    let seconds = (try? String(contentsOf: proof.appending(path: "wait"), encoding: .utf8))
      .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 300
    let tabs = { SpaceController.live.flatMap(\.tabs).filter { $0.tmuxSession == Self.session && $0.target?.port == config.port } }
    let activePane = { [self] in
      (try? await run(host, "\(Tmux.path); tmux display-message -p -t \(Command.shellQuote("=" + Self.session + ":")) '#{pane_id}'")) ?? ""
    }
    /// Waits for a connected tab on the session with the target pane active.
    func waitForTarget(_ phase: String) async throws -> String {
      let deadline = Date.now.addingTimeInterval(seconds)
      var active = ""
      while Date.now < deadline {
        if tabs().contains(where: \.isConnected) {
          active = await activePane()
          if active == target { return active }
        }
        try await Task.sleep(for: .seconds(1))
      }
      let why = "\(phase): no tab on \(Self.session) with \(target) active within \(Int(seconds)) s (active: \(active.isEmpty ? "none" : active))"
      try? why.write(to: proof.appending(path: "failed.txt"), atomically: true, encoding: .utf8)
      throw ProofFailure(message: why)
    }

    // Tap one: no tab on the session, so a new one attaches.
    let active = try await waitForTarget("new tab")
    let tab = try XCTUnwrap(tabs().first)
    try await Task.sleep(for: .seconds(1))
    let screen = tab.current.text(fromCol: 0, row: 0, toCol: tab.current.cols - 1, row: tab.current.rows - 1)
    XCTAssertTrue(screen.contains("PUSH-PROOF-TARGET"), "the tab shows the target's window")
    XCTAssertFalse(screen.contains("PUSH-PROOF-ELSEWHERE"), "not the window that was current")

    // The attachment probe, run for real, names this tab's client's active pane and its @agent.
    let root = try XCTUnwrap(tab.remote?.processID)
    let agentPayload = #"{"state":"ask","stop":{"at":1793241830.5}}"#
    _ = try await run(host, "\(Tmux.path); tmux set-option -p -t \(Command.shellQuote(target)) @agent \(Command.shellQuote(agentPayload))")
    let probed = await RemoteExec.run(Tab.spec(for: host), TmuxAttachment.probeCommand(roots: [root]))
    _ = try await run(host, "\(Tmux.path); tmux set-option -p -u -t \(Command.shellQuote(target)) @agent")
    let probe = String(decoding: try probed.get().stdout, as: UTF8.self)
    XCTAssertEqual(TmuxAttachment.parse(probe, root: root), .attached(Self.session))
    XCTAssertEqual(TmuxAttachment.shownAgent(probe, root: root), ShownAgent(pane: target, state: .ask, stop: 1793241830.5))

    // Tap two: the wrong pane is current again and the tab stays open; the same push selects the pane in it.
    _ = try await run(host, "\(Tmux.path); tmux select-window -t \(Command.shellQuote(elsewhere))")
    let reset = await activePane()
    XCTAssertEqual(reset, elsewhere)
    try Data("{\"phase\":\"existing tab\"}".utf8).write(to: proof.appending(path: "ready-existing.json"))
    _ = try await waitForTarget("existing tab")
    XCTAssertEqual(tabs().count, 1, "the second tap opened another tab")

    let passed: [String: Any] = ["active_pane": active, "target_pane": target, "tab_session": tab.sessionName,
                                 "shows_target_window": screen.contains("PUSH-PROOF-TARGET"),
                                 "existing_tab_reselected": true, "tabs_on_session": tabs().count]
    try JSONSerialization.data(withJSONObject: passed, options: [.prettyPrinted, .sortedKeys])
      .write(to: proof.appending(path: "passed.json"))
  }

  /// The pairing file over the host's pinned SSH connection: written as the
  /// contract's JSON, folder 0700 and file 0600, then removed. Only the one
  /// file this test makes is touched, never the folder or other pairings.
  func testWritesPairingOverPinnedSSH() async throws {
    let host = try savedHost(try require("enabled"))
    let spec = Tab.spec(for: host)
    XCTAssertNotNil(spec.hostKey, "the host key is pinned")
    let secret = Hex.random()
    let pairing = HostPairing(hostID: host.id, pairingID: Hex.sha256(secret), secret: secret,
                              routingKey: Hex.random(), relayURL: "http://127.0.0.1:8789")
    let file = "\"$HOME/\(SSHNotifyFiles.directory)/\(pairing.pairingID).json\""
    addTeardownBlock { _ = await RemoteExec.run(spec, "rm -f \(file)") }

    try await SSHNotifyFiles().write(pairing, to: spec)
    let written = try await run(host, "cat \(file)")
    XCTAssertEqual(written, String(decoding: pairing.hostFile, as: UTF8.self))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
    XCTAssertEqual(object["version"] as? Int, 1)
    XCTAssertEqual(object["relay_url"] as? String, "http://127.0.0.1:8789")
    XCTAssertEqual(object["secret"] as? String, secret)
    XCTAssertEqual(object["routing_key"] as? String, pairing.routingKey)
    let modes = try await run(host, "for p in \"$HOME/\(SSHNotifyFiles.directory)\" \(file); do"
      + " stat -f '%Lp' \"$p\" 2>/dev/null || stat -c '%a' \"$p\"; done")
    XCTAssertEqual(modes.split(separator: "\n"), ["700", "600"])

    await SSHNotifyFiles().remove(pairingID: pairing.pairingID, from: spec)
    let gone = await RemoteExec.run(spec, "[ -e \(file) ]")
    XCTAssertEqual(try gone.get().status, 1, "the pairing file is still on the host")
  }

  /// Takes away what the proof left: the session, the pairing, the host and its key.
  func testRemoveProofFixture() async throws {
    let config = try require("clean")
    guard var host = ConfigStore.shared.host(alias: Self.alias) else { return }
    host.port = config.port
    _ = try? await run(host, "\(Tmux.path); tmux kill-session -t \(Command.shellQuote("=" + Self.session))")
    try? await PushPairings.shared.unpair(host)
    ConfigStore.shared.pinHostKey(nil, for: host.knownHostsKey)
    ConfigStore.shared.delete(host)
    Keychain.deleteKey(named: Self.keyName)
  }
}
