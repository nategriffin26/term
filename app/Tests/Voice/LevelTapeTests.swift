import XCTest
@testable import Term

/// The listening trace's motion, frame by frame at 60 Hz, with levels
/// delivered as the microphone does (two every 100 ms) or late in bursts.
final class LevelTapeTests: XCTestCase {
  private let frame = 1.0 / 60

  /// Levels one per 50 ms: quiet, with one loud level at `loud`.
  private func level(_ i: Int, loud: Int) -> Float { i == loud ? 1 : 0.1 }

  /// What the microphone has delivered by `count` levels.
  private func heard(_ count: Int, loud: Int) -> HeardLevels {
    var heard = HeardLevels()
    heard.add((0..<count).map { level($0, loud: loud) })
    return heard
  }

  /// The loudest bar on screen at `t`: where it is and how high.
  private func loudest(_ tape: LevelTape, at t: Double) -> (offset: Double, level: Float) {
    (0..<40).map { tape.bar($0, at: t) }.compactMap { bar in bar.level.map { (bar.offset, $0) } }.max { $0.1 < $1.1 }!
  }

  /// Catches the old strip's stop-and-lurch: bars move exactly 40 pt a
  /// second on the display's clock, whether levels arrive every 100 ms, two
  /// at a time late, or in a burst after a 150 ms stall.
  func testScrollsAtFortyPointsASecondWhateverTheDeliveries() {
    // (display time, levels delivered by then): on time, then late, then a stall and a burst.
    let deliveries: [(Double, Int)] = [(0, 2), (0.1, 4), (0.2, 6), (0.33, 8), (0.36, 10), (0.55, 12), (0.56, 14), (0.6, 16)]
      + (7...30).map { (Double($0) * 0.1, 2 * ($0 + 1)) }
    var tape = LevelTape()
    var next = 0
    var last: (t: Double, offset: Double, level: Float)?
    var moves = 0
    for f in 0..<180 {
      let t = Double(f) * frame
      while next < deliveries.count, deliveries[next].0 <= t {
        tape.receive(heard(deliveries[next].1, loud: 9), at: deliveries[next].0)
        next += 1
      }
      guard t > 0.75 else { continue }
      let bar = loudest(tape, at: t)
      if let last {
        XCTAssertEqual(bar.offset - last.offset, LevelTape.speed * (t - last.t), accuracy: 1e-6, "at \(t) s")
        XCTAssertEqual(bar.level, last.level, "the loud bar's height at \(t) s")
        moves += 1
      }
      last = (t, bar.offset, bar.level)
    }
    XCTAssertEqual(LevelTape.speed, 40)
    XCTAssertGreaterThan(moves, 50)
  }

  /// Catches a delivery moving the trace: the bars' places at a moment are
  /// the same whether or not a delivery came just before it.
  func testDeliveriesNeverMoveTheBars() {
    var tape = LevelTape()
    tape.receive(heard(2, loud: 1), at: 10)
    let before = (0..<10).map { tape.bar($0, at: 10.25).offset }
    tape.receive(heard(6, loud: 1), at: 10.25)
    XCTAssertEqual((0..<10).map { tape.bar($0, at: 10.25).offset }, before)
  }

  /// Catches levels shown the moment they arrive (no time to absorb a late
  /// delivery) or long after: audio reaches the right edge 0.2 s after it
  /// arrived, and bars for audio before listening began show as dots.
  func testAudioReachesTheEdgeTwoTenthsOfASecondAfterArriving() {
    var tape = LevelTape()
    tape.receive(heard(2, loud: 1), at: 5)
    XCTAssertNil(tape.bar(0, at: 5).level, "nothing yet at the edge")
    XCTAssertNil(tape.bar(0, at: 5.19).level)
    // The second level (1 after 0.1) through the envelope: 0.06, then 0.06 + 0.94 × 0.6.
    let edge = tape.bar(0, at: 5.21)
    XCTAssertEqual(edge.level ?? -1, 0.624, accuracy: 1e-6)
    XCTAssertEqual(edge.offset, 0.4, accuracy: 1e-6)
    XCTAssertNil(tape.bar(1, at: 5.21).level, "before listening began")
  }

  /// Catches a jittery trace (every level shown raw) or a sluggish one: a
  /// rise covers 60% of the step in one level, a fall 25%.
  func testEnvelopeRisesFastAndFallsSlowly() {
    var tape = LevelTape()
    var heard = HeardLevels()
    heard.add([1, 1, 0, 0, 0, 0])
    tape.receive(heard, at: 0)
    // Bars show the envelope at the end of every second level: after 1, 1 → 0.84; after 0, 0 → 0.84 × 0.75².
    let t = 0.15
    XCTAssertEqual(tape.bar(1, at: t).level ?? -1, 0.84, accuracy: 1e-5)
    XCTAssertEqual(tape.bar(0, at: t).level ?? -1, 0.84 * 0.5625, accuracy: 1e-5)
  }

  /// Catches the trace freezing when the levels repeat (a steady room, digital
  /// silence): the old strip counted new levels by comparing windows, saw
  /// none, and stalled. Here a loud level decays through identical windows of silence.
  func testRepeatedLevelsStillArrive() {
    var tape = LevelTape()
    var heard = HeardLevels()
    heard.add([1, 1])
    tape.receive(heard, at: 0)
    heard.add([Float](repeating: 0, count: 40))
    tape.receive(heard, at: 2)
    let window = heard.recent
    heard.add([0, 0])
    XCTAssertEqual(heard.recent, window, "the window repeats")
    tape.receive(heard, at: 2.1)
    // The 44th level ends 2.2 s into the audio, at the edge 0.2 s after it arrived.
    XCTAssertEqual(tape.bar(0, at: 2.35).level ?? -1, 0.84 * powf(0.75, 42), accuracy: 1e-6)
  }
}
