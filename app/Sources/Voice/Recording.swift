import Foundation

/// The microphone's audio from the tap that starts listening to the tap
/// that stops it (16 kHz mono), with each 50 ms frame's loudness.
///
/// What is sent is everything but the clearly silent, at one level. Room
/// more than half a second from any sound is cut, so a long pause shrinks
/// to about a second (a 30 s pause sent whole cost four times the audio for
/// the same text) and the room before and after the speech goes. OpenAI's
/// transcriber drops quiet speech and keeps it once it is raised (measured:
/// a sentence said at -65 dBFS lost in every run, kept in every run raised;
/// the last sentence under a fan lost in 8 of 8, kept in 6 of 10 raised),
/// the treatment OpenAI's own chunking gives (loudness normalized, silence
/// found by voice activity).
struct Recording {
  static let sampleRate = 16_000
  /// 50 ms.
  static let frameLength = 800
  /// The longest part sent as one request. OpenAI's transcriber spells
  /// fewer paths and flags right past a minute (measured: 13-16 of 16 in a
  /// 60 s clip, 22-24 of 31 in a 2 min one, 25-26 of 31 as two 1 min parts).
  static let partFrames = 1_200

  /// Kept on each side of every sound, so soft first and last sounds and
  /// the pauses between sentences survive.
  static let padFrames = 10
  /// A frame is sound when its loudness, averaged over the 0.45 s around
  /// it (a room's noise wavers less over that than frame to frame), is this
  /// far over the room: the recording's quietest averaged frame, the room
  /// before the first word or in any breath. A room measured only within
  /// 5 s of each frame took a minute of continuous speech for room and cut
  /// 1-3 s of it. No level is too quiet to be sound: speech the microphone
  /// hears at -65 dBFS is still transcribed once leveled.
  private static let smoothFrames = 4
  private static let margin: Float = 6
  /// The level speech is sent at: its loudest frames (the 90th percentile
  /// of the sound) at -16 dBFS, where loudness normalization puts spoken
  /// word (-16 LUFS). Quieter recordings are raised by up to 40 dB, never lowered.
  static let target: Float = -16
  static let maxGain: Float = 40
  /// How far a cut may move from an even split to land in a pause.
  private static let cutSearchFrames = 200

  private(set) var samples: [Float] = []
  /// dBFS of each whole frame so far.
  private(set) var loudness: [Float] = []

  /// Adds what the microphone delivered; returns the strip's level (0 to 1)
  /// of each frame it completed.
  mutating func append(_ more: some Collection<Float>) -> [Float] {
    samples.append(contentsOf: more)
    var levels: [Float] = []
    while (loudness.count + 1) * Self.frameLength <= samples.count {
      let start = loudness.count * Self.frameLength
      let dB = Self.loudness(samples[start..<start + Self.frameLength])
      loudness.append(dB)
      levels.append(Self.displayLevel(dB: dB))
    }
    return levels
  }

  /// What is sent: the recording without its clearly silent stretches, set
  /// to the target level, cut at pauses into parts of at most `partFrames`,
  /// in order. Empty for an empty recording.
  func parts() -> [[Float]] {
    guard let plan = Self.plan(loudness: loudness) else { return [] }
    let gain = powf(10, plan.gain / 20)
    var sent: [Float] = []
    sent.reserveCapacity(plan.kept.reduce(0) { $0 + $1.count } * Self.frameLength)
    for run in plan.kept {
      // The unfinished frame at the end goes with the last frame.
      let end = run.upperBound == loudness.count ? samples.count : run.upperBound * Self.frameLength
      sent.append(contentsOf: samples[run.lowerBound * Self.frameLength..<end].lazy.map { Self.limited($0 * gain) })
    }
    return plan.parts.map { frames in
      let end = frames.upperBound == plan.frameCount ? sent.count : frames.upperBound * Self.frameLength
      return Array(sent[frames.lowerBound * Self.frameLength..<end])
    }
  }

  /// What a recording of `loudness` sends.
  struct Plan: Equatable {
    /// The recording's frames that are sent, as runs in order.
    let kept: [Range<Int>]
    /// The parts, as ranges of the kept frames laid end to end.
    let parts: [Range<Int>]
    /// dB added to every sample.
    let gain: Float

    var frameCount: Int { kept.reduce(0) { $0 + $1.count } }
  }

  /// The plan for a whole recording's `loudness`; nil for an empty recording.
  static func plan(loudness: [Float]) -> Plan? {
    let sound = sound(loudness)
    var kept: [Range<Int>] = []
    for i in sound.indices where sound[i] {
      let run = max(0, i - padFrames)..<min(loudness.count, i + padFrames + 1)
      if let last = kept.last, last.upperBound >= run.lowerBound {
        kept[kept.count - 1] = last.lowerBound..<run.upperBound
      } else {
        kept.append(run)
      }
    }
    guard !kept.isEmpty else { return nil }
    let frames = kept.flatMap { $0 }
    let level = percentile90(sound.indices.filter { sound[$0] }.map { loudness[$0] })
    let gain = min(max(target - level, 0), maxGain)
    let parts = cuts(loudness: frames.map { loudness[$0] }, quiet: frames.map { !sound[$0] })
    return Plan(kept: kept, parts: parts, gain: gain)
  }

  /// Whether each frame is sound rather than room (see `margin`). With no
  /// frame over the room there is nothing to tell them apart (a word from
  /// tap to tap, speech throughout, the room alone): every frame counts,
  /// and the speech classifier judges the whole recording.
  static func sound(_ loudness: [Float]) -> [Bool] {
    let power = loudness.map { powf(10, $0 / 10) }
    let averaged = power.indices.map { i in
      let window = power[max(0, i - smoothFrames)...min(power.count - 1, i + smoothFrames)]
      return 10 * log10f(max(window.reduce(0, +) / Float(window.count), 1e-12))
    }
    guard let room = averaged.min() else { return [] }
    let sound = averaged.map { $0 >= room + margin }
    return sound.contains(true) ? sound : [Bool](repeating: true, count: sound.count)
  }

  /// `count` frames cut into parts of at most `partFrames`, as few as fit,
  /// each cut in the longest pause near an even split.
  private static func cuts(loudness: [Float], quiet: [Bool]) -> [Range<Int>] {
    let count = (loudness.count + partFrames - 1) / partFrames
    var cuts = [0]
    for k in 1..<max(count, 1) {
      // Between an even split's neighbourhood and what keeps every part short enough.
      let even = loudness.count * k / count
      let lo = max(even - cutSearchFrames, loudness.count - (count - k) * partFrames)
      let hi = min(even + cutSearchFrames, cuts[k - 1] + partFrames)
      cuts.append(cut(loudness, quiet: quiet, in: lo...hi, near: even))
    }
    cuts.append(loudness.count)
    return (0..<cuts.count - 1).map { cuts[$0]..<cuts[$0 + 1] }
  }

  /// The middle of the longest pause in `range` (the one nearest `near` of
  /// equals); with no quiet frame, the quietest frame nearest `near`.
  private static func cut(_ loudness: [Float], quiet: [Bool], in range: ClosedRange<Int>, near: Int) -> Int {
    var best: (length: Int, distance: Int, at: Int)?
    var i = range.lowerBound
    while i <= range.upperBound {
      guard quiet[i] else {
        i += 1
        continue
      }
      var j = i
      while j + 1 <= range.upperBound, quiet[j + 1] { j += 1 }
      let at = (i + j + 1) / 2
      let candidate = (length: j - i + 1, distance: abs(at - near), at: at)
      if best.map({ candidate.length > $0.length || candidate.length == $0.length && candidate.distance < $0.distance }) ?? true {
        best = candidate
      }
      i = j + 1
    }
    if let best { return best.at }
    return range.min { (loudness[$0], abs($0 - near)) < (loudness[$1], abs($1 - near)) }!
  }

  private static func percentile90(_ values: [Float]) -> Float {
    values.sorted()[values.count * 9 / 10]
  }

  /// A sample past ±0.5 bends toward ±1, never past it: a knock or the stop
  /// tap raised with quiet speech is squashed, never clipped.
  static func limited(_ x: Float) -> Float {
    let knee: Float = 0.5
    let size = abs(x)
    guard size > knee else { return x }
    return (knee + (1 - knee) * tanhf((size - knee) / (1 - knee))) * (x < 0 ? -1 : 1)
  }

  /// A frame's loudness for the strip: 0 at -60 dBFS or less, 1 at -10 dBFS.
  static func displayLevel(dB: Float) -> Float { min(max((dB + 60) / 50, 0), 1) }

  /// RMS in dBFS.
  static func loudness(_ frame: ArraySlice<Float>) -> Float {
    guard !frame.isEmpty else { return -120 }
    var sum: Float = 0
    for s in frame { sum += s * s }
    return 10 * log10(max(sum / Float(frame.count), 1e-12))
  }
}
