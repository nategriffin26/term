import AVFoundation
import Network
import UIKit

extension Notification.Name {
  /// Posted on the main thread when `Dictation.shared.state` or `note` changes.
  static let voiceStateChanged = Notification.Name("VoiceStateChanged")
}

/// Where dictated text goes: the terminal the microphone was turned on in.
@MainActor
protocol DictationTarget: AnyObject {
  /// Where input typed here goes now; nil at the local prompt.
  var dictationDestination: DictationDestination? { get }
  /// The prompt for what is said here (`DictationPrompt`): the end of the screen and the text last dictated.
  var dictationPrompt: String { get }
  /// Types a recording's text at the cursor.
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

/// Voice to text for the Smart Keys mic key. Records from the tap that
/// starts listening to the tap that stops it, sending nothing meanwhile; then
/// cuts the clearly silent stretches, sets what is left to one level, cuts it
/// at pauses into parts of a minute at most, sends it when the speech
/// classifier hears speech anywhere in it (less any part it is sure holds
/// none), transcribes the parts two at a time, cleans the recording's text
/// up when that is on (`DictationCleanup`; the transcript itself when that
/// fails) and types it once, joined in order. A recording with no speech
/// types nothing and says so.
/// Speech is never dropped for a slow or missing network: parts wait on
/// disk, failed ones keep their place and go again on their own schedule,
/// when the network returns, on coming back to the app, or on a tap. Text
/// whose terminal now shows another session goes to the clipboard instead.
@MainActor
final class Dictation {
  static let shared = Dictation(transcriber: Dictation.openRouter, cleanup: Dictation.openRouterCleanup,
                                words: { AppSettings.shared.dictationWords })

  private(set) var state = VoiceState.idle {
    didSet { if state != oldValue { NotificationCenter.default.post(name: .voiceStateChanged, object: self) } }
  }
  /// What the strip says for a moment: text went to the clipboard, or a recording held no speech.
  private(set) var note: VoiceNote? {
    didSet { if note != oldValue { NotificationCenter.default.post(name: .voiceStateChanged, object: self) } }
  }
  var isListening: Bool { capture != nil }
  /// The microphone did not start; tapping the strip or the mic tries again.
  private var microphoneFailed = false

  private let transcriber: @MainActor () -> Transcriber?
  /// Cleanup as Settings › Voice has it now; nil when it is off.
  private let cleanup: @MainActor () -> DictationCleanup?
  /// The words to get right, for the transcription prompt and cleanup.
  private let words: @MainActor () -> [String]
  private let microphone: MicrophoneFactory
  private let startDeadline: Duration
  private let spool: SpeechSpool
  private let pasteboard: UIPasteboard
  private weak var target: DictationTarget?
  /// Where the recording's text goes: the target's input when listening started.
  private var destination = Destination(view: nil, place: nil)
  private var capture: Microphone?
  private var startTimer: Task<Void, Never>?
  private var recording = Recording()
  private var heard = HeardLevels()
  private let gate = SpeechGate()
  private var queue = TranscriptQueue<Destination>()
  /// Stopped recordings the speech classifier is still judging.
  private var judging = 0
  /// Counts listenings, so a microphone's late answer reaches only its own.
  private var run = 0
  private var path: NWPathMonitor?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  private var retryTimer: Task<Void, Never>?
  private var noteTimer: Task<Void, Never>?
  /// What dictation last put on the clipboard, while nothing else replaced
  /// it: text copied next is added to it rather than replacing it.
  private var copied: (text: String, changeCount: Int)?

  /// Makes the microphone: samples arrive on the audio thread; the failure, on the main actor.
  typealias MicrophoneFactory = @MainActor (_ onSamples: @escaping @Sendable ([Float]) -> Void,
                                            _ onFailure: @escaping @MainActor @Sendable () -> Void) -> Microphone

  /// A recording's terminal, and where that terminal's input went when listening started.
  struct Destination {
    weak var view: DictationTarget?
    let place: DictationDestination?
  }

  /// `startDeadline`: how long the microphone may take to start before listening
  /// fails; AudioToolbox's own limit for an audio server that stopped answering.
  init(transcriber: @escaping @MainActor () -> Transcriber?,
       cleanup: @escaping @MainActor () -> DictationCleanup? = { nil },
       words: @escaping @MainActor () -> [String] = { [] },
       microphone: @escaping MicrophoneFactory = { MicrophoneCapture(onSamples: $0, onFailure: $1) },
       startDeadline: Duration = .seconds(9),
       spool: SpeechSpool = SpeechSpool(directory: AppDirectories.speech),
       pasteboard: UIPasteboard = .general) {
    self.transcriber = transcriber
    self.cleanup = cleanup
    self.words = words
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
    let (key, base) = openRouterAccess()
    guard let key else { return nil }
    return OpenRouterTranscriber(key: key, model: AppSettings.shared.voiceModel, baseURL: base)
  }

  /// Cleanup through the same OpenRouter key; nil when Settings › Voice turned it off.
  static func openRouterCleanup() -> DictationCleanup? {
    guard AppSettings.shared.cleansUpDictation else { return nil }
    let (key, base) = openRouterAccess()
    return DictationCleanup(key: key, baseURL: base)
  }

  private static func openRouterAccess() -> (key: String?, baseURL: URL) {
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
    return (key?.isEmpty == false ? key : nil, base)
  }

  // MARK: - Listening

  /// The mic key: starts listening into `target`, or stops.
  func toggle(in target: DictationTarget) {
    if isListening { stop() } else { start(in: target) }
  }

  func start(in target: DictationTarget) {
    // A tap delivered while the app is still coming back to the front is
    // dropped: the audio session does not start for an app that isn't active.
    guard !isListening, UIApplication.shared.applicationState == .active else {
      DiagnosticLog.record(.voice, "start-declined", "reason=\(isListening ? "listening" : "inactive")")
      return
    }
    guard transcriber() != nil else {
      DiagnosticLog.record(.voice, "start-declined", "reason=no-key")
      target.dictationNeedsSettings()
      return
    }
    // Asked of the permission system, not the audio server: a stalled audio
    // server (rpc_timeout is off) must not freeze the main thread here.
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      listen(into: target)
    case .notDetermined:
      Task { [weak self, weak target] in
        guard await AVCaptureDevice.requestAccess(for: .audio), let self, let target else { return }
        listen(into: target)
      }
    default:
      DiagnosticLog.record(.voice, "start-declined", "reason=microphone-denied")
      target.dictationNotice("Turn on Microphone for Term in the Settings app")
    }
  }

  /// Stops listening; what was said is transcribed and typed.
  func stop() {
    guard let capture else { return }
    capture.stop()
    self.capture = nil
    DiagnosticLog.record(.voice, "stopped", "run=\(run) seconds=\(DiagnosticLog.seconds(Double(recording.samples.count) / Double(Recording.sampleRate)))")
    startTimer?.cancel()
    startTimer = nil
    transcribe(recording, into: destination, prompt: target?.dictationPrompt ?? "")
    recording = Recording()
    gate.release()
    target = nil
    heard = HeardLevels()
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
    DiagnosticLog.record(.voice, "listening", "run=\(run)")
    self.capture = capture
    self.target = target
    destination = Destination(view: target, place: target.dictationDestination)
    recording = Recording()
    heard = HeardLevels()
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
    DiagnosticLog.record(.voice, "microphone-failed", "run=\(run)")
    stop()
    microphoneFailed = true
    update()
  }

  private func heard(_ samples: [Float], run: Int) {
    guard run == self.run, isListening else { return }
    heard.add(recording.append(samples))
    update()
  }

  // MARK: - Transcribing

  /// A stopped recording: leveled, its silences cut, and judged by the speech
  /// classifier; with speech, its parts are queued for transcription, and
  /// without, the strip says there was no speech, at once when the
  /// recording is empty.
  private func transcribe(_ recording: Recording, into destination: Destination, prompt: String) {
    guard !recording.loudness.isEmpty else {
      DiagnosticLog.record(.voice, "no-speech", "reason=empty")
      return show(.noSpeech)
    }
    judging += 1
    gate.judge(recording) { [weak self] parts in
      guard let self else { return }
      judging -= 1
      DiagnosticLog.record(.voice, parts.isEmpty ? "no-speech" : "judged", "parts=\(parts.count)")
      if parts.isEmpty {
        show(.noSpeech)
      } else {
        let ids = reserve(parts: parts.count, destination, prompt: prompt)
        for (id, part) in zip(ids, parts) {
          Task.detached(priority: .userInitiated) { [weak self] in
            let audio = try? SpeechAudio.m4a(part[...])
            await self?.encoded(id, audio)
          }
        }
      }
      update()
    }
  }

  private func encoded(_ id: Int, _ audio: Data?) {
    if let audio { send(audio, for: id) } else { spooled(id, nil) }
  }

  /// Holds a place in order for a recording of `parts` parts said into `target` now; returns the parts' ids.
  func reserve(parts: Int, for target: DictationTarget) -> [Int] {
    reserve(parts: parts, Destination(view: target, place: target.dictationDestination), prompt: target.dictationPrompt)
  }

  private func reserve(parts: Int, _ destination: Destination, prompt: String) -> [Int] {
    watchNetwork()
    let ids = queue.reserve(parts: parts, target: destination, prompt: prompt, cleansUp: true)
    update()
    return ids
  }

  /// Spools a part's audio (m4a) to disk; it is sent once a request slot is free.
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
      cleanUp()
    }
    update()
  }

  /// Speech said before the app last quit: each file transcribed in order
  /// and copied to the clipboard, never typed (where it was said is gone).
  func transcribeLeftovers() {
    let files = spool.leftovers()
    guard !files.isEmpty else { return }
    for file in files {
      for id in reserve(parts: 1, Destination(view: nil, place: nil), prompt: "") { queue.setAudio(file, for: id) }
    }
    resend()
  }

  /// Sends spooled parts, earliest first, while a request slot is free.
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
      let prompt = DictationPrompt.adding(DictationWords.bounded(words()), to: request.prompt)
      Task { [weak self] in
        let start = ProcessInfo.processInfo.systemUptime
        do throws(TranscriptionFailure) {
          let text = try await transcriber.transcribe(request.audio, prompt: prompt) { [weak self] in
            Task { @MainActor in self?.waiting(request.id) }
          }
          DiagnosticLog.record(.voice, "transcribed",
            "part=\(request.id) seconds=\(DiagnosticLog.seconds(ProcessInfo.processInfo.systemUptime - start)) characters=\(text.count)")
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
    cleanUp()
    sendReady()
    update()
  }

  /// Each recording whose text is all back goes through cleanup (or, with
  /// it off, straight on); its text types once every earlier one's has.
  private func cleanUp() {
    for item in queue.takeCleanups() {
      guard let cleanup = cleanup() else {
        cleaned(item, DictationCleanup.Result(text: item.text, status: .off), after: .zero)
        continue
      }
      let vocabulary = DictationWords.bounded(words())
      Task { [weak self] in
        let start = ContinuousClock.now
        let result = await cleanup.clean(item.text, vocabulary: vocabulary)
        self?.cleaned(item, result, after: ContinuousClock.now - start)
        self?.update()
      }
    }
  }

  /// Logs the outcome (never the text) and types what is now ready.
  private func cleaned(_ item: TranscriptQueue<Destination>.Cleanup, _ result: DictationCleanup.Result, after time: Duration) {
    DiagnosticLog.record(.voice, "cleanup",
      "status=\(result.status.rawValue) ms=\(Int(time / .milliseconds(1))) model=\(DictationCleanup.model) "
        + "words-in=\(DictationCleanup.words(item.text)) words-out=\(DictationCleanup.words(result.text))")
    output(queue.cleaned(item.recording, text: result.text))
  }

  private func failed(_ id: Int, _ failure: TranscriptionFailure) {
    let kind = switch failure.problem {
    case .offline: "offline"
    case .badKey: "bad-key"
    case .noCredit: "no-credit"
    case .modelNotFound: "model-not-found"
    case .other: "other"
    }
    DiagnosticLog.record(.voice, "transcription-failed", "part=\(id) problem=\(kind) retries=\(failure.retriesByItself)")
    let target = queue.entries.first { $0.id == id }?.target.view
    let wasStuck = queue.problem != nil
    queue.fail(id, failure, at: .now)
    if failure.retriesByItself {
      scheduleRetry()
    } else if !wasStuck {
      // Once, for the first part held up; the strip shows the rest.
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

  /// Types each recording's text into its terminal while that terminal's
  /// input still goes where it went when listening started; copies it otherwise.
  private func output(_ ready: [TranscriptQueue<Destination>.Typed]) {
    for typed in ready {
      if let view = typed.target.view, let place = typed.target.place, place.admits(view.dictationDestination) {
        DiagnosticLog.record(.voice, "typed")
        view.typeDictation(typed.text)
      } else {
        DiagnosticLog.record(.voice, "copied", "reason=\(typed.target.view == nil ? "no-terminal" : "destination-changed")")
        copy(typed.text)
      }
    }
  }

  private func copy(_ text: String) {
    let joined = copied.flatMap { $0.changeCount == pasteboard.changeCount ? $0.text + " " + text : nil } ?? text
    pasteboard.string = joined
    copied = (joined, pasteboard.changeCount)
    show(.copied)
  }

  /// Shows `note` in the strip for 3 seconds, and says it to VoiceOver.
  private func show(_ note: VoiceNote) {
    self.note = note
    UIAccessibility.post(notification: .announcement, argument: note == .copied ? "Dictated text copied" : "No speech heard")
    noteTimer?.cancel()
    noteTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.note = nil
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

  /// Wakes at the earliest failed part's own time to go again.
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
    let busy = !queue.isEmpty || judging > 0
    if isListening {
      state = .listening(heard)
    } else if let problem = queue.problem {
      state = .failed(queued: queue.count, problem: problem)
    } else if microphoneFailed {
      state = .microphoneUnavailable
    } else if busy, judging == 0, queue.cleaningCount == queue.count {
      state = .cleaningUp(pending: queue.count)
    } else if busy {
      state = .transcribing(pending: queue.count + judging)
    } else {
      state = .idle
    }
    // Recordings still on their way finish after the app leaves the screen.
    if !busy, backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    } else if busy, backgroundTask == .invalid {
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
