import UIKit
import XCTest
@testable import Term

/// Opt-in proof against the same isolated sshd as TmuxReconnectTests.
/// Each tab runs in its own tmux session; window-resized counts what its
/// program actually sees, including a resize later undone by the keyboard.
@MainActor
final class KeyboardSwipeRemoteTests: XCTestCase {
  private var window: UIWindow?
  private var space: SpaceController!
  private var host: Host?
  private var names: [String] = []
  private var keyName = ""
  private var gridEvents: [String] = []
  private var savedSplit = false
  private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "local/e2e")

  override func tearDown() async throws {
    if let space {
      for tab in space.tabs { tab.disconnect() }
      SessionRegistry.shared.discardScenes([space.sceneID])
    }
    if let host {
      for name in names {
        _ = await RemoteExec.run(Tab.spec(for: host), "/opt/homebrew/bin/tmux -L termtest kill-session -t '=\(name)'")
      }
      _ = await RemoteExec.run(Tab.spec(for: host), "rm -f /tmp/\(keyName)/note.txt /tmp/\(keyName)/swipe.txt; rmdir /tmp/\(keyName) 2>/dev/null")
    }
    Keychain.deleteKey(named: keyName)
    window?.isHidden = true
    window = nil
    space = nil
    AppSettings.shared.splitWhenFlat = savedSplit
  }

  private func execute(_ command: String) async throws -> String {
    let output = try await RemoteExec.run(Tab.spec(for: XCTUnwrap(host)), command).get()
    XCTAssertEqual(output.status, 0, command)
    return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resizeCount(_ name: String) async throws -> Int {
    let value = try await execute("/opt/homebrew/bin/tmux -L termtest show-options -wv -t '=\(name):' @swipe-resizes")
    return try XCTUnwrap(Int(value), "tmux did not return its resize counter")
  }

  private func waitForResizes(_ minimum: Int, in name: String) async throws {
    let deadline = Date.now.addingTimeInterval(10)
    var count = try await resizeCount(name)
    while count < minimum, Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      count = try await resizeCount(name)
    }
    XCTAssertGreaterThanOrEqual(count, minimum, "the remote counter must observe the keyboard resize")
  }

  private func open(_ count: Int) async throws {
    savedSplit = AppSettings.shared.splitWhenFlat
    struct Configuration: Decodable { var user: String; var port: Int }
    let url = fixture.appending(path: "reconnect.json")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private swipe sshd fixture is not configured") }
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    let key = try String(contentsOf: fixture.appending(path: "client_key"), encoding: .utf8)
    keyName = "keyboard-swipe-" + UUID().uuidString
    try Keychain.addKey(name: keyName, privateKey: key, publicKey: XCTUnwrap(SSHKeys.publicKey(for: key)))
    host = Host(alias: "swipe", hostname: "127.0.0.1", port: config.port, user: config.user, keyName: keyName, transport: .ssh)
    AppSettings.shared.splitWhenFlat = false
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    space = SpaceController(sceneID: keyName)
    window.rootViewController = UINavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window
    space.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(800))
    for _ in 1..<count {
      space.newTab()
      try await Task.sleep(for: .milliseconds(800))
    }
    for (index, tab) in space.tabs.enumerated() {
      let name = "swipe-" + UUID().uuidString.prefix(8).lowercased()
      names.append(name)
      var target = try XCTUnwrap(host)
      target.startupCommand = "/opt/homebrew/bin/tmux -L termtest new-session -s \(name) /bin/sh"
      tab.connect(target, tmuxSession: name)
      let deadline = Date.now.addingTimeInterval(15)
      while tab.remote == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
      let remote = try XCTUnwrap(tab.remote, String(decoding: tab.local.history(), as: UTF8.self))
      remote.write(Data("printf '\\033[2J\\033[H'; i=1; while [ $i -le 90 ]; do printf '\\033[36mSession \(index + 1)\\033[0m  retained transcript line %03d\\n' $i; i=$((i+1)); done\r".utf8))
    }
    space.select(space.tabs[0])
    try await Task.sleep(for: .seconds(2))
    for name in names {
      // A tmux option is synchronous; run-shell logs can arrive after a reset.
      let action = "set-option -wF @swipe-resizes '#{e|+:#{@swipe-resizes},1}'"
      _ = try await execute("/opt/homebrew/bin/tmux -L termtest set-option -w -t '=\(name):' @swipe-resizes 0; /opt/homebrew/bin/tmux -L termtest set-hook -t '=\(name):' window-resized \(Command.shellQuote(action))")
    }
    // Prove the counter sees real resizes before relying on its zero.
    let keyboardRows = space.tabs.map { $0.current.rows }
    XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.resignFirstResponder())
    let hideDeadline = Date.now.addingTimeInterval(5)
    while zip(space.tabs, keyboardRows).contains(where: { $0.current.rows <= $1 }), Date.now < hideDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    for (tab, rows) in zip(space.tabs, keyboardRows) {
      XCTAssertGreaterThan(tab.current.rows, rows, "hiding the keyboard must resize every tab")
    }
    for name in names { try await waitForResizes(1, in: name) }
    XCTAssertTrue(try XCTUnwrap(space.focusedTab).view.becomeFirstResponder())
    let showDeadline = Date.now.addingTimeInterval(5)
    while space.tabs.map({ $0.current.rows }) != keyboardRows, Date.now < showDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(space.tabs.map { $0.current.rows }, keyboardRows)
    for name in names {
      try await waitForResizes(2, in: name)
      _ = try await execute("/opt/homebrew/bin/tmux -L termtest set-option -w -t '=\(name):' @swipe-resizes 0")
    }
    for (index, tab) in space.tabs.enumerated() {
      let previous = tab.current.onGridChange
      tab.current.onGridChange = { [weak self] cols, rows in
        previous?(cols, rows)
        self?.gridEvents.append("tab\(index + 1):\(cols)x\(rows)")
      }
    }
  }

  private func swipe(_ direction: CGFloat, fast: Bool, cancel: Bool) async throws {
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    let parent = try XCTUnwrap(terminal.superview)
    let gesture = SwipeGesture()
    gesture.point = parent.convert(CGPoint(x: parent.bounds.midX, y: parent.bounds.height * 0.25), to: space.view)
    gesture.phase = .began
    space.perform(NSSelectorFromString("page:"), with: gesture)
    for step in 1...12 {
      gesture.phase = .changed
      gesture.distance = direction * parent.bounds.width * (cancel ? 0.2 : fast ? 0.25 : 0.7) * CGFloat(step) / 12
      space.perform(NSSelectorFromString("page:"), with: gesture)
      try await Task.sleep(for: .milliseconds(fast ? 8 : 40))
    }
    gesture.speed = fast && !cancel ? direction * 900 : 0
    gesture.phase = .ended
    space.perform(NSSelectorFromString("page:"), with: gesture)
    try await SwipeGesture.waitForCompletion(in: parent)
  }

  private func prove(_ count: Int) async throws {
    try await open(count)
    print("SWIPE READY tabs=\(count) grids=\(space.tabs.map { "\($0.current.cols)x\($0.current.rows)" })")
    print("SWIPE SURFACE pixels=\(try XCTUnwrap(window).screen.nativeBounds) points=\(space.view.bounds)")
    let probe = KeyboardContinuityProbe(space)
    for fast in [false, true] {
      for direction: CGFloat in [-1, 1] {
        for _ in 1..<count {
          let source = space.focusedTab
          try await swipe(direction, fast: fast, cancel: true)
          XCTAssertTrue(space.focusedTab === source)
          try await swipe(direction, fast: fast, cancel: false)
          XCTAssertFalse(space.focusedTab === source)
        }
      }
    }
    probe.stop()
    print("SWIPE RESULT tabs=\(count) frames=\(probe.frames) hides=\(probe.hides) advisoryShows=\(probe.shows) movedFrames=\(probe.changes.count) grids=\(gridEvents)")
    XCTAssertEqual(gridEvents, [])
    for (index, name) in names.enumerated() {
      let resizes = try await resizeCount(name)
      print("SWIPE REMOTE tab=\(index + 1) resizes=\(resizes)")
      XCTAssertEqual(resizes, 0, "remote program resized during a swipe")
    }
    if count == 2 { try await filesFieldReturnsFocus() }
  }

  private func filesFieldReturnsFocus() async throws {
    let directory = "/tmp/" + keyName
    _ = try await execute("mkdir -p \(directory); touch \(directory)/note.txt")
    let terminal = try XCTUnwrap(space.focusedTab?.view)
    space.openMenu(.files)
    let deadline = Date.now.addingTimeInterval(10)
    while space.menu.shownBrowser == nil, Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let browser = try XCTUnwrap(space.menu.shownBrowser)
    browser.go(directory)
    await browser.load(directory)
    browser.renaming = directory + "/note.txt"
    try await Task.sleep(for: .seconds(1))
    func renameField(in view: UIView) -> UITextField? {
      if let field = view as? UITextField, field.placeholder == "Name" { return field }
      return view.subviews.lazy.compactMap { renameField(in: $0) }.first
    }
    let field = try XCTUnwrap(renameField(in: space.view))
    XCTAssertTrue(field.isFirstResponder)
    XCTAssertFalse(terminal.isFirstResponder)
    let start = field.beginningOfDocument
    field.selectedTextRange = field.textRange(from: start, to: try XCTUnwrap(field.position(from: start, offset: 4)))
    field.insertText("swipe")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(field.text, "swipe.txt")
    space.closeMenu()
    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(terminal.isFirstResponder)
    XCTAssertFalse(field.isFirstResponder)
    _ = try await execute("test -f \(directory)/swipe.txt")
  }

  func testTwoRemoteTabsNeverResizeDuringSwipes() async throws { try await prove(2) }
  func testThreeRemoteTabsNeverResizeDuringSwipes() async throws { try await prove(3) }
}
