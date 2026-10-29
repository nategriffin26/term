import XCTest
@testable import Term

@MainActor
final class UsageCounterTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""
  private var clock = Date()
  private var sent: [RelayClient.Ping] = []
  private var relayAnswers = true

  override func setUp() {
    suite = "UsageCounterTests-" + UUID().uuidString
    defaults = UserDefaults(suiteName: suite)
    sent = []
    relayAnswers = true
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

  private func counter() -> UsageCounter {
    UsageCounter(defaults: defaults, now: { [unowned self] in clock }) { [unowned self] ping in
      guard relayAnswers else { return false }
      sent.append(ping)
      return true
    }
  }

  /// A counter he has turned on.
  private func optedIn() -> UsageCounter {
    let count = counter()
    count.setEnabled(true)
    return count
  }

  // Bug: a ping on the day itself sends a day's flags before the day is over.
  func testADayGoesOutOnlyAfterItEnds() async {
    let count = optedIn()
    clock = utc("2026-10-28T09:00:00Z")
    await count.becameActive()
    count.record(.hostOK)
    count.record(.askAnswered)
    await count.becameActive()
    XCTAssertEqual(sent.count, 0)

    clock = utc("2026-10-29T08:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent.first.map { [$0.host_ok, $0.screen_opened, $0.ask_answered] }, [true, false, true])
  }

  // UTC days: 23:59:59 and 00:00:00 are different days whatever the phone's zone.
  func testTheDayTurnsAtUTCMidnight() async {
    let count = optedIn()
    clock = utc("2026-10-28T23:59:59Z")
    await count.becameActive()
    count.record(.screenOpened)
    clock = utc("2026-10-29T00:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.map(\.screen_opened), [true])
  }

  func testAFailedSendIsRetriedAtTheNextChance() async {
    let count = optedIn()
    clock = utc("2026-10-28T09:00:00Z")
    await count.becameActive()
    count.record(.hostOK)
    clock = utc("2026-10-29T09:00:00Z")
    relayAnswers = false
    await count.becameActive()
    XCTAssertEqual(sent.count, 0)
    relayAnswers = true
    clock = utc("2026-10-29T10:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.map(\.host_ok), [true])
  }

  // At most one ping a day: later returns to the front that day send nothing more.
  func testOnePingPerDay() async {
    let count = optedIn()
    clock = utc("2026-10-28T09:00:00Z")
    await count.becameActive()
    clock = utc("2026-10-29T09:00:00Z")
    await count.becameActive()
    clock = utc("2026-10-29T18:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.count, 1)
  }

  // Policy: no backfill. Two finished days unsent: only the later goes, its flags its own.
  func testOnlyTheLatestFinishedDayIsSentAndNeverMerged() async {
    let count = optedIn()
    clock = utc("2026-10-20T09:00:00Z")
    count.record(.screenOpened)
    relayAnswers = false
    clock = utc("2026-10-21T09:00:00Z")
    await count.becameActive()
    count.record(.hostOK)
    relayAnswers = true
    clock = utc("2026-10-25T09:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent.first.map { [$0.host_ok, $0.screen_opened] }, [true, false])
  }

  // Policy: a day goes out under its own month's id. October's last day sent in
  // November keeps October's id; November's days get a new one.
  func testMonthlyIDNeverCarriesADayAcrossMonths() async {
    let count = optedIn()
    clock = utc("2026-10-30T09:00:00Z")
    await count.becameActive()
    clock = utc("2026-10-31T09:00:00Z")
    await count.becameActive()
    count.record(.askAnswered)
    clock = utc("2026-11-01T09:00:00Z")
    await count.becameActive()
    clock = utc("2026-11-02T09:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.count, 3)
    XCTAssertEqual(sent[0].install_id, sent[1].install_id, "both October days")
    XCTAssertTrue(sent[1].ask_answered)
    XCTAssertNotEqual(sent[1].install_id, sent[2].install_id, "November's day has November's id")
    XCTAssertFalse(sent[2].ask_answered)
    XCTAssertNotNil(UUID(uuidString: sent[2].install_id))
    XCTAssertEqual(sent[2].install_id, sent[2].install_id.lowercased())
  }

  // Turning it off erases the id and the flags; nothing is sent, and flags
  // gathered while off never count. Back on, a new id.
  func testOptOutErasesAndStopsSending() async {
    let count = optedIn()
    clock = utc("2026-10-28T09:00:00Z")
    await count.becameActive()
    count.record(.hostOK)
    let before = count.state.installID
    count.setEnabled(false)
    XCTAssertEqual(count.state, UsageCounter.State())
    XCTAssertNil(defaults.data(forKey: "usageCount").flatMap { try? JSONDecoder().decode(UsageCounter.State.self, from: $0) }?.installID)
    count.record(.screenOpened)
    clock = utc("2026-10-29T09:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.count, 0)

    count.setEnabled(true)
    await count.becameActive()
    clock = utc("2026-10-30T09:00:00Z")
    await count.becameActive()
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent.first.map { [$0.host_ok, $0.screen_opened] }, [false, false])
    XCTAssertNotEqual(sent.first?.install_id, before?.uuidString.lowercased())
  }

  // Off until he opts in: no id, nothing gathered, nothing sent, however long it runs.
  func testOffByDefaultCollectsAndSendsNothing() async {
    let count = counter()
    XCTAssertFalse(count.isEnabled)
    for day in ["2026-10-28", "2026-10-29", "2026-10-30"] {
      clock = utc(day + "T09:00:00Z")
      await count.becameActive()
      count.record(.hostOK)
      count.record(.screenOpened)
      count.record(.askAnswered)
    }
    XCTAssertEqual(count.state, UsageCounter.State())
    XCTAssertNil(defaults.object(forKey: "usageCount"))
    XCTAssertTrue(sent.isEmpty)
  }

  // Bug: state gathered under an earlier default survived while off and went out once turned on.
  func testStateStoredWhileOffIsDiscardedAtLaunch() async throws {
    let stale = UsageCounter.State(installID: UUID(), month: "2026-10",
                                   current: nil, finished: .init(date: "2026-10-27", installID: UUID(), flags: [.hostOK]))
    defaults.set(try JSONEncoder().encode(stale), forKey: "usageCount")
    let count = counter()
    XCTAssertEqual(count.state, UsageCounter.State())
    count.setEnabled(true)
    clock = utc("2026-10-28T09:00:00Z")
    await count.becameActive()
    XCTAssertTrue(sent.isEmpty)
  }

  // The switch and the gathered day survive a relaunch.
  func testStateSurvivesRelaunch() async {
    clock = utc("2026-10-28T09:00:00Z")
    optedIn().record(.screenOpened)
    let relaunched = counter()
    XCTAssertTrue(relaunched.isEnabled)
    clock = utc("2026-10-29T09:00:00Z")
    await relaunched.becameActive()
    XCTAssertEqual(sent.map(\.screen_opened), [true])

    relaunched.setEnabled(false)
    XCTAssertFalse(counter().isEnabled)
  }

  // The ping carries exactly the contract's keys: no dates, no device facts, no purchase state.
  func testPingHasOnlyTheContractKeys() throws {
    let ping = RelayClient.Ping(install_id: UUID().uuidString.lowercased(), host_ok: true, screen_opened: false,
                                ask_answered: false)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ping)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["install_id", "host_ok", "screen_opened", "ask_answered"])
  }
}
