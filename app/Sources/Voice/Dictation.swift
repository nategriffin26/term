import AVFoundation
import Network
import UIKit

extension Notification.Name {
  /// Posted on the main thread when `Dictation.shared.state` changes.
  static let voiceStateChanged = Notification.Name("VoiceStateChanged")
}

/// Where dictated text goes: the terminal the microphone was turned on in.
@MainActor
protocol DictationTarget: AnyObject {
  /// Types a transcript at the cursor.
  func typeDictation(_ text: String)
  /// Says what went wrong (the microphone refused, the key rejected).
  func dictationNotice(_ text: String)
  /// Settings › Voice: there is no OpenRouter key yet, or the strip's failure is fixed there.
  func dictationNeedsSettings()
}

/// Voice to text for the Smart Keys mic key. Listens, cuts speech into
/// segments at pauses, sends each the moment it ends and types its text
/// in spoken order, so words appear while the user is still talking.
/// Speech is never dropped for a slow or missing network: failed segments
/// keep their place and go again when the network returns, when the
/// service answers again, on coming back to the app, or on a tap.
@MainActor
final class Dictation {
  static let shared = Dictation(transcriber: Dictation.openRouter)

  private(set) var state = VoiceState.idle {
    didSet { if state != oldValue { NotificationCenter.default.post(name: .voiceStateChanged, object: self) } }
  }
  var isListening: Bool { capture != nil }

  private let transcriber: @MainActor () -> Transcriber?
  private weak var target: DictationTarget?
  private var capture: MicrophoneCapture?
  private var segmenter = SpeechSegmenter()
  private var queue = TranscriptQueue<WeakTarget>()
  private var run = 0
  private var levels: [Float] = []
  private var path: NWPathMonitor?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  /// Segments that fail by themselves go again after 2 s, then 4, 8 … up to a minute.
  private var retryDelay = Dictation.firstRetryDelay
  private var retryTimer: Task<Void, Never>?
  private var engineObserver: NSObjectProtocol?

  private static let firstRetryDelay = Duration.seconds(2)
  /// Levels the strip gets: the last 2 s.
  private static let levelCount = 40

  struct WeakTarget {
    weak var value: DictationTarget?
  }

  init(transcriber: @escaping @MainActor () -> Transcriber?) {
    self.transcriber = transcriber
    let center = NotificationCenter.default
    center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.retry(all: false) }
    }
    // A call, an alarm or another app taking the microphone.
    center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
    center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
  }

  /// The OpenRouter key and model from Settings › Voice; nil without a key.
  static func openRouter() -> Transcriber? {
    #if DEBUG
    // Simulator runs pass these in the environment (SIMCTL_CHILD_…); nothing ships them.
    let env = ProcessInfo.processInfo.environment
    let key = env["TERM_OPENROUTER_KEY"] ?? Keychain.openRouterKey()
    let base = env["TERM_OPENROUTER_BASE_URL"].flatMap(URL.init(string:)) ?? OpenRouterTranscriber.defaultBaseURL
    #else
    let key = Keychain.openRouterKey()
    let base = OpenRouterTranscriber.defaultBaseURL
    #endif
    guard let key, !key.isEmpty else { return nil }
    return OpenRouterTranscriber(key: key, model: AppSettings.shared.voiceModel, baseURL: base)
  }

  // MARK: - Listening

  /// The mic key: starts listening into `target`, or stops.
  func toggle(in target: DictationTarget) {
    if isListening { stop() } else { start(in: target) }
  }

  func start(in target: DictationTarget) {
    // A tap delivered while the app comes back to the front would start the
    // engine before the audio server takes it, and it aborts (seen on the simulator).
    guard !isListening, UIApplication.shared.applicationState == .active else { return }
    guard transcriber() != nil else {
      target.dictationNeedsSettings()
      return
    }
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      listen(into: target)
    case .undetermined:
      Task { [weak self, weak target] in
        guard await AVAudioApplication.requestRecordPermission(), let self, let target else { return }
        listen(into: target)
      }
    default:
      target.dictationNotice("Turn on Microphone for Term in the Settings app")
    }
  }

  /// Stops listening; what was said last is still sent.
  func stop() {
    guard let capture else { return }
    capture.stop()
    self.capture = nil
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    engineObserver = nil
    if let last = segmenter.finish(), let target { submit(last, to: target) }
    target = nil
    levels = []
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    update()
  }

  /// A terminal gave up the keyboard: listening into it stops with it.
  func targetLostFocus(_ view: DictationTarget) {
    if target === view { stop() }
  }

  private func listen(into target: DictationTarget) {
    guard !isListening else { return }
    let session = AVAudioSession.sharedInstance()
    run += 1
    let run = run
    let capture = MicrophoneCapture { [weak self] samples in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(samples, run: run) } }
    }
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
      try session.setActive(true)
      try capture.start()
    } catch {
      capture.stop()
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      target.dictationNotice("The microphone isn't available")
      return
    }
    self.capture = capture
    self.target = target
    segmenter = SpeechSegmenter()
    levels = []
    // A new route (headphones, AirPods) stops the engine: start again in its format.
    engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                            object: capture.notificationObject, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let capture = self.capture else { return }
        do { try capture.start() } catch { self.stop() }
      }
    }
    retry(all: true)
    update()
  }

  private func heard(_ samples: [Float], run: Int) {
    guard run == self.run, isListening, let target else { return }
    let out = segmenter.append(samples)
    levels.append(contentsOf: out.levels)
    if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
    for segment in out.segments { submit(segment, to: target) }
    update()
  }

  // MARK: - Transcribing

  /// A finished segment: its place in spoken order now, its audio once encoded.
  private func submit(_ samples: [Float], to target: DictationTarget) {
    let id = reserve(for: target)
    Task.detached(priority: .userInitiated) { [weak self] in
      let audio = try? SpeechAudio.m4a(samples)
      await self?.encoded(id, audio)
    }
  }

  private func encoded(_ id: Int, _ audio: Data?) {
    guard let audio else {
      type(queue.drop(id))
      update()
      return
    }
    send(audio, for: id)
  }

  /// Holds a place in spoken order for a segment said into `target`.
  func reserve(for target: DictationTarget) -> Int {
    watchNetwork()
    let id = queue.reserve(run: run, target: WeakTarget(value: target))
    update()
    return id
  }

  /// Sends a segment's audio (m4a) for transcription.
  func send(_ audio: Data, for id: Int) {
    queue.setAudio(audio, for: id)
    send(id)
  }

  private func send(_ id: Int) {
    guard let transcriber = transcriber() else {
      queue.fail(id, TranscriptionFailure(problem: .badKey, retriesByItself: false))
      update()
      return
    }
    guard let request = queue.send(id) else { return }
    update()
    Task { [weak self] in
      do throws(TranscriptionFailure) {
        let text = try await transcriber.transcribe(request.audio, prompt: request.prompt) { [weak self] in
          Task { @MainActor in self?.waiting(id) }
        }
        self?.finished(id, text)
      } catch {
        self?.failed(id, error)
      }
    }
  }

  private func waiting(_ id: Int) {
    queue.waiting(id)
    update()
  }

  private func finished(_ id: Int, _ text: String) {
    type(queue.complete(id, reply: text))
    retryDelay = Self.firstRetryDelay
    // An answer means the service works again: what failed by itself goes now.
    retry(all: false)
    update()
  }

  private func failed(_ id: Int, _ failure: TranscriptionFailure) {
    let target = queue.entries.first { $0.id == id }?.target.value
    let wasStuck = queue.problem != nil
    queue.fail(id, failure)
    if failure.retriesByItself {
      scheduleRetry()
    } else if !wasStuck {
      // Once, for the first segment held up; the strip shows the rest.
      let notice = switch failure.problem {
      case .offline: "Offline"
      case .badKey: "OpenRouter refused the key in Settings › Voice"
      case .noCredit: "OpenRouter is out of credit"
      case .modelNotFound: "OpenRouter has no model \(AppSettings.shared.voiceModel)"
      case .other(let message): message
      }
      target?.dictationNotice(notice)
    }
    update()
  }

  private func type(_ ready: [TranscriptQueue<WeakTarget>.Typed]) {
    for typed in ready { typed.target.value?.typeDictation(typed.text) }
  }

  // MARK: - Retrying

  /// The strip's tap: everything queued goes again.
  func retry() {
    retryTimer?.cancel()
    retryTimer = nil
    retryDelay = Self.firstRetryDelay
    retry(all: true)
  }

  /// Forgets everything queued.
  func discard() {
    retryTimer?.cancel()
    retryTimer = nil
    queue.discard()
    update()
  }

  /// The network came back (tests call this in place of the path monitor).
  func networkReturned() {
    queue.connected()
    retry(all: false)
  }

  private func retry(all: Bool) {
    for id in queue.retry(all: all) { send(id) }
    update()
  }

  private func scheduleRetry() {
    guard retryTimer == nil else { return }
    let delay = retryDelay
    retryDelay = min(retryDelay * 2, .seconds(60))
    retryTimer = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      retryTimer = nil
      retry(all: false)
    }
  }

  private func watchNetwork() {
    guard path == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkReturned() } }
    }
    monitor.start(queue: .main)
    path = monitor
  }

  // MARK: - State

  private func update() {
    type(queue.remove { $0.value == nil })
    if isListening {
      state = .listening(levels: levels)
    } else if let problem = queue.problem {
      state = .failed(queued: queue.count, problem: problem)
    } else if !queue.isEmpty {
      state = .transcribing(pending: queue.count)
    } else {
      state = .idle
    }
    // Segments still on their way finish after the app leaves the screen.
    if queue.isEmpty, backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    } else if !queue.isEmpty, backgroundTask == .invalid {
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transcribe speech") { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          UIApplication.shared.endBackgroundTask(self.backgroundTask)
          self.backgroundTask = .invalid
        }
      }
    }
  }
}
