import AVFoundation
import Network
import UIKit

extension Notification.Name {
  /// Posted on the main thread when `Dictation.shared.state` or `showsCopied` changes.
  static let voiceStateChanged = Notification.Name("VoiceStateChanged")
}

/// Where dictated text goes: the terminal the microphone was turned on in.
@MainActor
protocol DictationTarget: AnyObject {
  /// Where input typed here goes now; nil at the local prompt.
  var dictationDestination: DictationDestination? { get }
  /// Types a transcript at the cursor.
  func typeDictation(_ text: String)
  /// Says what went wrong (the microphone refused, the key rejected).
  func dictationNotice(_ text: String)
  /// Settings › Voice: there is no OpenRouter key yet, or the strip's failure is fixed there.
  func dictationNeedsSettings()
}

/// Where a terminal's input goes: a tmux session on a host, or, while the
/// session's name is not known, one connection to the host.
struct DictationDestination {
  let host: UUID
  let tmuxSession: String?
  weak var connection: AnyObject?

  /// Whether text said into `self` may be typed into `now`: the same tmux
  /// session on the same host (a reconnect into it included), or, with no
  /// session known, the very same connection.
  func admits(_ now: DictationDestination?) -> Bool {
    guard let now, now.host == host else { return false }
    if let tmuxSession { return now.tmuxSession == tmuxSession }
    return connection != nil && now.connection === connection
  }
}

/// Voice to text for the Smart Keys mic key. Listens, cuts speech into
/// segments at pauses, sends each the moment it ends and types its text
/// in spoken order, so words appear while the user is still talking.
/// Speech is never dropped for a slow or missing network: segments wait on
/// disk, failed ones keep their place and go again on their own schedule,
/// when the network returns, on coming back to the app, or on a tap. Text
/// whose terminal now shows another session goes to the clipboard instead.
@MainActor
final class Dictation {
  static let shared = Dictation(transcriber: Dictation.openRouter)

  private(set) var state = VoiceState.idle {
    didSet { if state != oldValue { NotificationCenter.default.post(name: .voiceStateChanged, object: self) } }
  }
  /// Text just went to the clipboard instead of its terminal; the strip says so for a moment.
  private(set) var showsCopied = false {
    didSet { if showsCopied != oldValue { NotificationCenter.default.post(name: .voiceStateChanged, object: self) } }
  }
  var isListening: Bool { capture != nil }
  /// The microphone did not start; tapping the strip or the mic tries again.
  private var microphoneFailed = false

  private let transcriber: @MainActor () -> Transcriber?
  private let microphone: MicrophoneFactory
  private let startDeadline: Duration
  private let spool: SpeechSpool
  private let pasteboard: UIPasteboard
  private weak var target: DictationTarget?
  private var capture: Microphone?
  private var startTimer: Task<Void, Never>?
  private var segmenter = SpeechSegmenter()
  private let gate = SpeechGate()
  private var queue = TranscriptQueue<Destination>()
  private var run = 0
  private var levels: [Float] = []
  private var path: NWPathMonitor?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  private var retryTimer: Task<Void, Never>?
  private var copiedTimer: Task<Void, Never>?
  /// What dictation last put on the clipboard, while nothing else replaced
  /// it: text copied next is added to it rather than replacing it.
  private var copied: (text: String, changeCount: Int)?

  /// Levels the strip gets: the last 2 s.
  private static let levelCount = 40
  /// The run of segments said before the app last quit.
  private static let leftoverRun = -1

  /// Makes the microphone: samples arrive on the audio thread; the failure, on the main actor.
  typealias MicrophoneFactory = @MainActor (_ onSamples: @escaping @Sendable ([Float]) -> Void,
                                            _ onFailure: @escaping @MainActor @Sendable () -> Void) -> Microphone

  /// A segment's terminal, and where that terminal's input went when the segment was said.
  struct Destination {
    weak var view: DictationTarget?
    let place: DictationDestination?
  }

  /// `startDeadline`: how long the microphone may take to start before listening
  /// fails; AudioToolbox's own limit for an audio server that stopped answering.
  init(transcriber: @escaping @MainActor () -> Transcriber?,
       microphone: @escaping MicrophoneFactory = { MicrophoneCapture(onSamples: $0, onFailure: $1) },
       startDeadline: Duration = .seconds(9),
       spool: SpeechSpool = SpeechSpool(directory: AppDirectories.speech),
       pasteboard: UIPasteboard = .general) {
    self.transcriber = transcriber
    self.microphone = microphone
    self.startDeadline = startDeadline
    self.spool = spool
    self.pasteboard = pasteboard
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
    #if targetEnvironment(simulator)
    // Simulator runs may pass these in the environment (SIMCTL_CHILD_…);
    // a device build has no way to send the key anywhere but OpenRouter.
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
    // A tap delivered while the app is still coming back to the front is
    // dropped: the audio session does not start for an app that isn't active.
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
    startTimer?.cancel()
    startTimer = nil
    if let last = segmenter.finish(), let target { segmentEnded(last, in: target) }
    gate.release()
    target = nil
    levels = []
    update()
  }

  /// A terminal gave up the keyboard: listening into it stops with it, and
  /// a microphone failure shown on its Smart Keys goes with them.
  func targetLostFocus(_ view: DictationTarget) {
    if target === view { stop() }
    if !isListening, microphoneFailed {
      microphoneFailed = false
      update()
    }
  }

  /// Turns the microphone on into `target`. Listening shows at once; a
  /// microphone that fails, or has not started by `startDeadline`, ends it
  /// in the strip's failed state.
  func listen(into target: DictationTarget) {
    guard !isListening else { return }
    run += 1
    let run = run
    let deadline = startDeadline
    startTimer = Task { [weak self] in
      try? await Task.sleep(for: deadline)
      guard !Task.isCancelled else { return }
      self?.microphoneStopped(run: run)
    }
    let capture = microphone({ [weak self] samples in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(samples, run: run) } }
    }, { [weak self] in
      self?.microphoneStopped(run: run)
    })
    microphoneFailed = false
    self.capture = capture
    self.target = target
    segmenter = SpeechSegmenter()
    levels = []
    gate.prepare { [weak self, weak target] loaded in
      guard !loaded, let self, let target, self.target === target else { return }
      target.dictationNotice("Speech detection isn't available")
      stop()
    }
    capture.start { [weak self] error in
      guard let self, run == self.run, isListening else { return }
      startTimer?.cancel()
      startTimer = nil
      if error != nil { microphoneStopped(run: run) }
    }
    retry(all: true)
  }

  /// The microphone of listening `run` failed, or never started.
  private func microphoneStopped(run: Int) {
    guard run == self.run, isListening else { return }
    stop()
    microphoneFailed = true
    update()
  }

  private func heard(_ samples: [Float], run: Int) {
    guard run == self.run, isListening, let target else { return }
    let out = segmenter.append(samples)
    levels.append(contentsOf: out.levels)
    if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
    for segment in out.segments { segmentEnded(segment, in: target) }
    update()
  }

  // MARK: - Transcribing

  /// A segment the loudness detector cut: sent only if the gate hears speech in it.
  func segmentEnded(_ samples: [Float], in target: DictationTarget) {
    let destination = Destination(view: target, place: target.dictationDestination)
    gate.judge(samples) { [weak self] speech in
      guard speech, let self else { return }
      submit(samples, to: destination)
    }
  }

  /// A finished segment: its place in spoken order now, its audio once encoded.
  private func submit(_ samples: [Float], to destination: Destination) {
    let id = reserve(destination, run: run)
    Task.detached(priority: .userInitiated) { [weak self] in
      let audio = try? SpeechAudio.m4a(samples)
      await self?.encoded(id, audio)
    }
  }

  private func encoded(_ id: Int, _ audio: Data?) {
    if let audio { send(audio, for: id) } else { spooled(id, nil) }
  }

  /// Holds a place in spoken order for a segment said into `target` now.
  func reserve(for target: DictationTarget) -> Int {
    reserve(Destination(view: target, place: target.dictationDestination), run: run)
  }

  private func reserve(_ destination: Destination, run: Int) -> Int {
    watchNetwork()
    let id = queue.reserve(run: run, target: destination)
    update()
    return id
  }

  /// Spools a segment's audio (m4a) to disk; it is sent once a request slot is free.
  func send(_ audio: Data, for id: Int) {
    let spool = spool
    Task.detached(priority: .userInitiated) { [weak self] in
      let file = try? spool.write(audio, id: id)
      await self?.spooled(id, file)
    }
  }

  private func spooled(_ id: Int, _ file: URL?) {
    if let file {
      queue.setAudio(file, for: id)
      sendReady()
    } else {
      output(queue.drop(id))
    }
    update()
  }

  /// Speech said before the app last quit: transcribed in order and copied
  /// to the clipboard, never typed (where it was said is gone).
  func transcribeLeftovers() {
    let files = spool.leftovers()
    guard !files.isEmpty else { return }
    for file in files {
      queue.setAudio(file, for: reserve(Destination(view: nil, place: nil), run: Self.leftoverRun))
    }
    resend()
  }

  /// Sends spooled segments, earliest first, while a request slot is free.
  private func sendReady() {
    guard let transcriber = transcriber() else {
      while case let requests = queue.send(), !requests.isEmpty {
        for request in requests {
          queue.fail(request.id, TranscriptionFailure(problem: .badKey, retriesByItself: false), at: .now)
        }
      }
      return
    }
    for request in queue.send() {
      Task { [weak self] in
        do throws(TranscriptionFailure) {
          let text = try await transcriber.transcribe(request.audio, prompt: request.prompt) { [weak self] in
            Task { @MainActor in self?.waiting(request.id) }
          }
          self?.finished(request.id, text)
        } catch {
          self?.failed(request.id, error)
        }
      }
    }
  }

  private func waiting(_ id: Int) {
    queue.waiting(id)
    update()
  }

  private func finished(_ id: Int, _ text: String) {
    output(queue.complete(id, reply: text))
    sendReady()
    update()
  }

  private func failed(_ id: Int, _ failure: TranscriptionFailure) {
    let target = queue.entries.first { $0.id == id }?.target.view
    let wasStuck = queue.problem != nil
    queue.fail(id, failure, at: .now)
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
    sendReady()
    update()
  }

  /// Types each transcript into its terminal while that terminal's input
  /// still goes where it went when the words were said; copies it otherwise.
  private func output(_ ready: [TranscriptQueue<Destination>.Typed]) {
    for typed in ready {
      if let view = typed.target.view, let place = typed.target.place, place.admits(view.dictationDestination) {
        view.typeDictation(typed.text)
      } else {
        copy(typed.text)
      }
    }
  }

  private func copy(_ text: String) {
    let joined = copied.flatMap { $0.changeCount == pasteboard.changeCount ? $0.text + " " + text : nil } ?? text
    pasteboard.string = joined
    copied = (joined, pasteboard.changeCount)
    showsCopied = true
    UIAccessibility.post(notification: .announcement, argument: "Dictated text copied")
    copiedTimer?.cancel()
    copiedTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.showsCopied = false
    }
  }

  // MARK: - Retrying

  /// The strip's tap: everything queued goes again, each schedule from the start.
  func retry() {
    retry(all: true)
  }

  /// Forgets everything queued.
  func discard() {
    queue.discard()
    scheduleRetry()
    update()
  }

  /// The network came back (tests call this in place of the path monitor).
  func networkReturned() {
    queue.connected()
    retry(all: false)
  }

  private func retry(all: Bool) {
    queue.retry(all: all)
    resend()
  }

  private func resend() {
    sendReady()
    scheduleRetry()
    update()
  }

  /// Wakes at the earliest failed segment's own time to go again.
  private func scheduleRetry() {
    retryTimer?.cancel()
    retryTimer = nil
    guard let at = queue.nextRetry else { return }
    retryTimer = Task { [weak self] in
      try? await Task.sleep(until: at, clock: .continuous)
      guard !Task.isCancelled, let self else { return }
      retryTimer = nil
      queue.retryDue(at: .now)
      resend()
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
    for file in queue.takeReleasedAudio() { spool.remove(file) }
    if isListening {
      state = .listening(levels: levels)
    } else if let problem = queue.problem {
      state = .failed(queued: queue.count, problem: problem)
    } else if microphoneFailed {
      state = .microphoneUnavailable
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
