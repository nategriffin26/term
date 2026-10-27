import AVFoundation
import XCTest
@testable import Term

/// Audio as the microphone delivers it (16 kHz mono): spoken English from
/// the system voice, and sounds that rise over the room without speech.
enum TestAudio {
  static let rate = Recording.sampleRate

  /// `text` spoken by the system's English voice at `dB` RMS, over a quiet
  /// room at `roomDB`, with 0.3 s of room before and 0.2 s after.
  static func speech(_ text: String, dB: Float = -24, roomDB: Float = -55) async throws -> [Float] {
    let spoken = try await voice(text, dB: dB)
    var rng = Seeded(1)
    let before = room(0.3, &rng, dB: roomDB), after = room(0.2, &rng, dB: roomDB)
    let floor = room(Double(spoken.count) / Double(rate), &rng, dB: roomDB)
    return before + zip(spoken, floor).map(+) + after
  }

  /// The voice alone at `dB` RMS, from its first sound to its last;
  /// `voicedFrames` cuts it to its first frames (50 ms each), a word said short.
  static func voice(_ text: String, dB: Float = -24, voicedFrames: Int? = nil) async throws -> [Float] {
    let voice = try await say(text)
    let first = voice.firstIndex { abs($0) > 1e-3 } ?? 0, last = voice.lastIndex { abs($0) > 1e-3 } ?? 0
    let end = voicedFrames.map { min(last, first + $0 * Recording.frameLength - 1) } ?? last
    return scaled(Array(voice[first...end]), to: dB)
  }

  /// A room's steady hiss at `dB`: no stretch of it is louder than the rest.
  static func room(seconds: Double, dB: Float = -55) -> [Float] {
    var rng = Seeded(4)
    return scaled((0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -1...1, using: &rng) }, to: dB)
  }

  /// A quiet room whose noise swells and falls, with knocks on the desk.
  static func roomWithKnocks(seconds: Double) -> [Float] {
    var rng = Seeded(2)
    var x = room(seconds, &rng)
    var swell: Float = 1, target: Float = 1
    for i in x.indices {
      if i % (rate / 2) == 0 { target = Float.random(in: 0.3...4, using: &rng) }
      swell += (target - swell) * 0.0005
      x[i] *= swell
    }
    var at = rate / 2
    while at < x.count {
      let length = Int.random(in: rate / 30...rate / 6, using: &rng)
      for j in 0..<min(length, x.count - at) {
        x[at + j] += Float.random(in: -0.2...0.2, using: &rng) * expf(-6 * Float(j) / Float(length))
      }
      at += Int.random(in: rate...3 * rate, using: &rng)
    }
    return x
  }

  /// Typing: key clicks at 6 to 12 a second over a quiet room.
  static func typing(seconds: Double) -> [Float] {
    var rng = Seeded(3)
    var x = room(seconds, &rng)
    var at = rate / 4
    while at < x.count {
      let gain = Float.random(in: 0.05...0.3, using: &rng)
      for j in 0..<min(rate / 200, x.count - at) {
        x[at + j] += Float.random(in: -1...1, using: &rng) * gain * expf(-Float(j) / 12)
      }
      at += rate / Int.random(in: 6...12, using: &rng)
    }
    return x
  }

  /// Music without voice: chords on every half second over a bass drum.
  static func music(seconds: Double) -> [Float] {
    let chords: [[Float]] = [[261.6, 329.6, 392.0], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6], [196.0, 246.9, 293.7]]
    let count = Int(seconds * Double(rate))
    return (0..<count).map { i in
      let t = Float(i) / Float(rate)
      let beat = i % (rate / 2)
      let chord = chords[(i / (rate / 2)) % chords.count]
      var s: Float = 0
      for f in chord {
        for n in 1...4 { s += sinf(2 * .pi * f * Float(n) * t) / Float(n) }
      }
      let decay = expf(-3 * Float(beat) / Float(rate))
      let kick = sinf(2 * .pi * 55 * Float(beat) / Float(rate)) * expf(-20 * Float(beat) / Float(rate))
      return 0.02 * s * (0.4 + decay) + 0.15 * kick
    }
  }

  /// Brown noise around `dB`.
  private static func room(_ seconds: Double, _ rng: inout Seeded, dB: Float = -55) -> [Float] {
    var level: Float = 0
    let x = (0..<Int(seconds * Double(rate))).map { _ in
      level = level * 0.995 + Float.random(in: -1...1, using: &rng)
      return level
    }
    return scaled(x, to: dB)
  }

  private static func scaled(_ x: [Float], to dB: Float) -> [Float] {
    let rms = sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1)))
    let gain = powf(10, dB / 20) / max(rms, 1e-9)
    return x.map { $0 * gain }
  }

  /// The system voice's rendering of `text`, at 16 kHz mono.
  private static func say(_ text: String) async throws -> [Float] {
    final class Rendered: @unchecked Sendable {
      var buffers: [AVAudioPCMBuffer] = []
      var done = false
    }
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    let rendered = Rendered()
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
      synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, !rendered.done else { return }
        if pcm.frameLength == 0 {
          rendered.done = true
          finished.resume()
        } else {
          rendered.buffers.append(pcm)
        }
      }
    }
    guard let format = rendered.buffers.first?.format else { throw CocoaError(.featureUnsupported) }
    let frames = rendered.buffers.reduce(0) { $0 + Int($1.frameLength) }
    let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    for b in rendered.buffers {
      let bytes = Int(b.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame)
      let to = whole.audioBufferList.pointee.mBuffers.mData!.advanced(by: Int(whole.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame))
      to.copyMemory(from: b.audioBufferList.pointee.mBuffers.mData!, byteCount: bytes)
      whole.frameLength += b.frameLength
    }
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: format, to: target)!
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(frames) * target.sampleRate / format.sampleRate) + 1024)!
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed {
        status.pointee = .endOfStream
        return nil
      }
      fed = true
      status.pointee = .haveData
      return whole
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
  }
}

/// SplitMix64, so generated noise is the same on every run.
struct Seeded: RandomNumberGenerator {
  private var state: UInt64
  init(_ seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

final class SpeechGateTests: XCTestCase {
  /// Catches whispered speech scored as nothing, or another label taken for
  /// speech: a window's confidence is the higher of speech and whispering.
  func testWindowConfidenceIsSpeechOrWhispering() {
    XCTAssertEqual(SpeechGate.confidence { ["speech": 0.49, "whispering": 0.3][$0] }, 0.49)
    XCTAssertEqual(SpeechGate.confidence { ["speech": 0.2, "whispering": 0.8][$0] }, 0.8)
    XCTAssertEqual(SpeechGate.confidence { ["music": 0.99, "singing": 0.9, "typing": 0.9][$0] }, 0)
    XCTAssertEqual(SpeechGate.confidence { _ in nil }, 0)
  }

  /// Catches noise sent when the classifier was unsure of it, quiet speech
  /// dropped from a recording that holds speech, or a part sure to hold no
  /// speech sent with one that does: a recording goes once one of its parts
  /// reaches 0.5, and then each part at or over the floor.
  func testPartsGoWithSpeechAndOverTheFloor() {
    let floor = SpeechGate.floor
    XCTAssertEqual(SpeechGate.sends([0.49]), [false])
    XCTAssertEqual(SpeechGate.sends([0.5]), [true])
    XCTAssertEqual(SpeechGate.sends([0.49, 0.49]), [false, false], "no part sure of speech")
    XCTAssertEqual(SpeechGate.sends([0.9, floor]), [true, true])
    XCTAssertEqual(SpeechGate.sends([floor.nextDown, 0.5]), [false, true])
    XCTAssertEqual(SpeechGate.sends([]), [])
  }

  /// Catches a short word or a segment's end going unheard: the classifier
  /// scores only whole 1 s windows every 0.5 s.
  func testPaddingCoversShortSegmentsAndTheEnd() {
    let second = SpeechGate.window
    XCTAssertEqual(SpeechGate.padded([Float](repeating: 1, count: second * 3 / 4)).count, second)
    XCTAssertEqual(SpeechGate.padded([Float](repeating: 1, count: second)).count, second)
    XCTAssertEqual(SpeechGate.padded([Float](repeating: 1, count: second + 1)).count, second * 3 / 2)
    XCTAssertEqual(SpeechGate.padded([Float](repeating: 1, count: second * 2)).count, second * 2)
    let padded = SpeechGate.padded([Float](repeating: 1, count: 100))
    XCTAssertEqual(padded.prefix(100), [Float](repeating: 1, count: 100)[...])
    XCTAssertEqual(Set(padded.dropFirst(100)), [0])
  }

  /// Catches the transcriber being sent room noise, knocks, typing or music
  /// (it makes up text for them: "Zdravo, kako si?"), alone or as a part of
  /// a recording with speech: each scores under the floor.
  func testNoiseIsNotSpeech() {
    let gate = SpeechGate()
    XCTAssertLessThan(gate.confidence(in: TestAudio.roomWithKnocks(seconds: 8)), SpeechGate.floor, "room and knocks")
    XCTAssertLessThan(gate.confidence(in: TestAudio.typing(seconds: 6)), SpeechGate.floor, "typing")
    XCTAssertLessThan(gate.confidence(in: TestAudio.music(seconds: 6)), SpeechGate.floor, "music")
    XCTAssertLessThan(gate.confidence(in: TestAudio.typing(seconds: 0.5)), SpeechGate.floor, "a short burst")
  }

  /// Catches a part scored by its last window rather than its best (an
  /// unsure stretch of speech followed by room would be dropped): typing
  /// then 3 s of silence scores at least what the typing alone does.
  func testPartScoresItsBestWindow() {
    let gate = SpeechGate()
    let typing = TestAudio.typing(seconds: 6)
    let alone = gate.confidence(in: typing)
    XCTAssertGreaterThan(alone, 0.01, "typing scores over silence")
    XCTAssertGreaterThanOrEqual(gate.confidence(in: typing + [Float](repeating: 0, count: 3 * TestAudio.rate)), alone)
  }

  /// Catches real speech dropped: a sentence, the same said softly, and a
  /// one-word answer shorter than the classifier's window.
  func testSpeechIsSpeech() async throws {
    let gate = SpeechGate()
    let sentence = try await TestAudio.speech("Run git status, then list the files in the sources folder.")
    XCTAssertGreaterThanOrEqual(gate.confidence(in: sentence), SpeechGate.threshold, "a sentence")
    let soft = try await TestAudio.speech("Please check the config before deploying.", dB: -42)
    XCTAssertGreaterThanOrEqual(gate.confidence(in: soft), SpeechGate.threshold, "soft speech")
    let yes = try await TestAudio.speech("Yes.")
    XCTAssertLessThan(yes.count, SpeechGate.window, "the word is shorter than a window")
    XCTAssertGreaterThanOrEqual(gate.confidence(in: yes), SpeechGate.threshold, "a one-word answer")
  }

  /// What a speech gate sends of `recording`.
  private func judged(_ recording: Recording) async -> [[Float]] {
    let judged = expectation(description: "judged")
    nonisolated(unsafe) var sent: [[Float]] = []
    SpeechGate().judge(recording) { parts in
      sent = parts
      judged.fulfill()
    }
    await fulfillment(of: [judged], timeout: 10)
    return sent
  }

  /// Catches typing sent as text when it fills a part of its own (the
  /// transcriber makes up words for it): a sentence then 65 s of typing
  /// makes two parts, and only the sentence's part is sent.
  func testPartWithoutSpeechIsNotSent() async throws {
    var recording = Recording()
    _ = recording.append(try await TestAudio.speech("Run git status, then list the files in the sources folder."))
    _ = recording.append(TestAudio.typing(seconds: 65))
    let parts = recording.parts()
    XCTAssertEqual(parts.count, 2)
    let sent = await judged(recording)
    XCTAssertEqual(sent.map(\.count), parts.prefix(1).map(\.count))
    XCTAssertTrue(sent == Array(parts.prefix(1)), "the same audio")
  }

  /// Catches a room or digital silence sent once it is leveled: with no
  /// contrast in it the whole recording, raised up to 40 dB, reaches the
  /// classifier, which must still hear no speech.
  func testQuietRoomIsNotSent() async {
    for (name, samples) in [("room", TestAudio.room(seconds: 5)), ("digital silence", [Float](repeating: 0, count: 5 * TestAudio.rate))] {
      var recording = Recording()
      _ = recording.append(samples)
      XCTAssertEqual(recording.parts().count, 1, name)
      let sent = await judged(recording)
      XCTAssertEqual(sent.count, 0, name)
    }
  }
}
