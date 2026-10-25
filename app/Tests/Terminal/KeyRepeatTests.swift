import XCTest
@testable import Term

/// Timelines of `deleteBackward` calls as the iOS software keyboard makes them
/// (measured on iOS 27 in the simulator): one on touch down, one after 0.5 s,
/// then every 0.1 s; after about 2.1 s a pair 4 ms apart every 0.35 s.
final class KeyRepeatTests: XCTestCase {
  /// Characters typed for a series of calls: those typed at once plus every
  /// character the hold owes by the last call.
  private func typed(_ calls: [Double], delay: Double = 0.4, rate: Double = 25) -> Int {
    var tracker = HeldKeyTracker()
    var count = 0
    for t in calls {
      if case .emit = tracker.call(at: t, delay: delay, rate: rate) { count += 1 }
    }
    while tracker.takeOwed() { count += 1 }
    return count
  }

  private func held(until end: Double) -> [Double] {
    [0, 0.5] + (6...Int((end * 10).rounded())).map { Double($0) / 10 }
  }

  func testHeldKeyTypesAtTheConfiguredRateNotTheSystemsRate() {
    // Press, then the first repeat at 0.4 s, then 25 per second until 2.0 s: 1 + 1 + 1.6 * 25.
    XCTAssertEqual(typed(held(until: 2.0)), 42)
  }

  func testRateSettingChangesHowManyAreTyped() {
    XCTAssertEqual(typed(held(until: 2.0), rate: 10), 18)
    XCTAssertEqual(typed(held(until: 2.0), rate: 40), 66)
  }

  func testDelayLongerThanTheSystemsFirstRepeatStillCounts() {
    // The system's call at 0.5 s is typed (it cannot be told from a tap), the repeat starts at 0.8 s.
    XCTAssertEqual(typed(held(until: 2.0), delay: 0.8), 32)
  }

  func testSystemsSlowCadenceAfterTwoSecondsStaysOneHold() {
    var calls = held(until: 2.1)
    for k in 1...6 { calls += [2.1 + 0.35 * Double(k), 2.1 + 0.35 * Double(k) + 0.004] }
    // The last call is at 4.204 s: 1 + 1 + (4.204 - 0.4) * 25 = 97.
    XCTAssertEqual(typed(calls), 97)
  }

  func testSeparateTapsAreNeverHeld() {
    XCTAssertEqual(typed([0, 0.5, 1.0, 1.5, 2.0, 2.5]), 6)
    XCTAssertEqual(typed([0, 0.12, 0.24, 0.36, 0.48, 0.6, 0.72]), 7)
    XCTAssertEqual(typed([0, 0.2, 0.4, 0.6, 0.8, 1.0]), 6)
  }

  func testTapAfterReleaseIsATapNotMoreOfTheHold() {
    var tracker = HeldKeyTracker()
    for t in held(until: 1.0) { _ = tracker.call(at: t, delay: 0.4, rate: 25) }
    while tracker.takeOwed() {}
    guard case .emit = tracker.call(at: 1.25, delay: 0.4, rate: 25) else {
      return XCTFail("a press 0.25 s after the last system call was swallowed as part of the old hold")
    }
    XCTAssertFalse(tracker.isHeld)
    XCTAssertFalse(tracker.takeOwed())
  }

  func testRateChangeMidHoldOnlyAffectsTheTimeAfterIt() {
    var tracker = HeldKeyTracker()
    var count = 0
    for t in held(until: 2.0) {
      let rate = t <= 1.0 ? 10.0 : 40.0
      if case .emit = tracker.call(at: t, delay: 0.4, rate: rate) { count += 1 }
    }
    while tracker.takeOwed() { count += 1 }
    // 1 + 1 + (1.0 - 0.4) * 10 + (2.0 - 1.0) * 40 = 48.
    XCTAssertEqual(count, 48)
  }
}
