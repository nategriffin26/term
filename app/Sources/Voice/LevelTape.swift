import Foundation

/// The listening trace's timeline. Levels arrive a few at a time (two every
/// 100 ms from the microphone, now and then late); the trace scrolls at a
/// constant 40 pt/s on the display's clock all the same, 0.2 s of audio
/// behind the newest level, so a late delivery is in hand before its bar
/// reaches the edge. Each level passes once through an envelope (quick to
/// rise, slow to fall) as it arrives, and a bar shows the envelope at its own
/// point in the audio, so it keeps its height all the way across.
struct LevelTape {
  /// Audio per level.
  static let frameSeconds = 0.05
  /// Audio per bar.
  static let barSeconds = 0.1
  /// Points per second the trace scrolls: a bar every 4 pt.
  static let speed = 40.0
  /// Audio kept in hand behind the newest level.
  static let delay = 0.2
  /// How far the envelope moves toward a louder level, and toward a quieter one, per level.
  static let attack: Float = 0.6
  static let release: Float = 0.25
  /// Envelope values kept: 4 s, more than the widest trace shows.
  private static let kept = 80
  private static let framesPerBar = Int((barSeconds / frameSeconds).rounded())

  /// The envelope of the last `kept` levels, oldest first.
  private var envelope: [Float] = []
  /// Levels received in all.
  private var frames = 0
  /// The display time at which audio time 0 is at the right edge, set by the first level.
  private var start: Double?

  /// Takes the levels in `heard` not taken yet, received at display time `now`.
  mutating func receive(_ heard: HeardLevels, at now: Double) {
    let new = heard.total - frames
    guard new > 0 else { return }
    // Levels that slid out of `recent` before they were taken hold the envelope.
    for _ in 0..<max(new - heard.recent.count, 0) { keep(envelope.last ?? 0) }
    for level in heard.recent.suffix(new) {
      let last = envelope.last ?? 0
      keep(last + (level - last) * (level > last ? Self.attack : Self.release))
    }
    frames = heard.total
    if start == nil { start = now + Self.delay - Double(frames) * Self.frameSeconds }
  }

  /// Bar `index` (0 nearest the right edge) at display time `now`: how far
  /// left of the edge it is, in points, and its level, nil for audio before
  /// listening began. Past the newest level, the last envelope holds.
  func bar(_ index: Int, at now: Double) -> (offset: Double, level: Float?) {
    guard let start, !envelope.isEmpty else { return (Double(index) * Self.barSeconds * Self.speed, nil) }
    let edge = now - start
    let k = Int((edge / Self.barSeconds).rounded(.down)) - index
    let offset = (edge - Double(k) * Self.barSeconds) * Self.speed
    // The level whose 50 ms ends at the bar's point in the audio.
    let frame = k * Self.framesPerBar - 1
    guard frame >= 0 else { return (offset, nil) }
    let i = frame - (frames - envelope.count)
    return (offset, envelope[min(max(i, 0), envelope.count - 1)])
  }

  private mutating func keep(_ value: Float) {
    envelope.append(value)
    if envelope.count > Self.kept { envelope.removeFirst(envelope.count - Self.kept) }
  }
}
