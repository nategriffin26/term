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
    XCTAssertEqual(dictation.state, .listening(levels: []))
    microphones[0].finish(CocoaError(.featureUnsupported))
    XCTAssertEqual(dictation.state, .microphoneUnavailable)
    XCTAssertFalse(dictation.isListening)

    dictation.listen(into: terminal)
    let retried = try XCTUnwrap(microphones.dropFirst().first, "listening did not start again")
    retried.finish(nil)
    XCTAssertEqual(dictation.state, .listening(levels: []))
    XCTAssertTrue(retried.on)
  }

  /// Bug: an audio server that never answers left the mic lit forever.
  func testStartNotAnsweredByTheDeadlineFails() async throws {
    let dictation = dictation(deadline: .milliseconds(100))
    dictation.listen(into: terminal)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(dictation.state, .listening(levels: []), "failed before the deadline")
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
    XCTAssertEqual(dictation.state, .listening(levels: []))
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
