import UIKit
import XCTest
@testable import Term

/// Opt-in simulator checks against a private sshd. local/e2e/reconnect.json
/// contains {"user": ..., "port": ...}; its client_key authenticates that server.
/// The private server's `tmux` must select an isolated test socket.
@MainActor
final class TmuxReconnectTests: XCTestCase {
  private var window: UIWindow?
  private var tab: Tab?
  private var host: Host?
  private var keyName = ""
  private var sessionName = ""
  private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "local/e2e")

  override func tearDown() async throws {
    tab?.disconnect()
    if let host, !sessionName.isEmpty {
      _ = await RemoteExec.run(Tab.spec(for: host), Tmux.killCommand(ids: ["=" + sessionName]))
    }
    window?.isHidden = true
    window = nil
    tab = nil
    Keychain.deleteKey(named: keyName)
  }

  private func connect(_ transport: Host.Transport) async throws -> Tab {
    struct Configuration: Decodable { var user: String; var port: Int }
    let url = fixture.appending(path: "reconnect.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("Private reconnect sshd fixture is not configured")
    }
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    let key = try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8)
    keyName = "reconnect-" + UUID().uuidString
    try Keychain.addKey(name: keyName, privateKey: key, publicKey: try XCTUnwrap(SSHKeys.publicKey(for: key)))
    let host = Host(alias: transport == .mosh ? "e2em" : "e2e", hostname: "127.0.0.1", port: config.port,
                    user: config.user, keyName: keyName, transport: transport)
    self.host = host
    sessionName = "reconnect-" + UUID().uuidString.prefix(8).lowercased()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let space = SpaceController(sceneID: UUID().uuidString)
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window
    space.loadViewIfNeeded()
    let tab = try XCTUnwrap(space.tabs.first)
    self.tab = tab
    tab.connect(host)
    try await until("plain login shell") { tab.remote != nil }
    return tab
  }

  private func until(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(20)
    while !condition() {
      if Date.now > deadline { XCTFail("Timed out waiting for \(description)"); throw WaitFailure() }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
  private struct WaitFailure: Error {}

  private func execute(_ command: String) async throws -> RemoteExec.Output {
    let result = await RemoteExec.run(Tab.spec(for: try XCTUnwrap(host)), command)
    return try result.get()
  }

  private func text(_ tab: Tab) -> String {
    let s = tab.current
    return s.text(fromCol: 0, row: 0, toCol: s.cols - 1, row: s.rows - 1)
  }

  private func attach(_ tab: Tab) async throws {
    // Login shells may reorder PATH ahead of the private fixture wrapper.
    tab.current.write(Data("/opt/homebrew/bin/tmux -L termtest new-session -s \(sessionName) /bin/sh\r".utf8))
    tab.current.write(Data("printf 'retained-%s\\n' $((6*7))\r".utf8))
    do {
      try await until("manual tmux identity") { tab.tmuxSession == sessionName }
    } catch {
      let root = tab.current.processID
      let probe = try await execute(TmuxAttachment.probeCommand(root: root))
      XCTFail("root=\(root), probe=\(String(decoding: probe.stdout, as: UTF8.self).debugDescription), screen=\(text(tab))")
      throw error
    }
    try await until("retained tmux output") { text(tab).contains("retained-42") }
    XCTAssertEqual(tab.sessionName, sessionName)
    guard case .tmux(let name) = tab.historySource else { return XCTFail("History did not follow the learned session") }
    XCTAssertEqual(name, sessionName)
  }

  private func drop(_ tab: Tab) async throws {
    let root = try XCTUnwrap(tab.remote).processID
    XCTAssertGreaterThan(root, 1)
    // Only this test tab's server is killed. Other tabs and the listener survive.
    let killed = try await execute("kill -KILL \(root)")
    XCTAssertEqual(killed.status, 0)
    try await until("Reconnect banner") { tab.unreachable }
  }

  private func reconnectButton(in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.title(for: .normal) == "Reconnect" { return button }
    return view.subviews.lazy.compactMap { self.reconnectButton(in: $0) }.first
  }

  private func capture(_ name: String) async throws {
    // A host-side runner can capture the actual simulator framebuffer at each
    // named point. It acknowledges by removing the request; no UI mock is used.
    let request = fixture.appending(path: "reconnect-capture")
    guard FileManager.default.fileExists(atPath: fixture.appending(path: "capture-enabled").path) else { return }
    try name.write(to: request, atomically: true, encoding: .utf8)
    try await until("simulator screenshot") { !FileManager.default.fileExists(atPath: request.path) }
  }

  private func manualReconnect(_ transport: Host.Transport) async throws {
    let tab = try await connect(transport)
    try await attach(tab)
    try await capture("\(transport)-attached")
    try await drop(tab)
    try XCTUnwrap(reconnectButton(in: try XCTUnwrap(window))).sendActions(for: .touchUpInside)
    try await until("replacement connection") { !tab.reconnecting && !tab.unreachable && tab.remote != nil }
    tab.current.write(Data("printf 'reopened-%s\\n' $((7*8))\r".utf8))
    try await until("same tmux session") { text(tab).contains("retained-42") && text(tab).contains("reopened-56") }
    XCTAssertEqual(tab.tmuxSession, sessionName)
    try await capture("\(transport)-reconnected")

    tab.current.write(Data([2, 100])) // tmux's default Ctrl-B d
    try await until("detached shell identity") { tab.tmuxSession == nil }
    try await drop(tab)
    try XCTUnwrap(reconnectButton(in: try XCTUnwrap(window))).sendActions(for: .touchUpInside)
    try await until("replacement shell") { !tab.reconnecting && !tab.unreachable && tab.remote != nil }
    tab.current.write(Data("printf 'shell-%s:%s\\n' $((8*8)) \"${TMUX:-none}\"\r".utf8))
    try await until("shell outside tmux") { text(tab).contains("shell-64:none") }
    XCTAssertNil(tab.tmuxSession)
    try await capture("\(transport)-detached-shell")
  }

  func testHandAttachedMoshSessionReconnectsAndDetachedTabStaysShell() async throws {
    try await manualReconnect(.mosh)
  }

  func testHandAttachedSSHSessionReconnectsAndDetachedTabStaysShell() async throws {
    try await manualReconnect(.ssh)
  }

  func testHandAttachedMoshSessionAutomaticallyReconnects() async throws {
    let tab = try await connect(.mosh)
    try await attach(tab)
    let previous = tab.current.processID
    try await drop(tab)
    try await until("automatic tmux reconnect") {
      !tab.unreachable && !tab.reconnecting && tab.current.processID != previous
    }
    tab.current.write(Data("printf 'automatic-%s\\n' $((6*9))\r".utf8))
    try await until("automatic reconnect preserved the session") {
      text(tab).contains("retained-42") && text(tab).contains("automatic-54")
    }
    XCTAssertEqual(tab.tmuxSession, sessionName)
    try await capture("mosh-automatic")
  }

  func testGoneManualSessionFallsBackToShellWithoutRecreatingIt() async throws {
    let tab = try await connect(.mosh)
    try await attach(tab)
    let previous = tab.current.processID
    let dropped = try await execute("kill -KILL \(previous)")
    XCTAssertEqual(dropped.status, 0)
    let killed = try await execute(Tmux.killCommand(ids: ["=" + sessionName]))
    XCTAssertEqual(killed.status, 0)
    tab.reconnect()
    try await until("fallback connection") {
      !tab.reconnecting && tab.remote != nil && tab.current.processID != previous
    }
    tab.current.write(Data("printf 'fallback-%s:%s\\n' $((9*9)) \"${TMUX:-none}\"\r".utf8))
    try await until("missing session login shell") { text(tab).contains("fallback-81:none") }
    let exists = try await execute(Tmux.hasSessionCommand(sessionName))
    XCTAssertEqual(exists.status, 1)
    try await capture("mosh-missing-shell")
  }
}
