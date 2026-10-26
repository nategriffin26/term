import XCTest
@testable import Term

/// Synthetic level sequences: each frame is 50 ms of a square wave whose RMS is the given dBFS.
final class SpeechSegmenterTests: XCTestCase {
  private let n = SpeechSegmenter.frameLength

  private func frames(_ dB: Float, _ count: Int) -> [Float] {
    let a = powf(10, dB / 20)
    return (0..<count * n).map { $0 % 2 == 0 ? a : -a }
  }

  /// Speech as it really is: words at -20 dBFS with 50 ms dips between them.
  private func speech(_ count: Int) -> [Float] {
    (0..<count).flatMap { $0 % 5 == 4 ? frames(-40, 1) : frames(-20, 1) }
  }

  private let quiet: Float = -70

  /// Feeds frame by frame; returns each segment with the frame index that finished it.
  private func run(_ samples: [Float], chunk: Int? = nil) -> (segments: [[Float]], at: [Int]) {
    var s = SpeechSegmenter()
    var segments: [[Float]] = [], at: [Int] = []
    let step = chunk ?? n
    var i = 0
    while i < samples.count {
      let out = s.append(samples[i..<min(i + step, samples.count)])
      for seg in out.segments {
        segments.append(seg)
        at.append((i + step) / n)
      }
      i += step
    }
    return (segments, at)
  }

  /// Catches the wrong pause length: a segment ends on the 14th silent frame (0.7 s), not the 13th.
  func testSegmentEndsAfterSevenTenthsOfSilence() {
    let audio = frames(quiet, 40) + speech(20) + frames(quiet, 13)
    XCTAssertTrue(run(audio).segments.isEmpty, "0.65 s of silence must not end it")
    let (segments, at) = run(audio + frames(quiet, 1))
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(at, [40 + 20 + 14])
  }

  /// Catches lost first syllables or trailing silence sent upstream: 300 ms before
  /// the onset is kept (the onset frames included), and 200 ms after the last word.
  func testSegmentKeepsPreRollAndShortTail() {
    let (segments, _) = run(frames(quiet, 40) + speech(20) + frames(quiet, 20))
    XCTAssertEqual(segments.first?.count, (4 + 20 + 4) * n)
  }

  /// Catches a pause shorter than 0.7 s splitting a sentence.
  func testShortPauseKeepsOneSegment() {
    let (segments, _) = run(frames(quiet, 40) + speech(20) + frames(quiet, 13) + speech(20) + frames(quiet, 20))
    XCTAssertEqual(segments.count, 1)
  }

  /// Catches clicks becoming requests (and the prompt echo they cause): under 0.25 s of speech is dropped.
  func testUnderQuarterSecondOfSpeechIsDropped() {
    XCTAssertTrue(run(frames(quiet, 40) + frames(-20, 4) + frames(quiet, 20)).segments.isEmpty)
    XCTAssertEqual(run(frames(quiet, 40) + frames(-20, 5) + frames(quiet, 20)).segments.count, 1)
    XCTAssertTrue(run(frames(quiet, 40) + frames(-20, 1) + frames(quiet, 20)).segments.isEmpty)
  }

  /// Catches silence or steady room noise being sent: neither makes a segment, nor does finishing.
  func testSilenceAndSteadyNoiseMakeNothing() {
    for audio in [frames(quiet, 200), frames(-40, 200), [Float](repeating: 0, count: 200 * n)] {
      var s = SpeechSegmenter()
      XCTAssertTrue(s.append(audio).segments.isEmpty)
      XCTAssertNil(s.finish())
    }
  }

  /// Catches a noisy room hiding speech: words well over a -40 dBFS fan still cut a segment.
  func testSpeechOverNoiseIsFound() {
    let words = (0..<20).flatMap { $0 % 5 == 4 ? frames(-40, 1) : frames(-15, 1) }
    XCTAssertEqual(run(frames(-40, 80) + words + frames(-40, 20)).segments.count, 1)
  }

  /// Catches losing the start when speech begins the moment listening does.
  func testSpeechFromTheFirstFrameKeepsItsStart() {
    let (segments, _) = run(speech(20) + frames(quiet, 20))
    XCTAssertEqual(segments.count, 1)
    XCTAssertGreaterThanOrEqual(segments[0].count, 20 * n)
  }

  /// Catches segments past the upstream 60 s timeout: talking without pauses is cut at 30 s, losing nothing.
  func testLongSpeechIsCutAtThirtySeconds() {
    var s = SpeechSegmenter()
    var segments = s.append(frames(quiet, 40) + speech(700)).segments
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].count, 600 * n)
    if let rest = s.finish() { segments.append(rest) }
    XCTAssertEqual(segments.count, 2)
  }

  /// Catches the 15 s rule: a 0.3 s pause ends a long segment, but not a short one.
  func testShortPauseEndsOnlyLongSegments() {
    XCTAssertTrue(run(frames(quiet, 40) + speech(100) + frames(quiet, 6)).segments.isEmpty)
    XCTAssertEqual(run(frames(quiet, 40) + speech(310) + frames(quiet, 6)).segments.count, 1)
  }

  /// Catches samples lost between deliveries that are not whole frames.
  func testOddDeliverySizesGiveTheSameSegments() {
    let audio = frames(quiet, 40) + speech(20) + frames(quiet, 20)
    XCTAssertEqual(run(audio, chunk: 333).segments, run(audio).segments)
  }

  /// Catches a stop losing the last words: finish returns the segment in progress.
  func testFinishReturnsSpeechInProgress() {
    var s = SpeechSegmenter()
    _ = s.append(frames(quiet, 40) + speech(10))
    XCTAssertNotNil(s.finish())
    XCTAssertNil(s.finish())
  }

  /// Catches a level scale the strip cannot use: one level per frame, -60 → 0, -35 → 0.5, -10 → 1.
  func testOneLevelPerFrameOnTheStripScale() {
    var s = SpeechSegmenter()
    let levels = s.append(frames(-60, 1) + frames(-35, 1) + frames(-10, 1) + frames(0, 1) + frames(-60, 1).dropLast(1)).levels
    XCTAssertEqual(levels.count, 4)
    for (got, want) in zip(levels, [0, 0.5, 1, 1] as [Float]) { XCTAssertEqual(got, want, accuracy: 0.01) }
  }
}
