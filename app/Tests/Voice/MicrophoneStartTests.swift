import XCTest
@testable import Term

/// Starting the microphone: a start that fails, never answers or answers
/// too late ends in the strip's failed state, never in a crash or a mic
/// left on, and listening can start again.
@MainActor
final class MicrophoneStartTests: XCTestCase {
  /// Starts only when the test says how.
  private final class FakeMicrophone: Microphone {
    var done: (@MainActor @Sendable (Error?) -> Void)?
    var onFailure: (@MainActor @Sendable () -> Void)?
    /// On after a successful start, until stopped.
    private(set) var on = false
    private var stopped = false

    func start(_ done: @escaping @MainActor @Sendable (Error?) -> Void) { self.done = done }
    func stop() {
      stopped = true
      on = false
    }

    /// The start finishing, as MicrophoneCapture's queue does it: a stop asked for meanwhile still runs after.
    @MainActor func finish(_ error: Error?) {
      if error == nil, !stopped { on = true }
      done?(error)
    }
  }

  private final class Terminal: DictationTarget {
    var dictationDestination: DictationDestination? { nil }
    var dictationPrompt: String { "" }
    func typeDictation(_ text: String) {}
    func dictationNotice(_ text: String) {}
    func dictationNeedsSettings() {}
  }

  private var microphones: [FakeMicrophone] = []
  private let terminal = Terminal()

  private func dictation(deadline: Duration = .seconds(60)) -> Dictation {
    Dictation(transcriber: { nil }, microphone: { [unowned self] _, onFailure in
      let microphone = FakeMicrophone()
      microphone.onFailure = onFailure
      microphones.append(microphone)
      return microphone
    }, startDeadline: deadline)
  }

  /// Bug: the engine refusing to start (no input format, the session not
  /// activating) left the mic key lit with nothing heard, or only flashed a notice.
  func testFailedStartShowsMicrophoneUnavailableAndListensAgainOnRetry() throws {
    let dictation = dictation()
    dictation.listen(into: terminal)
    XCTAssertEqual(dictation.state, .listening(HeardLevels()))
    microphones[0].finish(CocoaError(.featureUnsupported))
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
    XCTAssertFalse(dictation.isListening)

    dictation.listen(into: terminal)
    let retried = try XCTUnwrap(microphones.dropFirst().first, "listening did not start again")
    retried.finish(nil)
    XCTAssertEqual(dictation.state, .listening(HeardLevels()))
    XCTAssertTrue(retried.on)
  }

  /// Bug: an audio server that never answers left the mic lit forever.
  func testStartNotAnsweredByTheDeadlineFails() async throws {
    let dictation = dictation(deadline: .milliseconds(100))
    dictation.listen(into: terminal)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(dictation.state, .listening(HeardLevels()), "failed before the deadline")
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
  }

  /// Bug: a start answering after the deadline turned listening back on, or left the microphone on unseen.
  func testStartAnsweringAfterTheDeadlineLeavesTheMicrophoneOff() async throws {
    let dictation = dictation(deadline: .milliseconds(50))
    dictation.listen(into: terminal)
    try await Task.sleep(for: .milliseconds(300))
    microphones[0].finish(nil)
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
    XCTAssertFalse(dictation.isListening)
    XCTAssertFalse(microphones[0].on)
  }

  /// Bug: a start that answers late, after the user turned the mic off, turned it back on.
  func testStopWhileStartingKeepsTheMicrophoneOff() {
    let dictation = dictation()
    dictation.listen(into: terminal)
    dictation.stop()
    microphones[0].finish(nil)
    XCTAssertEqual(dictation.state, .idle)
    XCTAssertFalse(microphones[0].on)
  }

  /// Bug: the microphone of an abandoned listening, failing late, ended the listening that replaced it.
  func testOldMicrophoneFailingDoesNotEndNewListening() {
    let dictation = dictation()
    dictation.listen(into: terminal)
    dictation.stop()
    dictation.listen(into: terminal)
    microphones[1].finish(nil)
    microphones[0].onFailure?()
    XCTAssertEqual(dictation.state, .listening(HeardLevels()))
  }

  /// Bug: an abandoned start answering late called off the new listening's deadline, leaving it lit forever.
  func testOldStartAnsweringKeepsTheNewDeadline() async throws {
    let dictation = dictation(deadline: .milliseconds(100))
    dictation.listen(into: terminal)
    dictation.stop()
    dictation.listen(into: terminal)
    microphones[0].finish(nil)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
  }

  /// Bug: the input failing to restart after a route change (AirPods in) left the mic lit and deaf.
  func testMicrophoneStoppingByItselfShowsUnavailable() {
    let dictation = dictation()
    dictation.listen(into: terminal)
    microphones[0].finish(nil)
    microphones[0].onFailure?()
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
  }

  /// Bug: the failure stayed on the Smart Keys after the keyboard went away.
  func testFailureClearsWhenTheTerminalLosesTheKeyboard() {
    let dictation = dictation()
    dictation.listen(into: terminal)
    microphones[0].finish(CocoaError(.featureUnsupported))
    dictation.targetLostFocus(terminal)
    XCTAssertEqual(dictation.state, .idle)
  }

  /// Bug (crash): AudioToolbox aborts the app when the audio server takes
  /// over 9 s to answer starting the microphone (AURemoteIO::Initialize,
  /// a loaded simulator). Term launches with `rpc_timeout` 0, which AudioToolbox
  /// reads as "wait" (Int32.max ms). Also fails if a new iOS drops the setting.
  func testAudioToolboxWaitsForASlowAudioServer() throws {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_Z24GetMediaServerRPCTimeoutv") else {
      return XCTFail("AudioToolbox no longer has GetMediaServerRPCTimeout(): check how it times out the audio server")
    }
    let timeout = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    XCTAssertEqual(timeout(), Int32.max)
  }
}

/// MicrophoneCapture's own start, with the audio calls replaced by steps
/// that record where they ran and can hang like a slow audio server.
@MainActor
final class MicrophoneCaptureTests: XCTestCase {
  private final class StagedInput: AudioInput, @unchecked Sendable {
    private let lock = NSLock()
    private var _ran: [Int] = []
    private var _onMain: [Bool] = []
    private var _released = 0
    /// The step that waits for `resume`, as an audio server that stopped answering.
    let hangs: Int?
    let reached = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    init(hangs: Int? = nil) { self.hangs = hangs }

    var ran: [Int] { lock.withLock { _ran } }
    var onMain: [Bool] { lock.withLock { _onMain } }
    var released: Int { lock.withLock { _released } }

    var steps: [() throws -> Void] {
      (0..<5).map { step in
        { [self] in
          lock.withLock {
            _ran.append(step)
            _onMain.append(Thread.isMainThread)
          }
          if step == hangs {
            reached.signal()
            resume.wait()
          }
        }
      }
    }

    func release() { lock.withLock { _released += 1 } }
  }

  private final class Terminal: DictationTarget {
    var dictationDestination: DictationDestination? { nil }
    var dictationPrompt: String { "" }
    func typeDictation(_ text: String) {}
    func dictationNotice(_ text: String) {}
    func dictationNeedsSettings() {}
  }

  /// Bug: AVAudioEngine was made on the main thread, before the start
  /// deadline, where a slow audio server froze the app: every step runs off it.
  func testEveryStepRunsOffTheMainThread() async {
    let input = StagedInput()
    let capture = MicrophoneCapture(input: input)
    let started = expectation(description: "started")
    capture.start { error in
      XCTAssertNil(error)
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(input.ran, [0, 1, 2, 3, 4])
    XCTAssertEqual(input.onMain, [false, false, false, false, false])
    capture.stop()
    MicrophoneCapture.queue.sync {}
    XCTAssertEqual(input.released, 1)
  }

  /// Bug: stopping during a start held up in a slow call waited behind it,
  /// then the start went on to turn the microphone on. Stop returns at once;
  /// once the call returns no later step runs and the microphone is given back.
  func testStopDuringAHungStepRunsNoFurtherStep() async throws {
    let input = StagedInput(hangs: 2)
    let capture = MicrophoneCapture(input: input)
    capture.start { _ in XCTFail("a stopped start answered") }
    XCTAssertEqual(input.reached.wait(timeout: .now() + 2), .success)
    let asked = ContinuousClock.now
    capture.stop()
    XCTAssertLessThan(ContinuousClock.now - asked, .milliseconds(50), "stop waited for the hung call")
    XCTAssertEqual(input.released, 0)
    input.resume.signal()
    MicrophoneCapture.queue.sync {}
    XCTAssertEqual(input.ran, [0, 1, 2])
    XCTAssertGreaterThanOrEqual(input.released, 1)
    try await Task.sleep(for: .milliseconds(100))
  }

  /// Bug: making the engine fell outside the start deadline. A first step
  /// that never answers still ends listening at the deadline, the app free meanwhile.
  func testDeadlineCoversMakingTheEngine() async throws {
    let input = StagedInput(hangs: 0)
    let dictation = Dictation(transcriber: { nil }, microphone: { _, _ in MicrophoneCapture(input: input) },
                              startDeadline: .milliseconds(100))
    dictation.listen(into: Terminal())
    XCTAssertEqual(dictation.state, .listening(HeardLevels()))
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
    input.resume.signal()
    MicrophoneCapture.queue.sync {}
    XCTAssertEqual(input.ran, [0])
    XCTAssertGreaterThanOrEqual(input.released, 1)
  }
}
