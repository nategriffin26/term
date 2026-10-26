import XCTest
@testable import Term

final class TmuxListTests: XCTestCase {
  private let api = Host(alias: "api-box", hostname: "10.0.0.2", user: "dev")
  private let ssh = Host(alias: "e2e", hostname: "127.0.0.1", port: 22622, user: "u", transport: .ssh)
  private let mosh = Host(alias: "e2em", hostname: "127.0.0.1", port: 22622, user: "u", transport: .mosh)

  private func session(_ id: String, _ name: String, activity: TimeInterval = 100, attached: Int = 0,
                       path: String = "/home/u") -> Tmux.Session {
    Tmux.Session(id: id, name: name, windows: 1, attached: attached, created: Date(timeIntervalSince1970: 1),
                 lastActivity: Date(timeIntervalSince1970: activity), command: "zsh", path: path,
                 width: 80, height: 24, cursorX: 0, cursorY: 0)
  }

  /// Bug it catches: e2e (ssh) and e2em (mosh) reach one tmux server; listed
  /// twice, every session shows twice and closing one leaves its twin.
  func testHostsSharingAServerShowOnceAsTheFirstSaved() {
    XCTAssertEqual(TmuxList.servers([ssh, api, mosh]).map(\.alias), ["e2e", "api-box"])
    XCTAssertEqual(TmuxList.servers([mosh, ssh]).map(\.alias), ["e2em"])
    XCTAssertEqual(TmuxList.servers([]).map(\.alias), [])
    var otherPort = mosh
    otherPort.port = 22
    XCTAssertEqual(TmuxList.servers([mosh, otherPort]).count, 2)
    var otherUser = mosh
    otherUser.user = "root"
    XCTAssertEqual(TmuxList.servers([mosh, otherUser]).count, 2)
  }

  /// Bug it catches (seen on the sim): `tmux e2em` opened the tab scrolled
  /// part-way, e2em's head mid-screen (the List's scroll-to lands on
  /// estimated row heights). The host asked for leads the list instead,
  /// whichever of its aliases was typed; the rest keep their order.
  func testTheHostAskedForLeads() {
    let web = Host(alias: "web-box", hostname: "10.0.0.3", user: "dev")
    XCTAssertEqual(TmuxList.servers([api, web, mosh], first: mosh.serverKey).map(\.alias), ["e2em", "api-box", "web-box"])
    XCTAssertEqual(TmuxList.servers([api, ssh, web, mosh], first: mosh.serverKey).map(\.alias), ["e2e", "api-box", "web-box"])
    XCTAssertEqual(TmuxList.servers([api, web], first: web.serverKey).map(\.alias), ["web-box", "api-box"])
    XCTAssertEqual(TmuxList.servers([api, web], first: api.serverKey).map(\.alias), ["api-box", "web-box"])
    XCTAssertEqual(TmuxList.servers([api, web], first: "nobody@nowhere:22").map(\.alias), ["api-box", "web-box"])
    XCTAssertEqual(TmuxList.servers([api, web], first: nil).map(\.alias), ["api-box", "web-box"])
  }

  /// Other clients = attached minus Term's tabs on it, never below zero:
  /// Detach Others shows only when there is someone else to detach.
  func testOthersCountsClientsBesidesTerms() {
    let s = session("$1", "api", attached: 2)
    XCTAssertEqual(TmuxList.others(on: s, term: 0), 2)
    XCTAssertEqual(TmuxList.others(on: s, term: 1), 1)
    XCTAssertEqual(TmuxList.others(on: s, term: 2), 0)
    XCTAssertEqual(TmuxList.others(on: s, term: 3), 0)
  }

  /// Bug it catches: a stale session reads as fresh, or a fresh one as stale,
  /// at the one-day line.
  func testIdleAfterMoreThanADay() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func idle(_ seconds: TimeInterval) -> Bool { TmuxList.isIdle(session("$1", "a", activity: 1_000_000 - seconds), now: now) }
    XCTAssertFalse(idle(0))
    XCTAssertFalse(idle(86399))
    XCTAssertFalse(idle(86400))
    XCTAssertTrue(idle(86401))
    XCTAssertFalse(idle(-60))
  }

  /// Bug it catches: a refresh that started before a swipe-close returned
  /// the closed session, and its row came back for a refresh.
  func testClosedSessionsStayHiddenUntilTmuxStopsListingThem() {
    let listed = [session("$1", "api"), session("$2", "web"), session("$3", "ops")]
    let (shown, closing) = TmuxList.hide(["$2"], from: listed)
    XCTAssertEqual(shown.map(\.id), ["$1", "$3"])
    XCTAssertEqual(closing, ["$2"])
    // Gone from tmux: done, so a later session can never be hidden by it.
    let (after, done) = TmuxList.hide(closing, from: [session("$1", "api"), session("$3", "ops")])
    XCTAssertEqual(after.map(\.id), ["$1", "$3"])
    XCTAssertEqual(done, [])
    let (none, empty) = TmuxList.hide([], from: listed)
    XCTAssertEqual(none.map(\.id), ["$1", "$2", "$3"])
    XCTAssertEqual(empty, [])
    XCTAssertEqual(TmuxList.hide(["$9"], from: []).0, [])
  }

  /// Bug it catches (seen on the sim): api and ops print every 2-3 s, so
  /// sorting each refresh by activity swapped their rows, and a tap on ops's
  /// swipe Close landed on api. Rows hold their places; a new session goes
  /// first; one that ended leaves; each keeps tmux's latest values.
  func testRefreshKeepsTheOrderShown() {
    let shown = [session("$1", "api"), session("$2", "ops"), session("$3", "docs")]
    let fresh = [session("$2", "ops", activity: 300), session("$4", "new", activity: 250),
                 session("$1", "api-renamed", activity: 200)]
    let kept = TmuxList.keepOrder(shown, fresh)
    XCTAssertEqual(kept.map(\.id), ["$4", "$1", "$2"])
    XCTAssertEqual(kept.map(\.name), ["new", "api-renamed", "ops"])
    XCTAssertEqual(kept[2].lastActivity, Date(timeIntervalSince1970: 300))
    XCTAssertEqual(TmuxList.keepOrder([], fresh).map(\.id), ["$2", "$4", "$1"])
    XCTAssertEqual(TmuxList.keepOrder(shown, []).map(\.id), [])
  }

  /// Output recorded from tmux 3.6a `kill-session` on a `-L` server: a
  /// session already gone is closed, anything else is why it is still there.
  func testCloseComplaintIgnoresSessionsAlreadyGone() {
    XCTAssertNil(TmuxList.closeComplaint(Data()))
    XCTAssertNil(TmuxList.closeComplaint(Data("can't find session: $7\n".utf8)))
    XCTAssertNil(TmuxList.closeComplaint(Data("can't find session: $7\ncan't find session: $8\n".utf8)))
    XCTAssertEqual(TmuxList.closeComplaint(Data(
      "can't find session: $7\nerror connecting to /private/tmp/tmux-502/termtest (No such file or directory)\n".utf8)),
                   "tmux isn't running")
    XCTAssertEqual(TmuxList.closeComplaint(Data("zsh: command not found: tmux\n".utf8)), "zsh: command not found: tmux")
  }

  /// The window count rides at the end of every variant, so a narrow row
  /// gives up path folders before it; one window says nothing.
  func testDetailsEndWithTheWindowCountWhenMoreThanOne() {
    var s = session("$1", "a", path: "/srv/term/app")
    s.windows = 3
    XCTAssertEqual(TmuxList.details(s), ["zsh · /srv/term/app · 3 windows", "zsh · …/term/app · 3 windows", "zsh · …/app · 3 windows"])
    s.windows = 2
    s.path = ""
    XCTAssertEqual(TmuxList.details(s), ["zsh · 2 windows"])
    s.windows = 1
    XCTAssertEqual(TmuxList.details(s), ["zsh"])
    s.windows = 0
    XCTAssertEqual(TmuxList.details(s), ["zsh"])
  }

  func testShortPathShowsRemoteHomesAsTilde() {
    XCTAssertEqual(TmuxList.shortPath("/Users/dev/Projects/api"), "~/Projects/api")
    XCTAssertEqual(TmuxList.shortPath("/home/dev"), "~")
    XCTAssertEqual(TmuxList.shortPath("/root/x"), "~/x")
    XCTAssertEqual(TmuxList.shortPath("/rootkit"), "/rootkit")
    XCTAssertEqual(TmuxList.shortPath("/Users/"), "/Users/")
    XCTAssertEqual(TmuxList.shortPath("/srv/app"), "/srv/app")
  }

  /// Bug: a session in /tmp on a Mac showed as "/private/tmp", a path nobody types.
  func testShortPathShowsMacPrivateFoldersAsTyped() {
    XCTAssertEqual(TmuxList.shortPath("/private/tmp/term-demo/api"), "/tmp/term-demo/api")
    XCTAssertEqual(TmuxList.shortPath("/private/tmp"), "/tmp")
    XCTAssertEqual(TmuxList.shortPath("/private/var/log"), "/var/log")
    XCTAssertEqual(TmuxList.shortPath("/private/etc"), "/etc")
    XCTAssertEqual(TmuxList.shortPath("/private/tmpx"), "/private/tmpx")
    XCTAssertEqual(TmuxList.shortPath("/private"), "/private")
    XCTAssertEqual(TmuxList.shortPath("/tmp/x"), "/tmp/x")
  }

  /// Bug: a narrow tile cut the path in the middle ("sleep · /…m-demo/api");
  /// it gives up whole folders from the front instead, the last one kept.
  func testDetailsShortenThePathFromTheFrontAFolderAtATime() {
    var s = session("$1", "a", path: "/Users/dev/Projects/term/app")
    XCTAssertEqual(TmuxList.details(s), ["zsh · ~/Projects/term/app", "zsh · …/term/app", "zsh · …/app"])
    s.path = "/private/tmp/term-demo/api"
    s.command = "sleep"
    XCTAssertEqual(TmuxList.details(s), ["sleep · /tmp/term-demo/api", "sleep · …/term-demo/api", "sleep · …/api"])
    s.path = "/home/dev"
    XCTAssertEqual(TmuxList.details(s), ["sleep · ~"])
    s.path = "/"
    XCTAssertEqual(TmuxList.details(s), ["sleep · /"])
    s.path = ""
    XCTAssertEqual(TmuxList.details(s), ["sleep"])
    s.command = ""
    s.path = "/srv/a"
    XCTAssertEqual(TmuxList.details(s), ["/srv/a", "…/a"])
  }

  func testAgeAtItsBoundaries() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func age(_ seconds: TimeInterval) -> String { TmuxList.age(now.addingTimeInterval(-seconds), now: now) }
    XCTAssertEqual(age(-30), "now")
    XCTAssertEqual(age(59), "now")
    XCTAssertEqual(age(60), "1m")
    XCTAssertEqual(age(3599), "59m")
    XCTAssertEqual(age(3600), "1h")
    XCTAssertEqual(age(86399), "23h")
    XCTAssertEqual(age(86400), "1d")
  }
}
