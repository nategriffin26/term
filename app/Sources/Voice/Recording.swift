import Foundation

/// The microphone's audio from the tap that starts listening to the tap
/// that stops it (16 kHz mono), with each 50 ms frame's loudness.
struct Recording {
  static let sampleRate = 16_000
  /// 50 ms.
  static let frameLength = 800
  /// The longest part sent as one request. OpenAI's transcriber spells
  /// fewer paths and flags right past a minute (measured: 13-16 of 16 in a
  /// 60 s clip, 22-24 of 31 in a 2 min one, 25-26 of 31 as two 1 min parts).
  static let partFrames = 1_200

  /// Kept before the first and after the last frame over the room, so soft
  /// first and last sounds survive the trim.
  private static let leadFrames = 6
  private static let tailFrames = 10
  /// A frame is over the room when it is this far above the noise floor
  /// (the recording's 10th-percentile frame: speech has gaps between words,
  /// so it follows the room, not the voice), and never quieter than -55 dBFS.
  private static let margin: Float = 6
  private static let quietest: Float = -55
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

  /// What is sent: the recording with the room before and after it trimmed
  /// off, cut at pauses into parts of at most `partFrames`, in order and
  /// with nothing between them dropped. Empty when nothing rose over the room.
  func parts() -> [ArraySlice<Float>] {
    Self.parts(loudness: loudness).map { frames in
      let end = frames.upperBound == loudness.count ? samples.count : frames.upperBound * Self.frameLength
      return samples[frames.lowerBound * Self.frameLength..<end]
    }
  }

  /// The parts as frame ranges, for `loudness` of a whole recording.
  static func parts(loudness: [Float]) -> [Range<Int>] {
    guard !loudness.isEmpty else { return [] }
    let line = max(floor(loudness) + margin, quietest)
    guard let first = loudness.firstIndex(where: { $0 >= line }),
          let last = loudness.lastIndex(where: { $0 >= line }) else { return [] }
    let start = max(0, first - leadFrames), end = min(loudness.count, last + 1 + tailFrames)
    let count = (end - start + partFrames - 1) / partFrames
    var cuts = [start]
    for k in 1..<max(count, 1) {
      // Between an even split's neighbourhood and what keeps every part short enough.
      let even = start + (end - start) * k / count
      let lo = max(even - cutSearchFrames, end - (count - k) * partFrames)
      let hi = min(even + cutSearchFrames, cuts[k - 1] + partFrames)
      cuts.append(cut(loudness, in: lo...hi, near: even, line: line))
    }
    cuts.append(end)
    return (0..<cuts.count - 1).map { cuts[$0]..<cuts[$0 + 1] }
  }

  /// The middle of the longest pause in `range` (the one nearest `near` of
  /// equals); with no frame under `line`, the quietest frame nearest `near`.
  private static func cut(_ loudness: [Float], in range: ClosedRange<Int>, near: Int, line: Float) -> Int {
    var best: (length: Int, distance: Int, at: Int)?
    var i = range.lowerBound
    while i <= range.upperBound {
      guard loudness[i] < line else {
        i += 1
        continue
      }
      var j = i
      while j + 1 <= range.upperBound, loudness[j + 1] < line { j += 1 }
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

  /// The 10th-percentile frame.
  private static func floor(_ loudness: [Float]) -> Float {
    loudness.sorted()[loudness.count / 10]
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
