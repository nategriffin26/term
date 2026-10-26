import Foundation

/// Cuts microphone audio (16 kHz mono) into spoken segments, judged by
/// loudness in 50 ms frames against the room's noise floor. A segment starts
/// with 100 ms of speech (with the 300 ms before it, so first syllables
/// survive) and ends after 0.7 s of silence, or 0.3 s once it is 15 s
/// long, or at 30 s outright. Pure silence and a click under 100 ms never
/// make one. Length alone never discards a segment: the speech classifier
/// hears a word in 100 to 150 ms of it, so a one-word answer reaches it.
struct SpeechSegmenter {
  static let sampleRate = 16_000
  /// 50 ms.
  static let frameLength = 800

  /// A frame's loudness for the strip: 0 at -60 dBFS or less, 1 at -10 dBFS.
  static func displayLevel(dB: Float) -> Float { min(max((dB + 60) / 50, 0), 1) }

  // Frame counts for the times above.
  private static let onsetFrames = 2
  private static let preRollFrames = 6
  private static let endSilenceFrames = 14
  private static let longSegmentFrames = 300
  private static let longSilenceFrames = 6
  private static let maxFrames = 600
  /// Silence kept after the last speech in a segment.
  private static let tailFrames = 4
  /// The noise floor is the quietest frame of the last 3 s: speech always
  /// has gaps between words, so it follows the room, not the voice.
  private static let floorFrames = 60
  /// Until the floor has 1 s behind it, every frame is kept for the first
  /// segment, in case speech began the moment listening did.
  private static let settleFrames = 20

  /// Speech is this far over the noise floor (less to stay in speech than
  /// to start it), and never quieter than -55 dBFS.
  private static let startMargin: Float = 10
  private static let stayMargin: Float = 6
  private static let quietest: Float = -55

  private var partial: [Float] = []
  private var floorWindow: [Float] = []
  private var recent: [[Float]] = []
  private var onset = 0
  private var segment: [[Float]]?
  private var silentRun = 0
  /// Frames in `segment` up to the end of its last speech.
  private var lastSpeech = 0

  struct Output: Equatable {
    /// One per frame completed, for the strip.
    var levels: [Float] = []
    /// Finished segments, in order.
    var segments: [[Float]] = []
  }

  mutating func append(_ samples: some Collection<Float>) -> Output {
    var out = Output()
    partial.append(contentsOf: samples)
    var start = 0
    while partial.count - start >= Self.frameLength {
      let frame = Array(partial[start..<start + Self.frameLength])
      start += Self.frameLength
      let dB = Self.loudness(frame)
      out.levels.append(Self.displayLevel(dB: dB))
      if let done = push(frame, dB: dB) { out.segments.append(done) }
    }
    partial.removeFirst(start)
    return out
  }

  /// The segment in progress when listening stops.
  mutating func finish() -> [Float]? {
    defer {
      endSegment()
      partial = []
      recent = []
    }
    guard segment != nil else { return nil }
    return trimmed()
  }

  private mutating func push(_ frame: [Float], dB: Float) -> [Float]? {
    floorWindow.append(dB)
    if floorWindow.count > Self.floorFrames { floorWindow.removeFirst() }
    let floor = floorWindow.min() ?? dB
    guard segment != nil else {
      recent.append(frame)
      if floorWindow.count >= Self.settleFrames, recent.count > Self.preRollFrames {
        recent.removeFirst(recent.count - Self.preRollFrames)
      }
      onset = dB >= max(floor + Self.startMargin, Self.quietest) ? onset + 1 : 0
      guard onset >= Self.onsetFrames else { return nil }
      segment = recent
      recent = []
      lastSpeech = segment!.count
      silentRun = 0
      onset = 0
      return nil
    }
    segment!.append(frame)
    if dB >= max(floor + Self.stayMargin, Self.quietest) {
      silentRun = 0
      lastSpeech = segment!.count
    } else {
      silentRun += 1
    }
    let length = segment!.count
    if length >= Self.maxFrames {
      // Cut mid-speech: all of it goes, and the next segment starts afresh.
      let all = segment!.flatMap { $0 }
      endSegment()
      return all
    }
    let pause = length >= Self.longSegmentFrames ? Self.longSilenceFrames : Self.endSilenceFrames
    guard silentRun >= pause else { return nil }
    let done = trimmed()
    endSegment()
    return done
  }

  /// The segment up to its last speech and a short tail of silence.
  private func trimmed() -> [Float] {
    guard let segment else { return [] }
    return segment.prefix(min(lastSpeech + Self.tailFrames, segment.count)).flatMap { $0 }
  }

  private mutating func endSegment() {
    segment = nil
    silentRun = 0
    lastSpeech = 0
    onset = 0
  }

  /// RMS in dBFS.
  static func loudness(_ frame: [Float]) -> Float {
    guard !frame.isEmpty else { return -120 }
    var sum: Float = 0
    for s in frame { sum += s * s }
    return 10 * log10(max(sum / Float(frame.count), 1e-12))
  }
}
