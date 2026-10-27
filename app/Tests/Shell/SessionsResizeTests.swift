import UIKit
import XCTest
@testable import Term

/// Sessions must be a presentation of existing grids, not a terminal resize.
/// Uses the isolated sshd fixture and only the termtest tmux server.
@MainActor
final class SessionsResizeTests: XCTestCase {
  private var window: UIWindow?
  private var space: SpaceController?
  private var host: Host?
  private var names: [String] = []
  private var keyName = ""
  private var savedSplit = false
  private var grids: [[String]] = []
  private let tmux = "/opt/homebrew/bin/tmux -L termtest"

  override func tearDown() async throws {
    if let space {
      for tab in space.tabs { tab.disconnect() }
      SessionRegistry.shared.discardScenes([space.sceneID])
    }
    if let host {
      for name in names {
        _ = await RemoteExec.run(Tab.spec(for: host), "\(tmux) kill-session -t '=\(name)'")
      }
    }
    Keychain.deleteKey(named: keyName)
    window?.isHidden = true
    window = nil
    space = nil
    AppSettings.shared.splitWhenFlat = savedSplit
  }

  private func execute(_ command: String) async throws -> String {
    let result = try await RemoteExec.run(Tab.spec(for: XCTUnwrap(host)), command).get()
    XCTAssertEqual(result.status, 0, command)
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func counters() async throws -> [[Int]] {
    let command = names.map {
      "\(tmux) display-message -p -t '=\($0):' '#{@sessions-window-resizes} #{@sessions-client-resizes}'"
    }.joined(separator: "; ")
    let values = try await execute(command)
    let lines = values.split(separator: "\n")
    let rows = try XCTUnwrap(lines.count == names.count ? lines : nil, "missing tmux counters: \(values)")
    return try rows.map { row in
      let counts = row.split(separator: " ").compactMap { Int($0) }
      XCTAssertEqual(counts.count, 2, "missing tmux resize counters: \(row)")
      return [try XCTUnwrap(counts.first), try XCTUnwrap(counts.dropFirst().first)]
    }
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(750)) }

  private func open(_ count: Int) async throws -> SpaceController {
    savedSplit = AppSettings.shared.splitWhenFlat
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "local/e2e")
    let configURL = fixture.appending(path: "reconnect.json")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      throw XCTSkip("Private Sessions sshd fixture is not configured")
    }
    struct Configuration: Decodable { var user: String; var port: Int }
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
    let key = try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8)
    keyName = "sessions-resize-" + UUID().uuidString
    try Keychain.addKey(name: keyName, privateKey: key, publicKey: XCTUnwrap(SSHKeys.publicKey(for: key)))
    host = Host(alias: "sessions", hostname: "127.0.0.1", port: config.port, user: config.user, keyName: keyName, transport: .ssh)
    AppSettings.shared.splitWhenFlat = false
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let space = SpaceController(sceneID: keyName)
    self.space = space
    self.window = window
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    space.view.layoutIfNeeded()
    try await settle()
    for _ in 1..<count { space.newTab(); try await settle() }
    for (index, tab) in space.tabs.enumerated() {
      let name = "sessions-" + UUID().uuidString.prefix(8).lowercased()
      names.append(name)
      var target = try XCTUnwrap(host)
      target.startupCommand = "\(tmux) new-session -s \(name) /bin/sh"
      tab.connect(target, tmuxSession: name)
      let deadline = Date.now.addingTimeInterval(60)
      while tab.remote == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
      let remote = try XCTUnwrap(tab.remote, String(decoding: tab.local.history(), as: UTF8.self))
      remote.write(Data("i=1; while [ $i -le 90 ]; do printf 'Session \(index + 1) retained transcript line %03d\\n' $i; i=$((i+1)); done\r".utf8))
    }
    space.select(space.tabs[0])
    try await Task.sleep(for: .seconds(2))
    for name in names {
      for (hook, option) in [("window-resized", "window"), ("client-resized", "client")] {
        let action = "set-option -wF @sessions-\(option)-resizes '#{e|+:#{@sessions-\(option)-resizes},1}'"
        _ = try await execute("\(tmux) set-option -w -t '=\(name):' @sessions-\(option)-resizes 0; \(tmux) set-hook -t '=\(name):' \(hook) \(Command.shellQuote(action))")
      }
    }
    // Positive control: a real keyboard change must resize every remote tab.
    let before = try await counters()
    try XCTUnwrap(space.focusedTab).view.resignFirstResponder()
    try await settle()
    let after = try await counters()
    for i in names.indices {
      XCTAssertGreaterThan(after[i][0], before[i][0], "window-resized counter did not observe a real keyboard resize")
      XCTAssertGreaterThan(after[i][1], before[i][1], "client-resized counter did not observe a real keyboard resize")
    }
    try XCTUnwrap(space.focusedTab).view.becomeFirstResponder()
    try await settle()
    grids = Array(repeating: [], count: count)
    for (index, tab) in space.tabs.enumerated() {
      let previous = tab.current.onGridChange
      tab.current.onGridChange = { [weak self] cols, rows in
        previous?(cols, rows)
        self?.grids[index].append("\(cols)x\(rows)")
      }
    }
    print("SESSIONS SURFACE points=\(space.view.bounds) pixels=\(window.screen.nativeBounds) tabs=\(count)")
    return space
  }

  private enum Entry: String, CaseIterable { case dock, command, threeFingerTap, threeFingerSwipe }
  private enum Exit: String, CaseIterable { case same, other, close }

  private func enter(_ entry: Entry, in space: SpaceController) throws {
    space.menu.tab = .sessions
    switch entry {
    case .dock:
      // The dock callback, also used by the system toolbar's Sessions item.
      let dock = try XCTUnwrap(space.view.subviews.compactMap { $0 as? MenuDock }.first)
      dock.onTap?(.sessions)
    case .command:
      let terminal = try XCTUnwrap(space.focusedTab?.view)
      func command(in view: UIView) -> KeyCap? {
        if let cap = view as? KeyCap, cap.accessibilityLabel == "Command" { return cap }
        return view.subviews.lazy.compactMap { command(in: $0) }.first
      }
      let cap = try XCTUnwrap(command(in: terminal.smartKeys))
      cap.onTap?()
      cap.onTap?()
    case .threeFingerTap:
      space.toggleMenu(nil)
    case .threeFingerSwipe:
      let gesture = OverviewSwipe()
      space.perform(NSSelectorFromString("overviewSwiped:"), with: gesture)
      gesture.phase = .changed
      space.perform(NSSelectorFromString("overviewSwiped:"), with: gesture)
    }
  }

  private func measure(_ label: String, keyboard: Bool, in space: SpaceController, action: () throws -> Void) async throws {
    let before = try await counters()
    grids = Array(repeating: [], count: names.count)
    let probe = KeyboardContinuityProbe(space, expectsSoftwareKeyboard: keyboard, tracksGridChanges: false)
    try action()
    try await settle()
    let after = try await counters()
    probe.stop()
    for i in names.indices {
      let delta = zip(after[i], before[i]).map { $0 - $1 }
      print("SESSIONS RESULT \(label) keyboard=\(keyboard ? "up" : "down") tab=\(i + 1) grids=\(grids[i]) window=\(delta[0]) client=\(delta[1]) hides=\(probe.hides) shows=\(probe.shows) movedFrames=\(probe.changes.count)")
      XCTAssertEqual(grids[i], [], "\(label) resized tab \(i + 1)")
      XCTAssertEqual(delta, [0, 0], "\(label) resized the remote program in tab \(i + 1)")
    }
    XCTAssertEqual(space.tabs.contains { $0.view.isFirstResponder }, keyboard)
  }

  private func prove(_ count: Int) async throws {
    let space = try await open(count)
    for keyboard in [true, false] {
      if !keyboard { space.focusedTab?.view.resignFirstResponder(); try await settle() }
      for entry in Entry.allCases {
        for exit in Exit.allCases {
          try await measure("\(entry.rawValue)/\(exit.rawValue)/open", keyboard: keyboard, in: space) {
            try enter(entry, in: space)
          }
          XCTAssertTrue(space.menu.isOpen)
          // A live thumbnail must exist; otherwise the zoom path was not exercised.
          XCTAssertNotNil(space.menu.thumbnails.view(showing: try XCTUnwrap(space.focusedTab).current))
          try await measure("\(entry.rawValue)/\(exit.rawValue)/close", keyboard: keyboard, in: space) {
            switch exit {
            case .same: space.zoom(into: try XCTUnwrap(space.focusedTab))
            case .other: space.zoom(into: try XCTUnwrap(space.tabs.first { $0 !== space.focusedTab }))
            case .close: space.closeMenu()
            }
          }
          XCTAssertFalse(space.menu.isOpen)
        }
      }
    }
  }

  func testTwoRemoteTabsKeepTheirGridsAndKeyboardThroughSessions() async throws { try await prove(2) }
  func testThreeRemoteTabsKeepTheirGridsAndKeyboardThroughSessions() async throws { try await prove(3) }
}

private final class OverviewSwipe: UIPanGestureRecognizer {
  var phase: UIGestureRecognizer.State = .began
  override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
  override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: -25) }
}
