import AVFoundation

/// What `Dictation` listens with. Called on the main thread.
protocol Microphone: AnyObject {
  /// Turns the microphone on; `done` comes back on the main actor with nil
  /// once samples will flow, or the error. It may take long, or never come,
  /// while the audio server is slow to answer.
  func start(_ done: @escaping @MainActor @Sendable (Error?) -> Void)
  /// Turns it off, after any start still in progress.
  func stop()
}

/// The microphone as 16 kHz mono samples, delivered on the audio thread
/// about every 100 ms. Every audio session and engine call runs on one
/// serial queue, never the main thread: an audio server slow to answer
/// holds up that queue, not the app.
final class MicrophoneCapture: Microphone, @unchecked Sendable {
  private static let queue = DispatchQueue(label: "MicrophoneCapture", qos: .userInitiated)

  /// AudioToolbox aborts the app when the audio server takes longer than
  /// its `rpc_timeout` preference (9 s unless set) to answer starting the
  /// microphone, and returns no error to handle; a loaded simulator hit it
  /// in AURemoteIO::Initialize and ::Start. 0 waits for the answer instead,
  /// and `Dictation` gives up on a start that takes too long. AudioToolbox
  /// reads it once per process, so this runs at launch, before any audio.
  static func waitForSlowAudioServer() {
    UserDefaults(suiteName: "com.apple.coreaudio")?.set(0, forKey: "rpc_timeout")
  }

  // Touched only on `queue`.
  private let engine = AVAudioEngine()
  private var tapped = false
  private var routeObserver: NSObjectProtocol?

  private let onSamples: @Sendable ([Float]) -> Void
  private let onFailure: @MainActor @Sendable () -> Void

  /// `onFailure`: listening stopped by itself (the input could not restart after a route change).
  init(onSamples: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @MainActor @Sendable () -> Void) {
    self.onSamples = onSamples
    self.onFailure = onFailure
  }

  func start(_ done: @escaping @MainActor @Sendable (Error?) -> Void) {
    Self.queue.async { [self] in
      var failure: Error?
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        try tap()
        // A new route (headphones, AirPods) stops the engine: start again in its format.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: engine, queue: nil) { [weak self] _ in
          Self.queue.async { self?.restart() }
        }
      } catch {
        failure = error
        release()
      }
      DispatchQueue.main.async { [failure] in MainActor.assumeIsolated { done(failure) } }
    }
  }

  func stop() {
    Self.queue.async { [self] in release() }
  }

  /// On `queue`.
  private func restart() {
    guard tapped else { return }
    do {
      try tap()
    } catch {
      release()
      let onFailure = onFailure
      DispatchQueue.main.async { MainActor.assumeIsolated { onFailure() } }
    }
  }

  /// On `queue`: the tap in the input's current format, and the engine running.
  private func tap() throws {
    let input = engine.inputNode
    if tapped { input.removeTap(onBus: 0) }
    tapped = false
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
          let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechSegmenter.sampleRate),
                                     channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: format, to: target)
    else { throw CocoaError(.featureUnsupported) }
    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format,
                     block: Self.tap(converter: converter, target: target, deliver: onSamples))
    tapped = true
    engine.prepare()
    try engine.start()
  }

  /// On `queue`: everything `start` took, given back.
  private func release() {
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    routeObserver = nil
    if tapped { engine.inputNode.removeTap(onBus: 0) }
    tapped = false
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// Made outside any actor: the engine calls it on its own thread.
  private static func tap(converter: AVAudioConverter, target: AVAudioFormat,
                          deliver: @escaping @Sendable ([Float]) -> Void) -> AVAudioNodeTapBlock {
    { buffer, _ in
      let ratio = target.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
      var fed = false
      var error: NSError?
      converter.convert(to: out, error: &error) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
      deliver(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
  }
}
