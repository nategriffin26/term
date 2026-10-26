import XCTest
@testable import Term

/// Synthetic recordings: each 50 ms frame a square wave whose RMS is the given dBFS.
final class RecordingTests: XCTestCase {
  private let n = Recording.frameLength
  private let room: Float = -55

  private func frames(_ dB: Float, _ count: Int) -> [Float] {
    let a = powf(10, dB / 20)
    return (0..<count * n).map { $0 % 2 == 0 ? a : -a }
  }

  /// Speech: frames between -30 and -20 dBFS, never down to the room.
  private func speech(_ count: Int) -> [Float] {
    (0..<count).flatMap { frames($0 % 3 == 0 ? -30 : -20, 1) }
  }

  private func recording(_ samples: [Float]) -> Recording {
    var r = Recording()
    for at in stride(from: 0, to: samples.count, by: 1_600) { _ = r.append(samples[at..<min(at + 1_600, samples.count)]) }
    return r
  }

  /// The parts as frame ranges in the recording, from their samples.
  private func ranges(_ r: Recording) -> [Range<Int>] {
    r.parts().map { $0.startIndex / n..<($0.endIndex + n - 1) / n }
  }

  /// Catches made-up text for silence: a quiet room, digital silence and an
  /// empty recording have no parts, so nothing is sent.
  func testNothingOverTheRoomHasNoParts() {
    XCTAssertEqual(recording(frames(room, 200)).parts().count, 0)
    XCTAssertEqual(recording([Float](repeating: 0, count: 200 * n)).parts().count, 0)
    XCTAssertEqual(recording([]).parts().count, 0)
    XCTAssertEqual(recording(frames(room, 200) + frames(-40, 1) + frames(room, 100)).parts().count, 1, "one frame over the room counts")
  }

  /// Catches a very quiet room's own noise read as speech: a room at -90 dBFS
  /// with a hiss at -70 stays under the -55 dBFS line, so nothing is sent.
  func testHissInAVeryQuietRoomIsNotSpeech() {
    XCTAssertEqual(recording(frames(-90, 200) + frames(-70, 40) + frames(-90, 100)).parts().count, 0)
    XCTAssertEqual(recording(frames(-90, 200) + frames(-50, 40) + frames(-90, 100)).parts().count, 1, "-50 is over the line")
  }

  /// Catches the room sent with the speech (cost, and silence the model
  /// fills with words) or first and last sounds cut off: 0.3 s is kept
  /// before the first frame over the room and 0.5 s after the last.
  func testRoomIsTrimmedWithPadsKept() {
    let r = recording(frames(room, 40) + speech(100) + frames(room, 60))
    XCTAssertEqual(ranges(r), [34..<150])
    let edges = recording(speech(50) + frames(room, 3))
    XCTAssertEqual(edges.parts().map(\.count), [53 * n], "speech from the first frame to near the end keeps both ends")
    let partial = recording(frames(room, 40) + speech(20) + Array(frames(-20, 1).prefix(300)))
    XCTAssertEqual(partial.parts().last?.endIndex, partial.samples.count, "the last part keeps the samples of an unfinished frame")
  }

  /// Catches parts longer than a minute or a recording split needlessly:
  /// exactly 60 s goes as one part, a frame more as two.
  func testOneMinuteIsOnePart() {
    let minute = Recording.partFrames
    XCTAssertEqual(minute, 1_200, "a minute of 50 ms frames")
    XCTAssertEqual(ranges(recording(speech(minute))).count, 1)
    let over = ranges(recording(speech(minute + 1)))
    XCTAssertEqual(over.count, 2)
    XCTAssertTrue(over.allSatisfy { $0.count <= minute })
  }

  /// Catches words cut in half at a part's edge, parts over a minute, or
  /// audio lost or repeated between parts: 130 s of speech with a pause
  /// every 5 s goes as three parts, cut inside pauses, each a minute at
  /// most, end to end with nothing between them.
  func testLongRecordingIsCutInPauses() {
    var samples = frames(room, 20)
    var pauses: [Range<Int>] = []
    for _ in 0..<26 {
      samples += speech(80)
      let at = samples.count / n
      samples += frames(room, 20)
      pauses.append(at..<at + 20)
    }
    let parts = ranges(recording(samples))
    XCTAssertEqual(parts.count, 3)
    XCTAssertEqual(parts.first?.lowerBound, 14)
    XCTAssertEqual(parts.last?.upperBound, samples.count / n - 10)
    for (a, b) in zip(parts, parts.dropFirst()) {
      XCTAssertEqual(a.upperBound, b.lowerBound, "contiguous")
      XCTAssertTrue(pauses.contains { $0.contains(b.lowerBound) }, "cut at \(b.lowerBound) is in a pause")
    }
    XCTAssertTrue(parts.allSatisfy { $0.count <= Recording.partFrames })
  }

  /// Catches a cut in a short gap between words when a sentence's end is
  /// near: the longest pause near the even split wins.
  func testCutPrefersTheLongestPause() {
    // The even split (frame 947) falls on a 3-frame gap; a 16-frame pause sits 120 frames later.
    let samples = frames(room, 200) + speech(750) + frames(room, 3) + speech(117) + frames(room, 16) + speech(614)
    let parts = ranges(recording(samples))
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[1].lowerBound, 200 + 750 + 3 + 117 + 8, "the middle of the long pause")
  }

  /// Catches a recording with no pause at all sent as one part over a
  /// minute: it is cut at its quietest frame near the even split.
  func testSpeechWithoutPausesIsStillCut() {
    let samples = frames(room, 200) + frames(-20, 700) + frames(-25, 1) + frames(-20, 700)
    let parts = ranges(recording(samples))
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[1].lowerBound, 900, "the quietest frame")
    XCTAssertTrue(parts.allSatisfy { $0.count <= Recording.partFrames })
  }

  /// Catches a strip fed the wrong levels: one per whole frame, 0 at -60
  /// dBFS and below, 1 at -10 and above, an unfinished frame not yet.
  func testOneLevelPerFrameOnTheStripScale() {
    var r = Recording()
    let levels = r.append(frames(-60, 1) + frames(-35, 1) + frames(-10, 1) + frames(0, 1) + frames(-60, 1).dropLast(1))
    XCTAssertEqual(levels.count, 4)
    for (got, want) in zip(levels, [0, 0.5, 1, 1] as [Float]) { XCTAssertEqual(got, want, accuracy: 0.01) }
    XCTAssertEqual(r.append([0]).count, 1, "the unfinished frame completes")
  }
}

final class DictationPromptTests: XCTestCase {
  /// Catches a prompt over the measured size, or one cut mid-line: the
  /// screen's last lines that fit in 8,000 characters, whole.
  func testScreenIsCutAtALineBoundary() {
    let rest = Array(repeating: String(repeating: "b", count: 199), count: 39)
    let fits = ([String(repeating: "a", count: 200)] + rest).joined(separator: "\n")
    XCTAssertEqual(fits.count, 8_000)
    XCTAssertEqual(DictationPrompt.text(screen: fits, typed: ""), fits)
    let over = ([String(repeating: "a", count: 201)] + rest).joined(separator: "\n")
    XCTAssertEqual(DictationPrompt.text(screen: over, typed: ""), rest.joined(separator: "\n"))
  }

  /// Catches a screen of one line longer than the limit giving no prompt at all.
  func testOneLongLineKeepsItsEnd() {
    let line = String(repeating: "a", count: 9_000) + "end"
    XCTAssertEqual(DictationPrompt.text(screen: line, typed: ""), String(line.suffix(8_000)))
  }

  /// Catches the blank rows under a short screen and trailing spaces spent from the limit.
  func testTrailingSpacesAndBlankLinesAreDropped() {
    let screen = "~/src % ls   \nkubeconfig.yaml  zxq-deploy.sh  \n   \n\n\n"
    XCTAssertEqual(DictationPrompt.text(screen: screen, typed: ""), "~/src % ls\nkubeconfig.yaml  zxq-deploy.sh")
  }

  /// Catches the typed text lost, grown past 200 characters, or an empty prompt sent with nothing to say.
  func testTypedTextFollowsTheScreen() {
    XCTAssertEqual(DictationPrompt.text(screen: "$ ls", typed: "git status"), "$ ls\ngit status")
    XCTAssertEqual(DictationPrompt.text(screen: "", typed: "git status"), "git status")
    let typed = String(repeating: "x", count: 199) + "yz"
    XCTAssertEqual(DictationPrompt.text(screen: "", typed: typed), String(typed.suffix(200)))
    XCTAssertEqual(DictationPrompt.text(screen: "", typed: String(typed.prefix(200))).count, 200)
    XCTAssertEqual(DictationPrompt.text(screen: " \n\n", typed: ""), "")
  }
}
