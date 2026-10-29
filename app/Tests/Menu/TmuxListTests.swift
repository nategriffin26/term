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

  // MARK: - One server reached through two hosts

  private let mac = Host(alias: "mac", hostname: "mac.example", user: "u")
  private let backup = Host(alias: "backup", hostname: "backup.example", user: "u")
  private let sameServer = ["u@mac.example:22": "box\t100\t/tmp/tmux-1/default", "u@backup.example:22": "box\t100\t/tmp/tmux-1/default"]

  /// Bug it catches: a backup route to the same Mac listed the Mac's sessions
  /// a second time, and its agents counted twice in the badge.
  func testHostsReportingOneServerShowOnceAsTheFirstSaved() {
    XCTAssertEqual(TmuxList.servers([mac, backup], identities: sameServer).map(\.alias), ["mac"])
    XCTAssertEqual(TmuxList.servers([backup, mac], identities: sameServer).map(\.alias), ["backup"])
    // Another pid, socket or machine is another server.
    var other = sameServer
    other["u@backup.example:22"] = "box\t101\t/tmp/tmux-1/default"
    XCTAssertEqual(TmuxList.servers([mac, backup], identities: other).map(\.alias), ["mac", "backup"])
    // A host that has not answered yet is not known to share anything.
    XCTAssertEqual(TmuxList.servers([mac, backup], identities: ["u@mac.example:22": "x"]).map(\.alias), ["mac", "backup"])
    XCTAssertEqual(TmuxList.servers([mac, backup]).map(\.alias), ["mac", "backup"])
  }

  /// Bug it catches: with the Mac unreachable the backup stayed hidden, and no
  /// sessions showed at all, which is what the backup is for.
  func testTheBackupShowsWhileTheFirstIsDown() {
    XCTAssertEqual(TmuxList.servers([mac, backup], identities: sameServer, down: ["u@mac.example:22"]).map(\.alias), ["mac", "backup"])
    XCTAssertEqual(TmuxList.servers([mac, backup], identities: sameServer, down: ["u@backup.example:22"]).map(\.alias), ["mac"])
    // A third route hides behind whichever shown one is up.
    let third = Host(alias: "third", hostname: "third.example", user: "u")
    var three = sameServer
    three["u@third.example:22"] = sameServer["u@mac.example:22"]
    XCTAssertEqual(TmuxList.servers([mac, backup, third], identities: three, down: ["u@mac.example:22"]).map(\.alias), ["mac", "backup"])
  }

  /// Bug it catches: `tmux backup` led nothing because that host was hidden.
  func testAHiddenHostAskedForLeadsAsTheOneThatShowsItsServer() {
    let web = Host(alias: "web-box", hostname: "10.0.0.3", user: "dev")
    XCTAssertEqual(TmuxList.servers([web, mac, backup], first: backup.serverKey, identities: sameServer).map(\.alias), ["mac", "web-box"])
  }

  /// Bug it catches: the badge read 2 for one finished agent seen through two hosts.
  func testAServerReachedTwiceCountsItsUnreadAgentsOnce() {
    var done = AgentInfo(session: "api", state: .done)
    done.unread = true
    var seen = done
    seen.unread = false
    let agents = ["u@mac.example:22": ["$0": done, "$1": seen], "u@backup.example:22": ["$0": done, "$1": seen]]
    XCTAssertEqual(TmuxList.unread(agents, on: TmuxList.servers([mac, backup], identities: sameServer)), 1)
    XCTAssertEqual(TmuxList.unread(agents, on: [mac, backup]), 2)
    XCTAssertEqual(TmuxList.unread([:], on: [mac]), 0)
  }

  /// The host that speaks for a hidden one is the shown host that is up.
  func testTheSpeakerForAHostIsTheShownOneOnItsServer() {
    let shown = [mac]
    XCTAssertEqual(TmuxList.speaker(for: backup, among: shown, identities: sameServer).alias, "mac")
    XCTAssertEqual(TmuxList.speaker(for: mac, among: shown, identities: sameServer).alias, "mac")
    XCTAssertEqual(TmuxList.speaker(for: backup, among: shown, identities: [:]).alias, "backup")
    XCTAssertEqual(TmuxList.speaker(for: mac, among: [mac, backup], identities: sameServer, down: ["u@mac.example:22"]).alias, "backup")
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

  // MARK: - Agent rows

  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func agent(_ state: AgentInfo.State, unread: Bool = false, since: TimeInterval = 720) -> AgentInfo {
    var agent = AgentInfo(session: "api", state: state, since: now.addingTimeInterval(-since))
    agent.unread = unread
    return agent
  }

  /// The session behind the rows below: last output 25 minutes ago.
  private var quiet: Tmux.Session { session("$1", "api", activity: 1_000_000 - 1500) }

  /// Bug it catches: a stop he has seen keeps saying "finished" (or a stop
  /// he hasn't reads as a bare age), so the row lies about needing him.
  func testAStopReadsAsItsWordUntilSeenThenAsItsAge() {
    XCTAssertEqual(TmuxList.status(agent(.done, unread: true), quiet, now: now), .finished)
    XCTAssertEqual(TmuxList.status(agent(.error, unread: true), quiet, now: now), .failed("Failed"))
    XCTAssertEqual(TmuxList.status(agent(.exited, unread: true), quiet, now: now), .failed("Exited"))
    XCTAssertEqual(TmuxList.status(agent(.aborted, unread: true), quiet, now: now), .stopped)
    for state in [AgentInfo.State.done, .error, .exited, .aborted, .idle] {
      XCTAssertEqual(TmuxList.status(agent(state), quiet, now: now), .age("25m"), "\(state) once seen")
    }
    XCTAssertEqual(TmuxList.status(nil, quiet, now: now), .age("25m"), "a shell")
  }

  /// Bug it catches: entering a session (which marks it seen) hides that
  /// omp still waits on an unanswered question.
  func testAQuestionWaitsUntilAnsweredSeenOrNot() {
    XCTAssertEqual(TmuxList.status(agent(.ask), quiet, now: now), .waits("Asks you"))
    XCTAssertEqual(TmuxList.status(agent(.ask, unread: true), quiet, now: now), .waits("Asks you"))
    XCTAssertEqual(TmuxList.status(agent(.approval), quiet, now: now), .waits("Approve"))
  }

  /// Bug it catches: the wash outlives the finish he has now seen, or lands
  /// behind needs you, a failure or a shell, so finished and working stop
  /// standing out from everything else.
  func testOnlyAnUnseenFinishAndWorkUnderWayAreWashed() {
    XCTAssertEqual(TmuxList.wash(agent(.done, unread: true)), .finished)
    XCTAssertEqual(TmuxList.wash(agent(.working)), .working)
    XCTAssertEqual(TmuxList.wash(agent(.working, unread: true)), .working)
    XCTAssertNil(TmuxList.wash(agent(.done)), "a finish once seen")
    for state in [AgentInfo.State.ask, .approval, .error, .exited, .aborted, .idle] {
      XCTAssertNil(TmuxList.wash(agent(state, unread: true)), "\(state)")
    }
    XCTAssertNil(TmuxList.wash(nil), "a shell")
  }

  /// Bug it catches: a working agent's time counted from the session's last
  /// output (seconds ago while it prints) instead of when the turn began.
  func testWorkingShowsTimeSinceItBegan() {
    XCTAssertEqual(TmuxList.status(agent(.working, since: 720), quiet, now: now), .working(elapsed: "12m"))
  }

  /// Bug it catches: every agent row grows a second line (or a stop he
  /// hasn't seen grows none), and a multi-line answer breaks the line.
  func testOnlyAnUnreadStopGrowsASecondLine() {
    var ask = agent(.ask, unread: true)
    ask.question = "Keep the old /v1 URLs as redirects?"
    ask.answer = "an older answer"
    XCTAssertEqual(TmuxList.note(ask), "Keep the old /v1 URLs as redirects?")
    ask.unread = false
    XCTAssertNil(TmuxList.note(ask), "seen: the pill says it, one line")
    var done = agent(.done, unread: true)
    done.answer = "Totals now round per line.\n\n  14 tests added,\tall green."
    XCTAssertEqual(TmuxList.note(done), "Totals now round per line. 14 tests added, all green.")
    done.answer = " \n "
    XCTAssertNil(TmuxList.note(done), "a blank answer adds no empty line")
    var working = agent(.working)
    working.answer = "last turn's answer"
    XCTAssertNil(TmuxList.note(working))
    XCTAssertNil(TmuxList.note(nil))
  }

  /// Bug it catches: the preview shows empty or invented values ("$0.00",
  /// "took 0s" while it works) for what the agent never reported.
  func testPreviewFactsOnlyWhatIsKnown() {
    var done = agent(.done, since: 60)
    done.model = "Opus 5.5"
    done.thinking = "high"
    done.context = 21
    done.cost = 0.837
    done.took = 1080
    done.branch = "fix-rounding"
    done.path = "/Users/dev/billing"
    XCTAssertEqual(TmuxList.facts(done, quiet, now: now), [
      .init(label: "model", value: "Opus 5.5 · high"), .init(label: "context", value: "21%"),
      .init(label: "cost", value: "$0.84"), .init(label: "took", value: "18m"),
      .init(label: "branch", value: "fix-rounding"), .init(label: "path", value: "~/billing"),
    ])
    var working = agent(.working, since: 4800)
    working.took = 30
    working.branch = ""
    XCTAssertEqual(TmuxList.facts(working, quiet, now: now), [
      .init(label: "elapsed", value: "1h 20m"), .init(label: "path", value: "~"),
    ], "while it works: how long so far, the session's folder when it sent none")
  }

  func testDurationAtItsBoundaries() {
    XCTAssertEqual(TmuxList.duration(-5), "0s")
    XCTAssertEqual(TmuxList.duration(59), "59s")
    XCTAssertEqual(TmuxList.duration(60), "1m")
    XCTAssertEqual(TmuxList.duration(3599), "59m")
    XCTAssertEqual(TmuxList.duration(3600), "1h")
    XCTAssertEqual(TmuxList.duration(3660), "1h 1m")
    XCTAssertEqual(TmuxList.duration(86399), "23h 59m")
    XCTAssertEqual(TmuxList.duration(86400), "1d")
  }

  /// Bug it catches: one long session name pushes every title off a phone's row.
  func testNameColumnFitsTheLongestNameUpToACap() {
    XCTAssertEqual(TmuxList.nameColumn([]), 4)
    XCTAssertEqual(TmuxList.nameColumn(["ab", "web"]), 4)
    XCTAssertEqual(TmuxList.nameColumn(["web", "billing"]), 7)
    XCTAssertEqual(TmuxList.nameColumn(["fourteen-chars"]), 14)
    XCTAssertEqual(TmuxList.nameColumn(["fifteen-chars-x"]), 14)
    XCTAssertEqual(TmuxList.nameColumn(["café"]), 4, "counted in characters, not bytes")
  }

  // MARK: - Remembered identities

  @MainActor
  private func store(_ remembered: [String: String]) -> TmuxStore {
    let defaults = UserDefaults(suiteName: "TmuxListTests.\(UUID().uuidString)")!
    defaults.set(remembered, forKey: "tmuxServerIdentities")
    return TmuxStore(defaults: defaults)
  }

  /// Bug it catches: after a relaunch both routes showed until the backup
  /// answered, and its agents counted, because nothing remembered who it was.
  @MainActor
  func testARememberedIdentityHidesTheDuplicateBeforeItAnswers() {
    let store = store(sameServer)
    XCTAssertEqual(store.shownHosts([mac, backup]).map(\.alias), ["mac"])
    XCTAssertTrue(store.sameServer(mac, backup))
    XCTAssertFalse(self.store([:]).sameServer(mac, backup))
    XCTAssertEqual(self.store([:]).shownHosts([mac, backup]).map(\.alias), ["mac", "backup"])
  }
}
