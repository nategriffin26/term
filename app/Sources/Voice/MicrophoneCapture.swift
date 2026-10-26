import AVFoundation
import Synchronization

/// What `Dictation` listens with. Called on the main thread.
protocol Microphone: AnyObject {
  /// Turns the microphone on; `done` comes back on the main actor with nil
  /// once samples will flow, or the error. It may take long, or never come,
  /// while the audio server is slow to answer; it never comes after `stop`.
  func start(_ done: @escaping @MainActor @Sendable (Error?) -> Void)
  /// Turns it off, without waiting for a start in progress.
  func stop()
}

/// The audio calls that turn the microphone on, each of which can wait long
/// on a slow audio server. Used only on `MicrophoneCapture.queue`.
protocol AudioInput: AnyObject {
  /// The steps, in order.
  var steps: [() throws -> Void] { get }
  /// Gives back whatever the steps took.
  func release()
}

/// The microphone as 16 kHz mono samples, delivered on the audio thread
/// about every 100 ms. Every audio session and engine call, making the
/// engine included, runs on one serial queue, never the main thread, so it
/// all falls inside `Dictation`'s start deadline. Stopping does not wait
/// for a start held up in a slow call: that start runs no further step and
/// gives the microphone back as soon as the call returns. One start per capture.
final class MicrophoneCapture: Microphone, @unchecked Sendable {
  static let queue = DispatchQueue(label: "MicrophoneCapture", qos: .userInitiated)

  /// AudioToolbox aborts the app when the audio server takes longer than
  /// its `rpc_timeout` preference (9 s unless set) to answer starting the
  /// microphone, and returns no error to handle; a loaded simulator hit it
  /// in AURemoteIO::Initialize and ::Start. 0 waits for the answer instead,
  /// and `Dictation` gives up on a start that takes too long. AudioToolbox
  /// reads it once per process, so this runs at launch, before any audio.
  static func waitForSlowAudioServer() {
    UserDefaults(suiteName: "com.apple.coreaudio")?.set(0, forKey: "rpc_timeout")
  }

  /// Touched only on `queue`.
  private let input: AudioInput
  private let stopped = Atomic<Bool>(false)

  /// `onFailure`: listening stopped by itself (the input could not restart after a route change).
  convenience init(onSamples: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @MainActor @Sendable () -> Void) {
    #if targetEnvironment(simulator)
    // Simulator runs play a file in place of the Mac's microphone (SIMCTL_CHILD_TERM_VOICE_FILE).
    if let path = ProcessInfo.processInfo.environment["TERM_VOICE_FILE"] {
      self.init(input: FileInput(url: URL(filePath: path), onSamples: onSamples))
      return
    }
    #endif
    self.init(input: EngineInput(onSamples: onSamples, onFailure: onFailure))
  }

  init(input: AudioInput) {
    self.input = input
  }

  func start(_ done: @escaping @MainActor @Sendable (Error?) -> Void) {
    Self.queue.async { [self] in
      var failure: Error?
      for step in input.steps {
        if stopped.load(ordering: .acquiring) { break }
        do {
          try step()
        } catch {
          failure = error
          break
        }
      }
      if stopped.load(ordering: .acquiring) {
        input.release()
        return
      }
      if failure != nil { input.release() }
      DispatchQueue.main.async { [failure] in MainActor.assumeIsolated { done(failure) } }
    }
  }

  func stop() {
    stopped.store(true, ordering: .releasing)
    Self.queue.async { [self] in input.release() }
  }
}

/// What `Dictation` hears: 16 kHz mono float samples.
extension MicrophoneCapture {
  static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechSegmenter.sampleRate),
                                    channels: 1, interleaved: false)!

  /// Converts each buffer to `format` and delivers its samples. Made outside
  /// any actor: the engine calls it on its own thread.
  static func tap(converter: AVAudioConverter, deliver: @escaping @Sendable ([Float]) -> Void) -> AVAudioNodeTapBlock {
    { buffer, _ in
      let ratio = format.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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

/// The real microphone: the shared audio session, and an engine tapping its input.
private final class EngineInput: AudioInput, @unchecked Sendable {
  private let onSamples: @Sendable ([Float]) -> Void
  private let onFailure: @MainActor @Sendable () -> Void
  // Touched only on `MicrophoneCapture.queue`.
  private var engine: AVAudioEngine?
  private var active = false
  private var tapped = false
  private var routeObserver: NSObjectProtocol?

  init(onSamples: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @MainActor @Sendable () -> Void) {
    self.onSamples = onSamples
    self.onFailure = onFailure
  }

  var steps: [() throws -> Void] {
    [
      { self.engine = AVAudioEngine() },
      {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
      },
      {
        try AVAudioSession.sharedInstance().setActive(true)
        self.active = true
      },
      { try self.installTap() },
      {
        try self.run()
        // A new route (headphones, AirPods) stops the engine: start again in its format.
        self.routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                    object: self.engine, queue: nil) { [weak self] _ in
          MicrophoneCapture.queue.async { self?.restart() }
        }
      },
    ]
  }

  func release() {
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    routeObserver = nil
    if tapped { engine?.inputNode.removeTap(onBus: 0) }
    tapped = false
    engine?.stop()
    engine = nil
    if active { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    active = false
  }

  private func restart() {
    guard tapped else { return }
    do {
      try installTap()
      try run()
    } catch {
      release()
      let onFailure = onFailure
      DispatchQueue.main.async { MainActor.assumeIsolated { onFailure() } }
    }
  }

  /// The tap in the input's current format.
  private func installTap() throws {
    guard let engine else { throw CocoaError(.featureUnsupported) }
    let input = engine.inputNode
    if tapped { input.removeTap(onBus: 0) }
    tapped = false
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
          let converter = AVAudioConverter(from: format, to: MicrophoneCapture.format)
    else { throw CocoaError(.featureUnsupported) }
    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format,
                     block: MicrophoneCapture.tap(converter: converter, deliver: onSamples))
    tapped = true
  }

  private func run() throws {
    guard let engine else { throw CocoaError(.featureUnsupported) }
    engine.prepare()
    try engine.start()
  }
}
