import AVFoundation
import SoundAnalysis

/// Whether a recording holds someone speaking, as Apple's on-device sound
/// classifier hears it. Room noise, typing, knocks and music rise over the
/// room as speech does, and the transcriber answers them with invented text
/// ("Zdravo, kako si?"), so a recording is sent only when the classifier
/// hears speech or whispering somewhere in it. Then a part it is unsure of
/// on its own (soft speech, a mumble) still goes with the rest, so no speech
/// is dropped for it; only a part it is sure holds no speech (`floor`) stays.
///
/// Recordings are judged in the order they stopped, on the gate's own queue,
/// leveled first (`Recording.parts`), so the classifier hears quiet speech at
/// a normal level. The classifier is loaded when listening starts and let go
/// once the recording is judged; judging a part stops at its first window of
/// speech, so a spoken recording takes a few milliseconds.
final class SpeechGate: @unchecked Sendable {
  /// The classifier scores 1 s windows every 0.5 s.
  static let window = Recording.sampleRate
  static let hop = window / 2
  /// A window this sure of speech or whispering is speech.
  static let threshold = 0.5
  /// Once a recording holds speech, each part of it goes unless none of its
  /// windows reaches this. Measured on the leveled audio the app sends: the
  /// best window of every sentence in 39 recordings (quiet, distant,
  /// whispered, under a fan, speech from tap to tap) scored 0.59 or more;
  /// room, fan, knocks, music and typing 0.15 or less.
  static let floor = 0.3
  private static let labels = ["speech", "whispering"]
  private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Recording.sampleRate),
                                            channels: 1, interleaved: false)!

  private let queue = DispatchQueue(label: "SpeechGate", qos: .userInitiated)
  // Touched only on `queue`.
  private var request: SNClassifySoundRequest?
  private var next: Analysis?

  /// Loads the classifier; `loaded` runs on the main queue with whether it could.
  func prepare(then loaded: @escaping @MainActor @Sendable (Bool) -> Void) {
    queue.async {
      if self.next == nil { self.next = self.makeAnalysis() }
      let ready = self.next != nil
      DispatchQueue.main.async { MainActor.assumeIsolated { loaded(ready) } }
    }
  }

  /// Lets the classifier go once every recording already handed in is judged.
  func release() {
    queue.async {
      self.next = nil
      self.request = nil
    }
  }

  /// Works out what `recording` sends and judges it; `heard` runs on the
  /// main queue with the parts to send, none when no speech was heard, in
  /// the order recordings were handed in.
  func judge(_ recording: Recording, then heard: @escaping @MainActor @Sendable ([[Float]]) -> Void) {
    queue.async {
      let parts = recording.parts()
      let sent = zip(parts, Self.sends(parts.map { self.confidence(in: $0) })).filter(\.1).map(\.0)
      DispatchQueue.main.async { MainActor.assumeIsolated { heard(sent) } }
      if self.request != nil { self.next = self.makeAnalysis() }
    }
  }

  /// Which parts of a recording go, given each part's confidence in speech:
  /// none unless one is sure of it (`threshold`), then each over `floor`.
  static func sends(_ confidences: [Double]) -> [Bool] {
    let speech = confidences.contains { $0 >= threshold }
    return confidences.map { speech && $0 >= floor }
  }

  /// The highest confidence in speech of any window of `samples`, worked
  /// out on the calling thread window by window, stopping at the first
  /// sure of speech. The analyzer reports each window before `analyze`
  /// returns. Runs on the gate's queue (and in tests).
  func confidence(in samples: some Collection<Float>) -> Double {
    guard let analysis = next ?? makeAnalysis() else { return 0 }
    next = nil
    let padded = Self.padded(samples)
    var at = 0
    while at < padded.count, analysis.listener.highest < Self.threshold {
      let end = min(at + Self.hop, padded.count)
      analysis.analyzer.analyze(Self.buffer(padded[at..<end]), atAudioFramePosition: AVAudioFramePosition(at))
      at = end
    }
    analysis.analyzer.completeAnalysis()
    return analysis.listener.highest
  }

  /// One window's confidence in speech: the higher of speech and whispering.
  static func confidence(_ label: (String) -> Double?) -> Double {
    labels.map { label($0) ?? 0 }.max() ?? 0
  }

  /// The part with silence after it up to whole hops and at least one
  /// window: the classifier only scores full windows, so without it the end
  /// of a part, or all of a word shorter than a window, goes unheard.
  static func padded(_ samples: some Collection<Float>) -> [Float] {
    let length = max(window, (samples.count + hop - 1) / hop * hop)
    var padded = Array(samples)
    padded.append(contentsOf: repeatElement(0, count: length - samples.count))
    return padded
  }

  private struct Analysis {
    let analyzer: SNAudioStreamAnalyzer
    let listener: Listener
  }

  private func makeAnalysis() -> Analysis? {
    do {
      let request = try request ?? SNClassifySoundRequest(classifierIdentifier: .version1)
      request.windowDuration = CMTime(value: CMTimeValue(Self.window), timescale: CMTimeScale(Recording.sampleRate))
      request.overlapFactor = 0.5
      self.request = request
      let analyzer = SNAudioStreamAnalyzer(format: Self.format)
      let listener = Listener()
      try analyzer.add(request, withObserver: listener)
      return Analysis(analyzer: analyzer, listener: listener)
    } catch {
      return nil
    }
  }

  private static func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
  }

  /// Collects the classifier's windows for one part.
  private final class Listener: NSObject, SNResultsObserving {
    private(set) var highest = 0.0

    func request(_ request: SNRequest, didProduce result: SNResult) {
      guard let result = result as? SNClassificationResult else { return }
      highest = max(highest, SpeechGate.confidence { result.classification(forIdentifier: $0)?.confidence })
    }
  }
}
