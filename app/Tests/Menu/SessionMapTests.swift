import XCTest
@testable import Term

final class SessionMapTests: XCTestCase {
  private let api = Host(alias: "api-box", hostname: "10.0.0.2", user: "dev")
  private let ssh = Host(alias: "e2e", hostname: "127.0.0.1", port: 22622, user: "u", transport: .ssh)
  private let mosh = Host(alias: "e2em", hostname: "127.0.0.1", port: 22622, user: "u", transport: .mosh)

  private func session(_ id: String, _ name: String, activity: TimeInterval = 100, attached: Int = 0,
                       path: String = "/home/u") -> Tmux.Session {
    Tmux.Session(id: id, name: name, windows: 1, attached: attached, created: Date(timeIntervalSince1970: 1),
                 lastActivity: Date(timeIntervalSince1970: activity), command: "zsh", path: path,
                 width: 80, height: 24, cursorX: 0, cursorY: 0)
  }

  private func tab(_ host: Host?, _ tmux: String?, connected: Bool = true) -> SessionMap.TabRef {
    SessionMap.TabRef(id: UUID(), host: host, tmuxSession: tmux, isConnected: connected)
  }

  private func ids(_ group: SessionMap.Group) -> [String] {
    group.items.map {
      switch $0 {
      case .tab(_, let s, _): "tab:\(s?.name ?? "-")"
      case .session(let s, _): s.name
      }
    }
  }

  /// Open tabs lead their host's group; its other sessions follow, most recent first.
  func testHostGroupShowsOpenTabsThenOtherSessions() {
    let t = tab(mosh, "web")
    let listed = [session("$1", "notes", activity: 300), session("$2", "web", activity: 200), session("$3", "ops", activity: 100)]
    let groups = SessionMap.groups(tabs: [t], current: t.id, hosts: [], sessions: [mosh.serverKey: listed], expanded: [])
    XCTAssertEqual(groups.map(\.id), [mosh.serverKey, SessionMap.localID])
    XCTAssertEqual(ids(groups[0]), ["tab:web", "notes", "ops"])
  }

  /// The bug: a session open in a tab also showed as a snapshot beside it.
  func testSessionOpenInATabIsNotAlsoASnapshot() {
    let a = tab(mosh, "api"), b = tab(mosh, "web")
    let listed = [session("$1", "api"), session("$2", "web"), session("$3", "ops")]
    let groups = SessionMap.groups(tabs: [a, b], current: a.id, hosts: [mosh], sessions: [mosh.serverKey: listed], expanded: [])
    XCTAssertEqual(ids(groups[0]), ["tab:api", "tab:web", "ops"])
  }

  func testCurrentTabsGroupComesFirstThenTabOrderThenSavedHosts() {
    let local = tab(nil, nil, connected: false), remote = tab(api, nil)
    let groups = SessionMap.groups(tabs: [local, remote], current: remote.id, hosts: [mosh, api], sessions: [:], expanded: [])
    XCTAssertEqual(groups.map(\.id), [api.serverKey, SessionMap.localID, mosh.serverKey])
    let other = SessionMap.groups(tabs: [local, remote], current: local.id, hosts: [mosh, api], sessions: [:], expanded: [])
    XCTAssertEqual(other.map(\.id), [SessionMap.localID, api.serverKey, mosh.serverKey])
  }

  /// Tabs keep their own order inside a group even when the current one is not first.
  func testTabsKeepTheirOrderInsideAGroup() {
    let a = tab(mosh, "a"), b = tab(mosh, "b")
    let groups = SessionMap.groups(tabs: [a, b], current: b.id, hosts: [], sessions: [:], expanded: [])
    XCTAssertEqual(ids(groups[0]), ["tab:-", "tab:-"])
    XCTAssertEqual(groups[0].items.map(\.id), ["tab:\(a.id.uuidString)", "tab:\(b.id.uuidString)"])
  }

  /// ssh and mosh aliases of one machine reach one tmux server: one group,
  /// attaching through the transport of the tab already open there.
  func testHostsSharingAServerShowOnce() {
    let t = tab(mosh, "a")
    let groups = SessionMap.groups(tabs: [t], current: t.id, hosts: [ssh, mosh], sessions: [:], expanded: [])
    XCTAssertEqual(groups.map(\.id), [mosh.serverKey, SessionMap.localID])
    let saved = SessionMap.groups(tabs: [], current: nil, hosts: [ssh, mosh], sessions: [:], expanded: [])
    XCTAssertEqual(saved.map(\.id), [SessionMap.localID, ssh.serverKey])
    XCTAssertEqual(saved[1].host?.alias, "e2e")
  }

  /// A host without tabs costs nothing until he opens it; one with tabs is always open.
  func testHostsWithoutTabsAreCollapsedUntilExpanded() {
    let t = tab(api, nil)
    let groups = SessionMap.groups(tabs: [t], current: t.id, hosts: [api, mosh], sessions: [:], expanded: [api.serverKey])
    XCTAssertEqual(groups.map(\.collapsed), [false, false, true])
    let expanded = SessionMap.groups(tabs: [], current: nil, hosts: [mosh], sessions: [:], expanded: [mosh.serverKey])
    XCTAssertEqual(expanded.map(\.collapsed), [false, false])
  }

  func testLocalGroupIsAlwaysThereAndNeverCollapsed() {
    let groups = SessionMap.groups(tabs: [], current: nil, hosts: [], sessions: [:], expanded: [])
    XCTAssertEqual(groups, [SessionMap.Group(id: SessionMap.localID, host: nil, items: [], collapsed: false)])
  }

  /// A tab whose session was killed elsewhere still shows (it is still open).
  func testTabWithoutAListedSessionStillShows() {
    let t = tab(mosh, "gone")
    let groups = SessionMap.groups(tabs: [t], current: t.id, hosts: [], sessions: [mosh.serverKey: [session("$1", "other")]], expanded: [])
    XCTAssertEqual(groups[0].items, [.tab(t.id, session: nil, others: 0), .session(session("$1", "other"), others: 0)])
  }

  /// Other clients = attached minus Term's connected tabs on it; a tab still
  /// connecting has not attached yet; never below zero.
  func testOthersCountsClientsBesidesTermsTabs() {
    let s = session("$1", "api", attached: 2)
    XCTAssertEqual(SessionMap.others(on: s, tabs: [tab(mosh, "api")]), 1)
    XCTAssertEqual(SessionMap.others(on: s, tabs: [tab(mosh, "api", connected: false)]), 2)
    XCTAssertEqual(SessionMap.others(on: s, tabs: [tab(mosh, "api"), tab(mosh, "api"), tab(mosh, "api")]), 0)
    XCTAssertEqual(SessionMap.others(on: s, tabs: [tab(mosh, "web")]), 2)
  }

  func testFoldersAreUniqueMostRecentFirstThenHome() {
    let listed = [session("$1", "a", activity: 100, path: "/srv/a"), session("$2", "b", activity: 300, path: "/srv/b"),
                  session("$3", "c", activity: 200, path: "/srv/a"), session("$4", "d", activity: 50, path: "")]
    XCTAssertEqual(SessionMap.folders(listed), ["/srv/b", "/srv/a", "~"])
    XCTAssertEqual(SessionMap.folders([]), ["~"])
  }

  /// Bug: a session in the remote home listed "~" twice (its "/Users/NAME"
  /// and home), and picking a folder typed "/private/tmp/…" instead of the "/tmp/…" shown.
  func testFoldersAreTheShownPathsOnce() {
    let listed = [session("$1", "a", activity: 300, path: "/Users/dev"), session("$2", "b", activity: 200, path: "/private/tmp/x"),
                  session("$3", "c", activity: 100, path: "/tmp/x")]
    XCTAssertEqual(SessionMap.folders(listed), ["~", "/tmp/x"])
  }

  func testShortPathShowsRemoteHomesAsTilde() {
    XCTAssertEqual(SessionMap.shortPath("/Users/dev/Projects/api"), "~/Projects/api")
    XCTAssertEqual(SessionMap.shortPath("/home/dev"), "~")
    XCTAssertEqual(SessionMap.shortPath("/root/x"), "~/x")
    XCTAssertEqual(SessionMap.shortPath("/rootkit"), "/rootkit")
    XCTAssertEqual(SessionMap.shortPath("/Users/"), "/Users/")
    XCTAssertEqual(SessionMap.shortPath("/srv/app"), "/srv/app")
  }

  /// Bug: a session in /tmp on a Mac showed as "/private/tmp", a path nobody types.
  func testShortPathShowsMacPrivateFoldersAsTyped() {
    XCTAssertEqual(SessionMap.shortPath("/private/tmp/term-demo/api"), "/tmp/term-demo/api")
    XCTAssertEqual(SessionMap.shortPath("/private/tmp"), "/tmp")
    XCTAssertEqual(SessionMap.shortPath("/private/var/log"), "/var/log")
    XCTAssertEqual(SessionMap.shortPath("/private/etc"), "/etc")
    XCTAssertEqual(SessionMap.shortPath("/private/tmpx"), "/private/tmpx")
    XCTAssertEqual(SessionMap.shortPath("/private"), "/private")
    XCTAssertEqual(SessionMap.shortPath("/tmp/x"), "/tmp/x")
  }

  /// Bug: a narrow tile cut the path in the middle ("sleep · /…m-demo/api");
  /// it gives up whole folders from the front instead, the last one kept.
  func testDetailsShortenThePathFromTheFrontAFolderAtATime() {
    var s = session("$1", "a", path: "/Users/dev/Projects/term/app")
    XCTAssertEqual(SessionMap.details(s), ["zsh · ~/Projects/term/app", "zsh · …/term/app", "zsh · …/app"])
    s.path = "/private/tmp/term-demo/api"
    s.command = "sleep"
    XCTAssertEqual(SessionMap.details(s), ["sleep · /tmp/term-demo/api", "sleep · …/term-demo/api", "sleep · …/api"])
    s.path = "/home/dev"
    XCTAssertEqual(SessionMap.details(s), ["sleep · ~"])
    s.path = "/"
    XCTAssertEqual(SessionMap.details(s), ["sleep · /"])
    s.path = ""
    XCTAssertEqual(SessionMap.details(s), ["sleep"])
    s.command = ""
    s.path = "/srv/a"
    XCTAssertEqual(SessionMap.details(s), ["/srv/a", "…/a"])
  }

  func testAgeAtItsBoundaries() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func age(_ seconds: TimeInterval) -> String { SessionMap.age(now.addingTimeInterval(-seconds), now: now) }
    XCTAssertEqual(age(-30), "now")
    XCTAssertEqual(age(59), "now")
    XCTAssertEqual(age(60), "1m")
    XCTAssertEqual(age(3599), "59m")
    XCTAssertEqual(age(3600), "1h")
    XCTAssertEqual(age(86399), "23h")
    XCTAssertEqual(age(86400), "1d")
  }
}
