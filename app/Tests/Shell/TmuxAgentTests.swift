import XCTest
@testable import Term

final class TmuxAgentTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_987_300)

  private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

  /// An agent-section line in `Tmux.agentFields` order.
  private func line(_ id: String = "$0", command: String = "omp", seen: String = "", session: String = "api",
                    title: String = "host.local", payload: String) -> String {
    "\(id)\t\(command)\t\(seen)\t\(session)\t\(title)\t\(payload)"
  }

  private func agents(_ lines: String...) -> [String: AgentInfo] {
    Tmux.parseAgents("\n" + lines.joined(separator: "\n") + "\n", now: now)
  }

  private func payload(state: String, t: Int = 1_792_987_290, stop: Int? = nil, extra: String = "") -> String {
    let stopField = stop.map { #","stop":{"at":\#($0),"why":"\#(state)"}"# } ?? ""
    return #"{"v":1,"state":"\#(state)","since":1792987200,"t":\#(t)\#(stopField)\#(extra)}"#
  }

  // MARK: - Real output

  /// Captured from tmux 3.6a running the agent section's list-panes against
  /// a private server: two panes of session api (the done payload is the
  /// extension's own, written by a throwaway omp; host name made neutral),
  /// and a session whose pane title still reads omp's while its pane runs zsh.
  func testRealAgentPanesOutput() {
    let out = "\u{1d}\n"
      + "$0\tzsh\t1792987242\tapi\thost.local\t"
      + #"{"v":1,"state":"done","since":1792987243,"t":1792987243,"pid":66258,"title":"\udb81\udde0 SHIP: Ask ship it with yes/no options","last":"Recorded: you chose Yes to \"Ship it?\"","took":26,"stop":{"at":1792987243,"why":"done"},"model":"Claude Haiku 5.5","think":"low","ctx":2,"cost":0.01,"cwd":"/tmp/omp-ext-test","branch":"ext-branch"}"#
      + "\n$0\tzsh\t1792987242\tapi\thost.local\t"
      + #"{"v":1,"state":"working","since":1792987270,"t":1792987270,"pid":66300,"doing":"Running tests","todo":[3,7,"Wire refresh"],"cwd":"/tmp/omp-ext-test"}"#
      + "\n$1\tzsh\t\tmy work\tπ ! Fix the café thing\t\n"
    let found = Tmux.parseAgents(Data(out.utf8), now: now)
    XCTAssertEqual(Set(found.keys), ["$0"], "a title left over at a shell is no agent")
    let done = try! XCTUnwrap(found["$0"])
    XCTAssertEqual(done.state, .done, "the finished agent he hasn't seen speaks for the session, not the working one")
    XCTAssertTrue(done.unread)
    XCTAssertEqual(done.session, "api")
    XCTAssertEqual(done.title, "SHIP: Ask ship it with yes/no options", "omp's icon goes: the menu's fonts lack it")
    XCTAssertEqual(done.answer, #"Recorded: you chose Yes to "Ship it?""#)
    XCTAssertEqual(done.took, 26)
    XCTAssertEqual(done.stoppedAt, at(1_792_987_243))
    XCTAssertEqual(done.since, at(1_792_987_243))
    XCTAssertEqual(done.model, "Claude Haiku 5.5")
    XCTAssertEqual(done.thinking, "low")
    XCTAssertEqual(done.context, 2)
    XCTAssertEqual(done.cost, 0.01)
    XCTAssertEqual(done.path, "/tmp/omp-ext-test")
    XCTAssertEqual(done.branch, "ext-branch")
    XCTAssertFalse(done.fromTitle)
  }

  func testWorkingCarriesStepTodoAndSubagents() {
    let a = agents(line(payload: payload(state: "working", extra: #","doing":"Running tests","todo":[3,7,"Wire refresh"],"subs":2"#)))["$0"]
    XCTAssertEqual(a?.state, .working)
    XCTAssertEqual(a?.doing, "Running tests")
    XCTAssertEqual(a?.todo, AgentInfo.Todo(done: 3, total: 7, current: "Wire refresh"))
    XCTAssertEqual(a?.subagents, 2)
    XCTAssertEqual(a?.unread, false)
  }

  func testTodoWithoutCurrentTask() {
    let a = agents(line(payload: payload(state: "working", extra: #","todo":[7,7,null]"#)))["$0"]
    XCTAssertEqual(a?.todo, AgentInfo.Todo(done: 7, total: 7, current: nil))
  }

  func testAskCarriesQuestionAndChoices() {
    let a = agents(line(seen: "1792987100", payload: payload(state: "ask", stop: 1_792_987_200,
                                                            extra: #","q":"Ship it?","opts":["Yes","No"]"#)))["$0"]
    XCTAssertEqual(a?.state, .ask)
    XCTAssertEqual(a?.question, "Ship it?")
    XCTAssertEqual(a?.options, ["Yes", "No"])
    XCTAssertEqual(a?.unread, true)
  }

  // MARK: - Unread

  /// Unread is "stopped after he last saw it": one second either side of @seen.
  func testUnreadOnlyWhenTheStopIsNewerThanSeen() {
    for (seen, unread) in [("1792987199", true), ("1792987200", false), ("1792987201", false), ("", true)] {
      let a = agents(line(seen: seen, payload: payload(state: "done", stop: 1_792_987_200)))["$0"]
      XCTAssertEqual(a?.unread, unread, "seen \(seen.isEmpty ? "never" : seen)")
    }
  }

  func testFractionalStopComparisonPreservesEqualityAndSubsecondOrder() {
    for (seen, unread) in [("1000", true), ("1000.000", true), ("1000.001", false), ("1000.002", false)] {
      let p = #"{"v":1,"state":"done","stop":{"at":1000.001,"why":"done"}}"#
      XCTAssertEqual(agents(line(seen: seen, payload: p))["$0"]?.unread, unread, seen)
    }
  }

  /// Captured from a real omp prompt immediately cancelled on a private tmux server.
  func testLiveSameSecondStopIsUnreadUntilAcknowledged() {
    let p = #"{"v":1,"state":"aborted","since":1792989716.768,"t":1792989716.789,"stop":{"at":1792989716.769,"why":"aborted"}}"#
    XCTAssertEqual(agents(line(seen: "1792989716.211", payload: p))["$0"]?.unread, true)
    XCTAssertEqual(agents(line(seen: "1792989716.769", payload: p))["$0"]?.unread, false)
  }

  func testEveryKindOfStopNotifies() {
    for state in ["done", "error", "aborted", "ask", "approval"] {
      XCTAssertEqual(agents(line(payload: payload(state: state, stop: 1_792_987_200)))["$0"]?.unread, true, state)
    }
  }

  /// He answered the ask on the Mac and it went back to work: the old stop
  /// left in the payload does not notify.
  func testWorkingOrIdleNeverNotifies() {
    for state in ["working", "idle"] {
      XCTAssertEqual(agents(line(payload: payload(state: state, stop: 1_792_987_200)))["$0"]?.unread, false, state)
    }
  }

  // MARK: - Exited

  /// omp died mid-turn: its heartbeat stops and the pane is back at a shell.
  /// Three heartbeats (90 s) without a write, one second either side.
  func testMidTurnSilentAndBackAtAShellIsExited() {
    let fresh = agents(line(command: "zsh", payload: payload(state: "working", t: 1_792_987_300 - 89)))["$0"]
    XCTAssertEqual(fresh?.state, .working)
    let stale = agents(line(command: "zsh", seen: "1792987000", payload: payload(state: "working", t: 1_792_987_300 - 91)))["$0"]
    XCTAssertEqual(stale?.state, .exited)
    XCTAssertEqual(stale?.stoppedAt, at(1_792_987_300 - 91))
    XCTAssertEqual(stale?.unread, true)
    let seen = agents(line(command: "-zsh", seen: "1792987250", payload: payload(state: "ask", t: 1_792_987_200, stop: 1_792_987_150)))["$0"]
    XCTAssertEqual(seen?.state, .exited, "a login shell counts")
    XCTAssertEqual(seen?.unread, false, "it died before he last looked")
  }

  /// A heartbeat can lag while omp is busy; omp still in the pane is alive.
  func testSilentButStillRunningIsNotExited() {
    XCTAssertEqual(agents(line(command: "omp", payload: payload(state: "working", t: 1_792_987_000)))["$0"]?.state, .working)
  }

  /// It had already stopped: that stop stands.
  func testAStoppedAgentThatDiedKeepsItsStop() {
    let a = agents(line(command: "zsh", payload: payload(state: "done", t: 1_792_987_000, stop: 1_792_987_000)))["$0"]
    XCTAssertEqual(a?.state, .done)
  }

  // MARK: - Title fallback

  func testOmpTitleWithoutTheExtension() {
    let cases: [(String, AgentInfo.State)] = [("π > Fix it", .idle), ("π ⠋ Fix it", .working), ("π ⠇ Fix it", .working), ("π ! Fix it", .ask)]
    for (title, state) in cases {
      let a = agents(line(title: title, payload: ""))["$0"]
      XCTAssertEqual(a?.state, state, title)
      XCTAssertEqual(a?.title, "Fix it", title)
      XCTAssertEqual(a?.fromTitle, true, title)
      XCTAssertEqual(a?.unread, false, "no stop time, no notification: \(title)")
    }
  }

  func testTitleFallbackDropsOmpsIcon() {
    XCTAssertEqual(agents(line(title: "π > \u{F043F} PI: Find logins", payload: ""))["$0"]?.title, "PI: Find logins")
  }

  func testOtherTitlesAreNoAgent() {
    for title in ["π ? Fix it", "π", "π ", "pi > Fix it", "host.local", "week.md - NVIM", ""] {
      XCTAssertNil(agents(line(title: title, payload: ""))["$0"], title)
    }
  }

  // MARK: - Hostile payloads

  func testGarbledPayloadFallsBackToTheTitle() {
    for bad in ["{not json", "[1,2]", "{}", #"{"state":"sleeping"}"#, #"{"state":"exited"}"#, #"{"state":3}"#, "null"] {
      let a = agents(line(title: "π ⠋ Fix it", payload: bad))["$0"]
      XCTAssertEqual(a?.state, .working, bad)
      XCTAssertEqual(a?.fromTitle, true, bad)
      XCTAssertNil(agents(line(payload: bad))["$0"], "\(bad) without omp's title")
    }
  }

  /// The extension escapes quotes, backslashes, newlines and every non-ASCII
  /// character (emoji as surrogate pairs), so the value survives any locale.
  func testEscapedStringsDecode() {
    let a = agents(line(payload: payload(state: "done", stop: 1_792_987_200,
                                         extra: #","last":"say \"hi\" \\ then\nbye caf\u00e9 \ud83d\ude00","title":"\u2014 dash""#)))["$0"]
    XCTAssertEqual(a?.answer, "say \"hi\" \\ then\nbye café 😀")
    XCTAssertEqual(a?.title, "— dash")
  }

  /// The payload starts at the last tab: a tab in the title can't split it.
  func testTabInTheTitleKeepsThePayload() {
    let a = agents(line(title: "a\tb", payload: payload(state: "done", stop: 1_792_987_200)))["$0"]
    XCTAssertEqual(a?.state, .done)
    XCTAssertEqual(a?.session, "api")
  }

  func testWrongTypesAreDroppedFieldByField() {
    let a = agents(line(payload: payload(state: "working", extra: #","ctx":"lots","todo":["a"],"opts":[1],"subs":null,"cost":"free""#)))["$0"]
    XCTAssertEqual(a?.state, .working)
    XCTAssertNil(a?.context)
    XCTAssertNil(a?.todo)
    XCTAssertEqual(a?.options, [])
    XCTAssertEqual(a?.subagents, 0)
    XCTAssertNil(a?.cost)
  }

  func testMalformedLinesAreSkipped() {
    let good = line("$4", payload: payload(state: "idle"))
    let found = agents("", "%1\tomp\t\tapi\tt\t{}", "$2\tomp", "garbage", good)
    XCTAssertEqual(Array(found.keys), ["$4"])
  }

  func testNoMarkNoAgents() {
    XCTAssertEqual(Tmux.parseAgents(Data(line(payload: payload(state: "idle")).utf8)), [:])
  }

  // MARK: - Several agents in a session

  func testTheAgentThatNeedsHimMostSpeaksForTheSession() {
    let seen = "1792987250"
    let found = agents(
      line(seen: seen, payload: payload(state: "working")),
      line(seen: seen, payload: payload(state: "done", stop: 1_792_987_100)),
      line(seen: seen, payload: payload(state: "ask", stop: 1_792_987_200)),
      line(seen: seen, payload: payload(state: "error", stop: 1_792_987_200))
    )
    XCTAssertEqual(found["$0"]?.state, .ask, "all seen: ask > error > done > working")
    let unread = agents(
      line(seen: seen, payload: payload(state: "ask", stop: 1_792_987_200)),
      line(seen: seen, payload: payload(state: "done", stop: 1_792_987_260))
    )
    XCTAssertEqual(unread["$0"]?.state, .done, "one he hasn't seen beats one he has")
  }

  // MARK: - Overview and commands

  func testOverviewCarriesAgentsBetweenListAndScreens() {
    let out = "$0\t100\t1\t0\t50\t80\t24\t3\t5\tomp\t/home/u\toff\tapi\n"
      + "\u{1d}\n" + line(payload: payload(state: "done", stop: 1_792_987_200)) + "\n"
      + "\u{1e}$0\nscreen row\n"
    guard case .success(let o) = Tmux.parseOverview(status: 0, output: Data(out.utf8), now: now) else { return XCTFail() }
    XCTAssertEqual(o.sessions.map(\.name), ["api"])
    XCTAssertEqual(o.agents["$0"]?.state, .done)
    XCTAssertEqual(o.screens, ["$0": "screen row"])
  }

  func testOverviewFromATmuxWithoutFiltersHasNoAgents() {
    let out = "$0\t100\t1\t0\t50\t80\t24\t3\t5\tzsh\t/home/u\toff\tapi\n\u{1d}\n\u{1e}$0\nrow\n"
    guard case .success(let o) = Tmux.parseOverview(status: 0, output: Data(out.utf8)) else { return XCTFail() }
    XCTAssertEqual(o.sessions.count, 1)
    XCTAssertEqual(o.agents, [:])
  }

  func testAgentsCommandListsTheParsersFieldsInOrder() {
    let command = Tmux.agentsCommand()
    let format = command.components(separatedBy: "-F '")[1].components(separatedBy: "'")[0]
    XCTAssertEqual(format.components(separatedBy: "\t"), Tmux.agentFields.map { "#{\($0)}" })
    XCTAssertEqual(Tmux.agentFields.last, "@agent", "the payload goes last")
    XCTAssertTrue(command.contains("list-panes -a -f '#{||:#{@agent},#{m:π *,#{pane_title}}}'"), command)
    XCTAssertTrue(command.hasPrefix(Tmux.path + "; printf '\\035\\n'; "), command)
    XCTAssertTrue(command.hasSuffix(" 2>/dev/null; exit 0"), command)
  }

  /// Agents come after the list's status check (a failed list still says
  /// why) and before the screens (their separator ends the list part).
  func testOverviewCommandListsAgentsAfterTheListAndBeforeTheScreens() {
    let command = Tmux.overviewCommand()
    let status = try! XCTUnwrap(command.range(of: "[ $s = 0 ] || exit $s"))
    let agents = try! XCTUnwrap(command.range(of: Tmux.agentsScript))
    let screens = try! XCTUnwrap(command.range(of: "capture-pane"))
    XCTAssertLessThan(status.upperBound, agents.lowerBound)
    XCTAssertLessThan(agents.upperBound, screens.lowerBound)
  }

  /// A delayed acknowledgement must clear only what he saw, never a later stop.
  func testSeenCommand() {
    XCTAssertEqual(Tmux.seenCommand(stops: ["$3": at(1_792_987_200.125)]),
                   #"\#(Tmux.path); tmux set-option -F -t '$3' @seen '#{?#{e|>|f|0:#{?@seen,#{@seen},0},1792987200.125},#{@seen},1792987200.125}'"#)
    XCTAssertEqual(Tmux.seenCommand(stops: [:]), Tmux.path)
  }

  // MARK: - Seen here before the host says so

  func testStopsSeenHereStayReadUntilANewerStop() {
    let done = agents(line(payload: payload(state: "done", stop: 1_792_987_200)))
    XCTAssertEqual(TmuxList.unseen(done, seen: ["$0": at(1_792_987_200)])["$0"]?.unread, false)
    XCTAssertEqual(TmuxList.unseen(done, seen: ["$0": at(1_792_987_199)])["$0"]?.unread, true, "it stopped again after")
    XCTAssertEqual(TmuxList.unseen(done, seen: ["$9": at(1_792_987_200)])["$0"]?.unread, true, "another session's")
    XCTAssertEqual(TmuxList.unseen(done, seen: [:])["$0"]?.unread, true)
  }

  func testPlainTitle() {
    XCTAssertEqual(Tmux.plainTitle("\u{F0D57} \u{E0A0}  Ship it "), "Ship it")
    XCTAssertEqual(Tmux.plainTitle("Ship \u{F0D57} it"), "Ship \u{F0D57} it", "only in front")
    XCTAssertNil(Tmux.plainTitle("\u{F0D57} "))
  }
}
