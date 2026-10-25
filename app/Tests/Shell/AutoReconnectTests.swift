import XCTest
@testable import Term

final class ReconnectPolicyTests: XCTestCase {
  func testProbesOnlyAfterOneSecondUnreachable() {
    var p = ReconnectPolicy()
    XCTAssertFalse(p.shouldProbe(now: 100, unreachableFor: 0.9))
    XCTAssertTrue(p.shouldProbe(now: 100, unreachableFor: 1))
  }

  func testOneFlightAtATime() {
    var p = ReconnectPolicy()
    XCTAssertTrue(p.shouldProbe(now: 100, unreachableFor: 6))
    XCTAssertFalse(p.shouldProbe(now: 500, unreachableFor: 400))
    XCTAssertNil(p.delay(now: 500, unreachableFor: 400))
  }

  func testUnansweredProbeWaitsTenSeconds() {
    var p = ReconnectPolicy()
    XCTAssertTrue(p.shouldProbe(now: 100, unreachableFor: 6))
    p.probeFailed(now: 100)
    XCTAssertFalse(p.shouldProbe(now: 109.9, unreachableFor: 20))
    XCTAssertEqual(p.delay(now: 105, unreachableFor: 20), 5)
    XCTAssertTrue(p.shouldProbe(now: 110, unreachableFor: 20))
  }

  func testFailedReconnectsBackOffTenThirtySixtyThenStaySixty() {
    var p = ReconnectPolicy()
    var now: TimeInterval = 0
    for wait in [10, 30, 60, 60, 60] as [TimeInterval] {
      XCTAssertTrue(p.shouldProbe(now: now, unreachableFor: 100), "due at \(now)")
      p.reconnectFinished(now: now, succeeded: false)
      XCTAssertFalse(p.shouldProbe(now: now + wait - 0.1, unreachableFor: 1000), "too early after \(wait)")
      now += wait
    }
    XCTAssertTrue(p.shouldProbe(now: now, unreachableFor: 1000))
  }

  func testRecoveryClearsBackoff() {
    var p = ReconnectPolicy()
    for _ in 0..<3 {
      _ = p.shouldProbe(now: 0, unreachableFor: 100)
      p.reconnectFinished(now: 0, succeeded: false)
    }
    p.recovered()
    XCTAssertTrue(p.shouldProbe(now: 0, unreachableFor: 6))
    p.reconnectFinished(now: 0, succeeded: false)
    XCTAssertEqual(p.delay(now: 0, unreachableFor: 100), 10)
  }

  func testSucceededReconnectWaitsTenSecondsForTheNewServerToAnswer() {
    var p = ReconnectPolicy()
    _ = p.shouldProbe(now: 50, unreachableFor: 6)
    p.reconnectFinished(now: 50, succeeded: true)
    XCTAssertFalse(p.shouldProbe(now: 59, unreachableFor: 100))
    XCTAssertTrue(p.shouldProbe(now: 60, unreachableFor: 100))
  }

  func testDroppedProbeFreesTheFlightWithoutPenalty() {
    var p = ReconnectPolicy()
    _ = p.shouldProbe(now: 0, unreachableFor: 6)
    p.probeDropped()
    XCTAssertTrue(p.shouldProbe(now: 0, unreachableFor: 6))
  }
}

@MainActor
final class AutoReconnectTests: XCTestCase {
  private var now: TimeInterval = 1000
  private var probes = 0
  private var reconnects = 0
  private var hostAnswers = true
  private var eligible = true
  private var gate: CheckedContinuation<Void, Never>?
  private var holdProbe = false

  private func makeDriver() -> AutoReconnect {
    let driver = AutoReconnect(clock: { [unowned self] in now })
    driver.isEligible = { [unowned self] in eligible }
    driver.probe = { [unowned self] in
      probes += 1
      if holdProbe { await withCheckedContinuation { gate = $0 } }
      return hostAnswers
    }
    driver.reconnect = { [unowned self] in reconnects += 1 }
    return driver
  }

  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  /// Unreachable at t=0, then seen again `after` seconds later.
  private func silent(_ driver: AutoReconnect, for after: TimeInterval) async {
    driver.statusChanged(unreachable: true)
    now += after
    driver.statusChanged(unreachable: true)
    await settle()
  }

  func testReachableHostReconnectsOnce() async {
    let driver = makeDriver()
    await silent(driver, for: 6)
    XCTAssertEqual(reconnects, 1)
    now += 60
    driver.statusChanged(unreachable: true)
    await settle()
    XCTAssertEqual(probes, 1, "a reconnect in flight blocks a second probe")
    XCTAssertEqual(reconnects, 1)
  }

  func testUnreachableHostIsNotReconnected() async {
    hostAnswers = false
    let driver = makeDriver()
    await silent(driver, for: 6)
    XCTAssertEqual(probes, 1)
    XCTAssertEqual(reconnects, 0)
    now += 9
    driver.statusChanged(unreachable: true)
    await settle()
    XCTAssertEqual(probes, 1, "retry is 10 s after the failed probe")
    now += 1
    driver.statusChanged(unreachable: true)
    await settle()
    XCTAssertEqual(probes, 2)
  }

  func testSessionThatRecoversDuringProbeIsNotReconnected() async {
    holdProbe = true
    let driver = makeDriver()
    await silent(driver, for: 6)
    XCTAssertEqual(probes, 1)
    driver.statusChanged(unreachable: false)
    gate?.resume()
    await settle()
    XCTAssertEqual(reconnects, 0)
  }

  func testPlainShellNeverProbes() async {
    eligible = false
    let driver = makeDriver()
    await silent(driver, for: 600)
    XCTAssertEqual(probes, 0)
  }

  func testBackgroundedAppNeverProbesAndResumeRestartsTheClock() async {
    let driver = makeDriver()
    driver.statusChanged(unreachable: true)
    driver.suspended()
    now += 600
    driver.statusChanged(unreachable: true)
    await settle()
    XCTAssertEqual(probes, 0)
    driver.resumed()
    await settle()
    XCTAssertEqual(probes, 0, "the network was off while suspended: the silence clock starts at resume")
    now += ReconnectPolicy.silence
    driver.statusChanged(unreachable: true)
    await settle()
    XCTAssertEqual(probes, 1)
  }

  func testProbeFromAClosedSessionIsIgnored() async {
    holdProbe = true
    let driver = makeDriver()
    await silent(driver, for: 6)
    driver.stop()
    gate?.resume()
    await settle()
    XCTAssertEqual(reconnects, 0)
  }
}
