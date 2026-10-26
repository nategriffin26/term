import AVFoundation
import SoundAnalysis

/// Whether a segment the loudness detector cut is someone speaking, as
/// Apple's on-device sound classifier hears it. Room noise, typing, knocks
/// and music are loud enough to make segments, and the transcriber answers
/// those with invented text ("Zdravo, kako si?"), so a segment is sent only
/// when the classifier hears speech or whispering in it.
///
/// Segments are judged in order on the gate's own queue. The classifier is
/// loaded when listening starts and let go when it stops; each segment's
/// analyzer is made while the one before it is being transcribed, so
/// judging speech adds a few milliseconds to it.
final class SpeechGate: @unchecked Sendable {
  /// The classifier scores 1 s windows every 0.5 s.
  static let window = SpeechSegmenter.sampleRate
  static let hop = window / 2
  /// A window this sure of speech or whispering is speech. Room noise,
  /// typing and music score under 0.1; soft, noisy and whispered speech over 0.7.
  static let threshold = 0.5
  private static let labels = ["speech", "whispering"]
  private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechSegmenter.sampleRate),
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

  /// Lets the classifier go once every segment already handed in is judged.
  func release() {
    queue.async {
      self.next = nil
      self.request = nil
    }
  }

  /// Judges a segment of 16 kHz mono samples; `heard` runs on the main
  /// queue with the verdict, in the order segments were handed in.
  func judge(_ samples: [Float], then heard: @escaping @MainActor @Sendable (Bool) -> Void) {
    queue.async {
      let speech = self.hearsSpeech(samples)
      DispatchQueue.main.async { MainActor.assumeIsolated { heard(speech) } }
      if self.request != nil { self.next = self.makeAnalysis() }
    }
  }

  /// The verdict, worked out on the calling thread: window by window, stopping
  /// at the first that holds speech. The analyzer reports each window before
  /// `analyze` returns. Runs on the gate's queue (and in tests).
  func hearsSpeech(_ samples: [Float]) -> Bool {
    guard let analysis = next ?? makeAnalysis() else { return false }
    next = nil
    let padded = Self.padded(samples)
    var at = 0
    while at < padded.count, !analysis.listener.heardSpeech {
      let end = min(at + Self.hop, padded.count)
      analysis.analyzer.analyze(Self.buffer(padded[at..<end]), atAudioFramePosition: AVAudioFramePosition(at))
      at = end
    }
    analysis.analyzer.completeAnalysis()
    return analysis.listener.heardSpeech
  }

  /// The rule for one window, given the classifier's confidence in a label.
  static func isSpeech(_ confidence: (String) -> Double?) -> Bool {
    labels.contains { (confidence($0) ?? 0) >= threshold }
  }

  /// The segment with silence after it up to whole hops and at least one
  /// window: the classifier only scores full windows, so without it the end
  /// of a segment, or all of a word shorter than a window, goes unheard.
  static func padded(_ samples: [Float]) -> [Float] {
    let length = max(window, (samples.count + hop - 1) / hop * hop)
    return samples + [Float](repeating: 0, count: length - samples.count)
  }

  private struct Analysis {
    let analyzer: SNAudioStreamAnalyzer
    let listener: Listener
  }

  private func makeAnalysis() -> Analysis? {
    do {
      let request = try request ?? SNClassifySoundRequest(classifierIdentifier: .version1)
      request.windowDuration = CMTime(value: CMTimeValue(Self.window), timescale: CMTimeScale(SpeechSegmenter.sampleRate))
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

  /// Collects the classifier's windows for one segment.
  private final class Listener: NSObject, SNResultsObserving {
    private(set) var heardSpeech = false

    func request(_ request: SNRequest, didProduce result: SNResult) {
      guard let result = result as? SNClassificationResult else { return }
      if SpeechGate.isSpeech({ result.classification(forIdentifier: $0)?.confidence }) { heardSpeech = true }
    }
  }
}
