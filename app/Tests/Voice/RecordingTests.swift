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

  private func plan(_ samples: [Float]) -> Recording.Plan? { Recording.plan(loudness: recording(samples).loudness) }

  /// The recording's frame at `index` of the kept frames laid end to end.
  private func frame(_ index: Int, in plan: Recording.Plan) -> Int {
    var left = index
    for run in plan.kept {
      if left < run.count { return run.lowerBound + left }
      left -= run.count
    }
    return plan.kept.last!.upperBound
  }

  /// dBFS of the 90th-percentile frame of `samples`.
  private func level(_ samples: [Float]) -> Float {
    let dB = stride(from: 0, to: samples.count - n + 1, by: n).map { Recording.loudness(samples[$0..<$0 + n]) }.sorted()
    return dB[dB.count * 9 / 10]
  }

  /// Catches a recording with nothing to tell speech from room taken for
  /// silence: the user's "yes" from tap to tap came back "No speech". With
  /// no frame over the room (a word with no room around it, the room
  /// alone, digital silence) the whole recording is kept and leveled for the
  /// speech classifier to judge. Only an empty recording sends nothing; a
  /// word as short as 0.2 s over a room is kept with its pads.
  func testRecordingWithoutContrastIsSentWhole() {
    XCTAssertEqual(recording(speech(12)).parts().map(\.count), [12 * n], "a word from tap to tap")
    XCTAssertEqual(plan(speech(12))?.gain ?? 0, Recording.target + 20, accuracy: 0.01, "the word's loudest frames (-20 dBFS) to the target")
    XCTAssertEqual(recording(frames(room, 200)).parts().map(\.count), [200 * n], "the room alone")
    XCTAssertEqual(recording([Float](repeating: 0, count: 200 * n)).parts().map(\.count), [200 * n], "digital silence")
    XCTAssertEqual(recording([]).parts().count, 0)
    XCTAssertEqual(plan(frames(room, 200) + frames(-40, 4) + frames(room, 100))?.kept, [186..<218], "a short word")
  }

  /// Catches quiet speech dropped by a fixed loudness line: speech the
  /// microphone hears at -70 dBFS (a -55 dBFS line cut it, and speech up to
  /// -55 lost its ends) is sent whole, raised the most the gain allows.
  func testQuietSpeechIsKeptAtAnyLevel() {
    let quiet = plan(frames(-90, 200) + frames(-70, 40) + frames(-90, 100))
    XCTAssertEqual(quiet?.kept, [186..<254], "the speech, its 0.2 s of averaging and 0.5 s of pad either side")
    XCTAssertEqual(quiet?.gain, Recording.maxGain)
  }

  /// Catches a fixed loudness line under a loud room: under a fan at -40
  /// dBFS, speech 8 dB over it is kept with its pads and the fan is cut.
  func testRoomIsMeasuredFromTheRecording() {
    let fan = plan(frames(-40, 200) + frames(-32, 40) + frames(-40, 200))
    XCTAssertEqual(fan?.kept, [191..<249], "8 dB over the fan, a frame is sound once most of its 0.45 s average is speech")
  }

  /// Catches the room sent with the speech (cost, and silence the model
  /// fills with words) or first and last sounds cut off: 0.7 s is kept on
  /// each side of the speech (0.2 s of averaging and 0.5 s of pad), and
  /// speech from the first frame to near the last keeps both ends.
  func testRoomIsTrimmedWithPadsKept() {
    XCTAssertEqual(plan(frames(room, 40) + speech(100) + frames(room, 60))?.kept, [26..<154])
    let edges = recording(speech(50) + frames(room, 3))
    XCTAssertEqual(edges.parts().map(\.count), [53 * n], "speech from the first frame to near the end keeps both ends")
    let partial = recording(frames(room, 40) + speech(20) + Array(frames(-20, 1).prefix(300)))
    XCTAssertEqual(partial.parts().last?.count, 34 * n + 300, "the last part keeps the samples of an unfinished frame")
  }

  /// Catches talk taken for the room when it runs on: a room measured only
  /// within 5 s of each frame cut 1-3 s a minute of continuous real speech.
  /// 40 s of speech with room only at the taps is kept whole.
  func testSpeechFarFromAnyPauseIsKept() {
    XCTAssertEqual(plan(frames(room, 20) + speech(800) + frames(room, 20))?.kept, [6..<834])
  }

  /// Catches a long pause sent whole, billed by the second: two sentences
  /// 30 s apart came back as often with the pause cut (7 of 10 runs whole,
  /// 6 of 9 sent whole) for a quarter of the audio. 10 s of room between two
  /// sentences shrinks to 1.4 s; pauses under that stay as they are.
  func testLongPauseShrinksToItsPads() {
    let long = plan(speech(60) + frames(room, 200) + speech(60) + frames(room, 20))
    XCTAssertEqual(long?.kept, [0..<74, 246..<334])
    XCTAssertEqual(plan(speech(60) + frames(room, 28) + speech(60))?.kept, [0..<148], "a 1.4 s pause stays whole")
  }

  /// Catches quiet speech sent quiet (the transcriber drops it: measured,
  /// the second sentence said at -65 dBFS lost in both runs, kept once
  /// raised) or a knock clipped by the raise: the loudest speech frames
  /// reach -16 dBFS, a tap at -3 dBFS stays within full scale, and speech
  /// already loud is not turned down.
  func testSpeechIsSentAtTheTargetLevel() {
    let quiet = recording(frames(-80, 40) + (0..<100).flatMap { frames($0 % 3 == 0 ? -58 : -48, 1) } + frames(-3, 1) + frames(-80, 20))
    let sent = quiet.parts().flatMap { $0 }
    XCTAssertEqual(level(sent), Recording.target, accuracy: 1)
    XCTAssertLessThanOrEqual(sent.map(abs).max()!, 1, "within full scale")
    XCTAssertEqual(plan(frames(room, 20) + frames(-10, 100))?.gain, 0, "loud speech is not lowered")
  }

  /// Catches parts longer than a minute or a recording split needlessly:
  /// exactly 60 s of speech, tap to tap, goes as one part, a frame more as two.
  func testOneMinuteIsOnePart() {
    let minute = Recording.partFrames
    XCTAssertEqual(minute, 1_200, "a minute of 50 ms frames")
    XCTAssertEqual(plan(speech(minute))?.parts.count, 1)
    let over = plan(speech(minute + 1))?.parts ?? []
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
    let plan = plan(samples)!
    XCTAssertEqual(plan.kept, [6..<samples.count / n - 6])
    XCTAssertEqual(plan.parts.count, 3)
    XCTAssertEqual(plan.parts.first?.lowerBound, 0)
    XCTAssertEqual(plan.parts.last?.upperBound, plan.frameCount)
    for (a, b) in zip(plan.parts, plan.parts.dropFirst()) {
      XCTAssertEqual(a.upperBound, b.lowerBound, "contiguous")
      let cut = frame(b.lowerBound, in: plan)
      XCTAssertTrue(pauses.contains { $0.contains(cut) }, "cut at \(cut) is in a pause")
    }
    XCTAssertTrue(plan.parts.allSatisfy { $0.count <= Recording.partFrames })
    XCTAssertEqual(recording(samples).parts().map(\.count), plan.parts.map { $0.count * n })
  }

  /// Catches a cut in a short gap between words when a sentence's end is
  /// near: the longest pause near the even split wins.
  func testCutPrefersTheLongestPause() {
    // The even split falls on a 3-frame gap; a 16-frame pause sits 120 frames later.
    let samples = frames(room, 200) + speech(750) + frames(room, 3) + speech(117) + frames(room, 16) + speech(614)
    let plan = plan(samples)!
    XCTAssertEqual(plan.parts.count, 2)
    XCTAssertEqual(frame(plan.parts[1].lowerBound, in: plan), 200 + 750 + 3 + 117 + 8, "the middle of the long pause")
  }

  /// Catches a recording with no pause at all sent as one part over a
  /// minute: it is cut at its quietest frame near the even split.
  func testSpeechWithoutPausesIsStillCut() {
    let samples = frames(room, 200) + frames(-20, 700) + frames(-25, 1) + frames(-20, 700)
    let plan = plan(samples)!
    XCTAssertEqual(plan.parts.count, 2)
    XCTAssertEqual(frame(plan.parts[1].lowerBound, in: plan), 900, "the quietest frame")
    XCTAssertTrue(plan.parts.allSatisfy { $0.count <= Recording.partFrames })
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

  /// Catches the words to get right missing, cut, or pushed out by the
  /// screen: they go last on their own line, whole, and the screen's
  /// earliest lines give way so the prompt stays within 8,201 characters.
  func testWordsGoLastAndTheScreenGivesWay() {
    XCTAssertEqual(DictationPrompt.adding(["nstack", "Term"], to: "$ ls\ngit status"), "$ ls\ngit status\nnstack, Term")
    XCTAssertEqual(DictationPrompt.adding(["nstack"], to: ""), "nstack")
    XCTAssertEqual(DictationPrompt.adding([], to: "$ ls"), "$ ls")
    let rest = Array(repeating: String(repeating: "b", count: 199), count: 40)
    let full = ([String(repeating: "a", count: 200)] + rest).joined(separator: "\n")
    XCTAssertEqual(full.count, 8_200)
    let prompt = DictationPrompt.adding(["nstack", "omp", "tmux", "Term"], to: full)
    XCTAssertEqual(prompt, (rest + ["nstack, omp, tmux, Term"]).joined(separator: "\n"), "the first line gave way, whole")
    XCTAssertLessThanOrEqual(prompt.count, 8_201)
    let line = String(repeating: "a", count: 8_300)
    XCTAssertEqual(DictationPrompt.adding(["nstack"], to: line), String(repeating: "a", count: 8_194) + "\nnstack",
                   "one long line keeps its end")
  }
}
