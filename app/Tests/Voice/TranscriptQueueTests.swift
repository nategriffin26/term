import AVFoundation
import XCTest
@testable import Term

final class TranscriptQueueTests: XCTestCase {
  private let offline = TranscriptionFailure(problem: .offline, retriesByItself: true)
  private let badKey = TranscriptionFailure(problem: .badKey, retriesByItself: false)
  private let now = ContinuousClock.now

  private func file(_ i: Int) -> URL { URL(filePath: "/spool/\(i).m4a") }

  /// `count` segments spooled, the first two sent.
  private func queue(_ count: Int, run: Int = 0) -> (TranscriptQueue<String>, [Int]) {
    var q = TranscriptQueue<String>()
    let ids = (0..<count).map { i in
      let id = q.reserve(run: run, target: "t")
      q.setAudio(file(i), for: id)
      return id
    }
    _ = q.send()
    return (q, ids)
  }

  /// Catches typing in reply order: later segments wait for every earlier one.
  func testOutOfOrderRepliesTypeInSpokenOrder() {
    var (q, ids) = queue(3)
    XCTAssertEqual(q.complete(ids[2], reply: "three").map(\.text), [])
    XCTAssertEqual(q.complete(ids[0], reply: "one").map(\.text), ["one"])
    XCTAssertEqual(q.complete(ids[1], reply: "two").map(\.text), ["two", "three"])
    XCTAssertTrue(q.isEmpty)
  }

  /// Catches lost speech offline: a failed segment keeps its place and audio,
  /// holds later ones back, goes again when the network returns, and its
  /// file is let go only once it is typed.
  func testOfflineSegmentWaitsThenTypesInOrder() {
    var (q, ids) = queue(2)
    q.fail(ids[0], offline, at: now)
    XCTAssertEqual(q.complete(ids[1], reply: "two").map(\.text), [])
    XCTAssertEqual(q.problem, .offline)
    XCTAssertEqual(q.count, 2)
    XCTAssertEqual(q.takeReleasedAudio(), [])
    q.retry(all: false)
    XCTAssertEqual(q.send().map(\.audio), [file(0)])
    XCTAssertEqual(q.complete(ids[0], reply: "one").map(\.text), ["one", "two"])
    XCTAssertEqual(q.takeReleasedAudio(), [file(0), file(1)])
  }

  /// Catches hammering OpenRouter with a refused key: only the user's retry sends those again.
  func testOnlyFailuresThatClearUpRetryByThemselves() {
    var (q, ids) = queue(2)
    q.fail(ids[0], badKey, at: now)
    q.fail(ids[1], offline, at: now)
    XCTAssertEqual(q.problem, .badKey)
    q.retry(all: false)
    XCTAssertEqual(q.send().map(\.id), [ids[1]])
    q.fail(ids[1], offline, at: now)
    q.retry(all: true)
    XCTAssertEqual(q.send().map(\.id), ids)
  }

  /// Catches unbounded requests: two at most are in flight (one held for the
  /// network included), the rest go in spoken order as slots free, and a
  /// segment still encoding is never sent.
  func testAtMostTwoInFlightInSpokenOrder() {
    var q = TranscriptQueue<String>()
    let ids = (0..<4).map { i in
      let id = q.reserve(run: 0, target: "t")
      q.setAudio(file(i), for: id)
      return id
    }
    let encoding = q.reserve(run: 0, target: "t")
    XCTAssertEqual(q.send().map(\.id), [ids[0], ids[1]])
    XCTAssertEqual(q.send().map(\.id), [])
    q.waiting(ids[0])
    XCTAssertEqual(q.send().map(\.id), [])
    _ = q.complete(ids[1], reply: "two")
    XCTAssertEqual(q.send().map(\.id), [ids[2]])
    q.fail(ids[0], offline, at: now)
    XCTAssertEqual(q.send().map(\.id), [ids[3]])
    _ = q.complete(ids[2], reply: "three")
    XCTAssertEqual(q.send().map(\.id), [])
    q.setAudio(file(4), for: encoding)
    XCTAssertEqual(q.send().map(\.id), [encoding])
  }

  /// Catches a success elsewhere moving a failed segment's retry: it goes at
  /// its own time (2 s, then 4 s after the next failure), whatever else answers.
  func testFailedSegmentKeepsItsOwnRetrySchedule() {
    var (q, ids) = queue(2)
    q.fail(ids[0], offline, at: now)
    XCTAssertEqual(q.nextRetry, now + .seconds(2))
    _ = q.complete(ids[1], reply: "two")
    XCTAssertEqual(q.nextRetry, now + .seconds(2))
    q.retryDue(at: now + .milliseconds(1_999))
    XCTAssertEqual(q.send().map(\.id), [])
    q.retryDue(at: now + .seconds(2))
    XCTAssertEqual(q.send().map(\.id), [ids[0]])
    q.fail(ids[0], offline, at: now + .seconds(2))
    XCTAssertEqual(q.nextRetry, now + .seconds(6))
    q.retry(all: true)
    _ = q.send()
    q.fail(ids[0], offline, at: now + .seconds(3))
    XCTAssertEqual(q.nextRetry, now + .seconds(5), "the user's retry starts the schedule over")
    q.fail(ids[0], badKey, at: now + .seconds(3))
    XCTAssertNil(q.nextRetry, "a refused key waits for the user")
  }

  /// Catches a schedule that never backs off or grows past a minute.
  func testRetryDelayDoublesUpToAMinute() {
    XCTAssertEqual((1...7).map(TranscriptQueue<String>.retryDelay(after:)),
                   [2, 4, 8, 16, 32, 60, 60].map(Duration.seconds))
  }

  /// Catches context leaking across runs or growing without bound: the prompt
  /// is this run's typed text, its last 200 characters.
  func testPromptIsTheRunsTypedTail() {
    var q = TranscriptQueue<String>()
    let first = q.reserve(run: 1, target: "t")
    q.setAudio(file(1), for: first)
    XCTAssertEqual(q.send().first?.prompt, "")
    let long = String(repeating: "word ", count: 60) + "end."
    _ = q.complete(first, reply: long)
    let second = q.reserve(run: 1, target: "t")
    q.setAudio(file(2), for: second)
    let prompt = q.send().first?.prompt ?? ""
    XCTAssertEqual(prompt.count, 200)
    XCTAssertTrue(prompt.hasSuffix("word end."))
    let other = q.reserve(run: 2, target: "t")
    q.setAudio(file(3), for: other)
    XCTAssertEqual(q.send().first?.prompt, "")
  }

  /// Catches genuine repeated speech deleted as an echo of the prompt: "yes",
  /// a pause until it appears, then "yes" again types both (the speech gate,
  /// not the text, decides what was said).
  func testRepeatedSpeechIsTyped() {
    var (q, ids) = queue(3)
    XCTAssertEqual(q.complete(ids[0], reply: "Yes.").map(\.text), ["Yes."])
    XCTAssertEqual(q.complete(ids[1], reply: "Yes.").map(\.text), ["Yes."])
    XCTAssertEqual(q.complete(ids[2], reply: "yes yes").map(\.text), ["yes yes"])
  }

  /// Catches the model's invented text in another script being typed (with
  /// English fixed, Cyrillic or Japanese was never said), while English with
  /// accents or a stray Greek letter is kept.
  func testReplyMostlyInAnotherScriptIsNotTyped() {
    var (q, ids) = queue(5)
    XCTAssertEqual(q.complete(ids[0], reply: "Продолжение следует...").map(\.text), [])
    XCTAssertEqual(q.complete(ids[1], reply: "ご視聴ありがとうございました").map(\.text), [])
    XCTAssertEqual(q.complete(ids[2], reply: "Open Términos y condiciones at the café.").map(\.text),
                   ["Open Términos y condiciones at the café."])
    XCTAssertEqual(q.complete(ids[3], reply: "Area is πr².").map(\.text), ["Area is πr²."])
    XCTAssertEqual(q.complete(ids[4], reply: "μs").map(\.text), ["μs"])
  }

  /// Catches an empty reply blocking the queue.
  func testEmptyReplyTypesNothingAndUnblocks() {
    var (q, ids) = queue(2)
    XCTAssertEqual(q.complete(ids[1], reply: "two").map(\.text), [])
    XCTAssertEqual(q.complete(ids[0], reply: "  \n").map(\.text), ["two"])
  }

  /// Catches a discarded segment typing later, or its file left on disk
  /// (one still encoding when the queue was discarded included).
  func testDiscardForgetsSegmentsAndLetsTheirFilesGo() {
    var (q, ids) = queue(2)
    let encoding = q.reserve(run: 0, target: "t")
    q.discard()
    XCTAssertEqual(q.complete(ids[0], reply: "late").map(\.text), [])
    XCTAssertTrue(q.isEmpty)
    q.setAudio(file(9), for: encoding)
    XCTAssertEqual(Set(q.takeReleasedAudio()), [file(0), file(1), file(9)])
    XCTAssertEqual(q.takeReleasedAudio(), [])
  }
}

final class DictatedTextTests: XCTestCase {
  /// Catches a transcript pressing Enter or ending the bracketed paste early (ESC [201~) to run a command.
  func testCleanLeavesOneLineWithoutControls() {
    let text = DictatedText.clean("  run\u{1b}[201~rm -rf ~\r\nnow\tplease\u{7}  \n")
    XCTAssertEqual(text, "run[201~rm -rf ~ now please")
    XCTAssertFalse(text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
  }

  /// Catches words running together across segments, or a space before closing punctuation.
  func testSpaceJoinsOnlyContinuingText() {
    XCTAssertEqual(DictatedText.typed("Hello", continuing: false), "Hello")
    XCTAssertEqual(DictatedText.typed("world", continuing: true), " world")
    XCTAssertEqual(DictatedText.typed(", then", continuing: true), ", then")
    XCTAssertEqual(DictatedText.typed("?", continuing: true), "?")
  }
}

final class OpenRouterTranscriberTests: XCTestCase {
  private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
  }

  /// Catches a request OpenRouter rejects or ignores: the measured shape (m4a base64,
  /// English, the prompt under provider.options.openai, never top-level).
  func testRequestShape() {
    let r = OpenRouterTranscriber.request(audio: Data([1, 2, 3]), prompt: "git status", model: "openai/gpt-4o-transcribe",
                                          key: "k", baseURL: OpenRouterTranscriber.defaultBaseURL)
    XCTAssertEqual(r.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
    XCTAssertEqual(r.httpMethod, "POST")
    XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let json = body(r)
    XCTAssertEqual(json["model"] as? String, "openai/gpt-4o-transcribe")
    XCTAssertEqual(json["language"] as? String, "en")
    XCTAssertNil(json["prompt"])
    let audio = json["input_audio"] as? [String: Any]
    XCTAssertEqual(audio?["data"] as? String, "AQID")
    XCTAssertEqual(audio?["format"] as? String, "m4a")
    let options = (json["provider"] as? [String: Any])?["options"] as? [String: Any]
    XCTAssertEqual((options?["openai"] as? [String: Any])?["prompt"] as? String, "git status")
  }

  /// Catches an empty prompt sent (it invites the echo on silence).
  func testNoPromptWithoutContext() {
    let r = OpenRouterTranscriber.request(audio: Data([1]), prompt: "", model: "m", key: "k",
                                          baseURL: OpenRouterTranscriber.defaultBaseURL)
    XCTAssertNil(body(r)["provider"])
  }

  /// Replies as OpenRouter sends them (recorded 2026-10-26, ids removed).
  func testReplies() throws {
    let ok = Data(#"{"text":"git rebase -i origin/main","usage":{"seconds":4.2,"cost":0.00028}}"#.utf8)
    XCTAssertEqual(try OpenRouterTranscriber.text(status: 200, body: ok), "git rebase -i origin/main")
    func failure(_ status: Int, _ body: String) -> TranscriptionFailure? {
      do { _ = try OpenRouterTranscriber.text(status: status, body: Data(body.utf8)); return nil } catch { return error }
    }
    XCTAssertEqual(failure(401, #"{"error":{"message":"User not found.","code":401}}"#),
                   TranscriptionFailure(problem: .badKey, retriesByItself: false))
    XCTAssertEqual(failure(402, #"{"error":{"message":"Insufficient credits","code":402}}"#)?.problem, .noCredit)
    XCTAssertEqual(failure(404, #"{"error":{"message":"No endpoints found","code":404}}"#)?.problem, .modelNotFound)
    XCTAssertEqual(failure(400, #"{"error":{"message":"Invalid audio","code":400}}"#),
                   TranscriptionFailure(problem: .other("Invalid audio"), retriesByItself: false))
    for status in [429, 502, 504] {
      XCTAssertEqual(failure(status, "<html>")?.retriesByItself, true, "\(status) retries by itself")
    }
    XCTAssertEqual(failure(200, #"{"usage":{}}"#)?.retriesByItself, true)
  }

  /// Catches a dropped connection read as a refusal (it must wait and retry).
  func testNetworkErrorsAreOffline() {
    XCTAssertEqual(OpenRouterTranscriber.failure(URLError(.notConnectedToInternet)), TranscriptionFailure(problem: .offline, retriesByItself: true))
    XCTAssertEqual(OpenRouterTranscriber.failure(URLError(.networkConnectionLost)).problem, .offline)
    XCTAssertEqual(OpenRouterTranscriber.failure(URLError(.badURL)).retriesByItself, false)
  }

  /// Catches an encoding OpenRouter cannot read or pays 24 KB of padding per
  /// request: a real m4a that still decodes to its second of audio, about 4 KB a second.
  func testSpeechEncodesAsCompactM4A() throws {
    let second = (0..<16_000).map { sinf(Float($0) * 0.1) * 0.3 }
    let data = try SpeechAudio.m4a(second)
    XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp")
    XCTAssertLessThan(data.count, 6_000)
    let url = FileManager.default.temporaryDirectory.appending(path: "decoded-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 20_000))
    try file.read(into: buffer)
    XCTAssertEqual(Double(buffer.frameLength), 16_000, accuracy: 1_100)
    let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    XCTAssertEqual(peak, 0.3, accuracy: 0.1, "the samples survive, not just the header")
    XCTAssertThrowsError(try SpeechAudio.m4a([]))
  }
}

/// The pipeline end to end with a fake service: a local fake of our own seam, failing on demand.
@MainActor
final class DictationTests: XCTestCase {
  private final class Terminal: DictationTarget {
    static let host = UUID()
    var typed: [String] = []
    var notices: [String] = []
    /// A tab showing tmux session "main" on a host, unless a test moves it.
    var dictationDestination: DictationDestination? = DictationDestination(host: Terminal.host, tmuxSession: "main")
    func typeDictation(_ text: String) { typed.append(text) }
    func dictationNotice(_ text: String) { notices.append(text) }
    func dictationNeedsSettings() {}
  }

  /// Answers with `reply(audio)` (the audio's bytes as text unless a test says
  /// otherwise) after `delay(text)`, or fails while `failure` is set or
  /// `fails(text)` says so. Counts calls per text and the most at once.
  private final class Service: Transcriber, @unchecked Sendable {
    let lock = NSLock()
    private var _failure: TranscriptionFailure?
    private var _calls: [String] = []
    private var _inFlight = 0
    private var _mostInFlight = 0
    var delay: @Sendable (String) -> Double = { _ in 0 }
    var reply: @Sendable (Data) -> String = { String(decoding: $0, as: UTF8.self) }
    var fails: @Sendable (String) -> TranscriptionFailure? = { _ in nil }
    var failure: TranscriptionFailure? {
      get { lock.withLock { _failure } }
      set { lock.withLock { _failure = newValue } }
    }
    var calls: Int { lock.withLock { _calls.count } }
    func calls(_ text: String) -> Int { lock.withLock { _calls.filter { $0 == text }.count } }
    var mostInFlight: Int { lock.withLock { _mostInFlight } }

    func transcribe(_ audio: URL, prompt: String,
                    waiting: @escaping @Sendable () -> Void) async throws(TranscriptionFailure) -> String {
      let text = reply((try? Data(contentsOf: audio)) ?? Data())
      lock.withLock {
        _calls.append(text)
        _inFlight += 1
        _mostInFlight = max(_mostInFlight, _inFlight)
      }
      try? await Task.sleep(for: .seconds(delay(text)))
      lock.withLock { _inFlight -= 1 }
      if let failure = failure ?? fails(text) { throw failure }
      return text
    }
  }

  private func until(_ what: String, timeout: Double = 5, _ done: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(done(), what)
  }

  private lazy var pasteboard = UIPasteboard.withUniqueName()

  /// A spool of its own in a temporary folder, removed after the test.
  private func spool(_ directory: URL? = nil) -> SpeechSpool {
    let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "spool-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return SpeechSpool(directory: directory)
  }

  private func make(_ service: Service, spool: SpeechSpool? = nil) -> Dictation {
    Dictation(transcriber: { service }, spool: spool ?? self.spool(), pasteboard: pasteboard)
  }

  private func files(in spool: SpeechSpool) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: spool.directory.path)) ?? []).sorted()
  }

  /// Catches replies typed in arrival order: "one" answers last but types first.
  func testSlowFirstSegmentStillTypesFirst() async {
    let service = Service()
    service.delay = { $0 == "one" ? 0.4 : 0 }
    let dictation = make(service)
    let terminal = Terminal()
    for word in ["one", "two", "three"] { dictation.send(Data(word.utf8), for: dictation.reserve(for: terminal)) }
    await until("typed in order") { terminal.typed.count == 3 }
    XCTAssertEqual(terminal.typed, ["one", "two", "three"])
    XCTAssertEqual(dictation.state, .idle)
  }

  /// Catches the made-up text bug at its source: segments the loudness
  /// detector cut from typing, room noise or music never reach the
  /// transcriber; spoken ones do, and type in the order they were said.
  func testOnlySpokenSegmentsAreSent() async throws {
    let service = Service()
    service.reply = { $0.count > 10_000 ? "sentence" : "yes" }
    let dictation = make(service)
    let terminal = Terminal()
    let sentence = try await TestAudio.speech("Show me the last ten lines of the server log, then open the readme.")
    let yes = try await TestAudio.speech("Yes.")
    dictation.segmentEnded(TestAudio.typing(seconds: 4), in: terminal)
    dictation.segmentEnded(sentence, in: terminal)
    dictation.segmentEnded(TestAudio.roomWithKnocks(seconds: 6), in: terminal)
    dictation.segmentEnded(yes, in: terminal)
    dictation.segmentEnded(TestAudio.music(seconds: 4), in: terminal)
    await until("both spoken segments typed") { terminal.typed.count >= 2 }
    try? await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(terminal.typed, ["sentence", "yes"])
    XCTAssertEqual(service.calls, 2, "only speech is sent")
    XCTAssertEqual(dictation.state, .idle)
  }

  /// Catches speech lost offline: segments queue as offline and type in order once the network returns.
  func testOfflineSegmentsTypeWhenTheNetworkReturns() async {
    let service = Service()
    service.failure = TranscriptionFailure(problem: .offline, retriesByItself: true)
    let dictation = make(service)
    let terminal = Terminal()
    for word in ["one", "two"] { dictation.send(Data(word.utf8), for: dictation.reserve(for: terminal)) }
    await until("queued offline") { dictation.state == .failed(queued: 2, problem: .offline) }
    XCTAssertEqual(terminal.typed, [])
    service.failure = nil
    dictation.networkReturned()
    await until("typed after the network returned") { terminal.typed.count == 2 }
    XCTAssertEqual(terminal.typed, ["one", "two"])
    XCTAssertEqual(dictation.state, .idle)
  }

  /// Catches a refused key retried in a loop or dropped: it waits, says so once, and goes on the user's retry.
  func testRefusedKeyWaitsForTheUser() async {
    let service = Service()
    service.failure = TranscriptionFailure(problem: .badKey, retriesByItself: false)
    let dictation = make(service)
    let terminal = Terminal()
    for word in ["one", "two"] { dictation.send(Data(word.utf8), for: dictation.reserve(for: terminal)) }
    await until("held for the key") { dictation.state == .failed(queued: 2, problem: .badKey) }
    XCTAssertEqual(terminal.notices.count, 1)
    dictation.networkReturned()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(service.calls, 2, "a refused key is not retried by itself")
    service.failure = nil
    dictation.retry()
    await until("typed after retry") { terminal.typed == ["one", "two"] }
  }

  /// Catches a discarded queue typing later.
  func testDiscardForgetsTheQueue() async {
    let service = Service()
    service.failure = TranscriptionFailure(problem: .other("Invalid audio"), retriesByItself: false)
    let dictation = make(service)
    let terminal = Terminal()
    dictation.send(Data("one".utf8), for: dictation.reserve(for: terminal))
    await until("failed") { dictation.state == .failed(queued: 1, problem: .other("Invalid audio")) }
    dictation.discard()
    XCTAssertEqual(dictation.state, .idle)
    service.failure = nil
    dictation.retry()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(terminal.typed, [])
  }

  /// Catches a one-word answer dropped by its length before the speech
  /// classifier hears it: "yes" clipped to 200 ms of voice goes from the
  /// microphone's samples through the segmenter (the mic turned off just
  /// after it), the gate and the service, and is typed.
  func testShortAnswerFromTheMicrophoneIsTyped() async throws {
    final class SampleMicrophone: Microphone {
      var onSamples: (@Sendable ([Float]) -> Void)?
      func start(_ done: @escaping @MainActor @Sendable (Error?) -> Void) { MainActor.assumeIsolated { done(nil) } }
      func stop() {}
    }
    let service = Service()
    service.reply = { _ in "Yes." }
    let microphone = SampleMicrophone()
    let dictation = Dictation(transcriber: { service }, microphone: { onSamples, _ in
      microphone.onSamples = onSamples
      return microphone
    }, spool: spool(), pasteboard: pasteboard)
    let terminal = Terminal()
    let yes = try await TestAudio.voice("Yes.", voicedFrames: 4)
    dictation.listen(into: terminal)
    let audio = TestAudio.room(seconds: 1.5) + yes + TestAudio.room(seconds: 0.2)
    for at in stride(from: 0, to: audio.count, by: 1_600) {
      microphone.onSamples?(Array(audio[at..<min(at + 1_600, audio.count)]))
    }
    try await Task.sleep(for: .milliseconds(100))
    dictation.stop()
    await until("the answer typed") { terminal.typed == ["Yes."] }
  }

  /// Catches every segment's request held open at once (long dictation
  /// through an outage): two at most are in flight, the rest go in spoken order.
  func testAtMostTwoRequestsInFlight() async {
    let service = Service()
    service.delay = { _ in 0.15 }
    let dictation = make(service)
    let terminal = Terminal()
    let words = ["one", "two", "three", "four", "five"]
    for word in words { dictation.send(Data(word.utf8), for: dictation.reserve(for: terminal)) }
    await until("all typed") { terminal.typed.count == words.count }
    XCTAssertEqual(terminal.typed, words)
    XCTAssertEqual(service.mostInFlight, 2)
  }

  /// Catches a success elsewhere defeating a failed segment's backoff: the
  /// failed segment goes again at its own deadline (2 s), not when another answers.
  func testSuccessElsewhereKeepsAFailedSegmentsRetryDeadline() async {
    let service = Service()
    service.fails = { $0 == "busy" ? TranscriptionFailure(problem: .other("Too many requests"), retriesByItself: true) : nil }
    service.delay = { $0 == "busy" ? 0 : 0.1 }
    let dictation = make(service)
    let terminal = Terminal()
    let start = ContinuousClock.now
    for word in ["busy", "ok"] { dictation.send(Data(word.utf8), for: dictation.reserve(for: terminal)) }
    await until("the other segment answered") { service.calls("ok") == 1 }
    try? await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(service.calls("busy"), 1, "retried when another segment succeeded")
    await until("retried at its deadline") { service.calls("busy") == 2 }
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(1_900))
    dictation.discard()
  }

  /// Catches a late reply typed into whatever the tab shows by then: another
  /// tmux session, or the local prompt after the connection closed. The text
  /// goes to the clipboard, joined in spoken order, and the strip says so.
  func testTextForASessionTheTabNoLongerShowsIsCopied() async {
    let service = Service()
    service.delay = { _ in 0.2 }
    let dictation = make(service)
    let moved = Terminal(), closed = Terminal()
    dictation.send(Data("one".utf8), for: dictation.reserve(for: moved))
    dictation.send(Data("two".utf8), for: dictation.reserve(for: closed))
    moved.dictationDestination = DictationDestination(host: Terminal.host, tmuxSession: "other")
    closed.dictationDestination = nil
    await until("copied") { pasteboard.string == "one two" }
    XCTAssertEqual(moved.typed + closed.typed, [])
    XCTAssertTrue(dictation.showsCopied)
  }

  /// Catches text said at the local prompt typed into the session the tab opened meanwhile.
  func testTextSaidAtTheLocalPromptIsCopied() async {
    let service = Service()
    service.delay = { _ in 0.2 }
    let dictation = make(service)
    let terminal = Terminal()
    terminal.dictationDestination = nil
    dictation.send(Data("one".utf8), for: dictation.reserve(for: terminal))
    terminal.dictationDestination = DictationDestination(host: Terminal.host, tmuxSession: "main")
    await until("copied") { pasteboard.string == "one" }
    XCTAssertEqual(terminal.typed, [])
  }

  /// Catches speech lost with its tab: a closed tab's text is copied.
  func testTextForAClosedTabIsCopied() async {
    let dictation = make(Service())
    var terminal: Terminal? = Terminal()
    let id = dictation.reserve(for: terminal!)
    terminal = nil
    dictation.send(Data("one".utf8), for: id)
    await until("copied") { pasteboard.string == "one" }
  }

  /// Catches a reconnect of the same tab into the same session treated as another session.
  func testReconnectIntoTheSameSessionStillTypes() async {
    let service = Service()
    service.delay = { _ in 0.2 }
    let dictation = make(service)
    let terminal = Terminal()
    let connection = NSObject()
    dictation.send(Data("one".utf8), for: dictation.reserve(for: terminal))
    terminal.dictationDestination = DictationDestination(host: Terminal.host, tmuxSession: "main", connection: connection)
    await until("typed") { terminal.typed == ["one"] }
    XCTAssertNil(pasteboard.string)
    XCTAssertFalse(dictation.showsCopied)
  }

  /// Catches dictation adding to text the user copied since: its own copies
  /// join, but what something else put on the clipboard is replaced.
  func testCopiesJoinOnlyDictationsOwnClipboardText() async {
    let dictation = make(Service())
    let terminal = Terminal()
    terminal.dictationDestination = nil
    dictation.send(Data("one".utf8), for: dictation.reserve(for: terminal))
    await until("copied") { pasteboard.string == "one" }
    pasteboard.string = "copied by hand"
    dictation.send(Data("two".utf8), for: dictation.reserve(for: terminal))
    await until("replaced") { pasteboard.string == "two" }
  }

  /// Catches queued speech held in memory or lost when the app quits: each
  /// segment waits as a file, the file goes once its text is out, and what an
  /// earlier launch left is transcribed in spoken order and copied, never typed.
  func testSpeechWaitsOnDiskAndOutlivesTheApp() async {
    let service = Service()
    service.failure = TranscriptionFailure(problem: .badKey, retriesByItself: false)
    let spool = spool()
    let quit = make(service, spool: spool)
    let terminal = Terminal()
    for word in ["one", "two"] { quit.send(Data(word.utf8), for: quit.reserve(for: terminal)) }
    await until("held for the key") { quit.state == .failed(queued: 2, problem: .badKey) }
    XCTAssertEqual(files(in: spool).map { try? Data(contentsOf: spool.directory.appending(path: $0)) },
                   [Data("one".utf8), Data("two".utf8)])
    service.failure = nil
    let relaunched = make(service, spool: SpeechSpool(directory: spool.directory))
    relaunched.transcribeLeftovers()
    await until("copied in spoken order") { pasteboard.string == "one two" }
    XCTAssertEqual(terminal.typed, [])
    await until("files let go") { files(in: spool).isEmpty }
    XCTAssertEqual(relaunched.state, .idle)
  }
}

final class DictationDestinationTests: XCTestCase {
  /// Catches text typed into a session it was not said into: only the same
  /// tmux session on the same host (a reconnect into it included) or, with no
  /// session known, the same connection takes it.
  func testSameSessionOrSameConnectionOnly() {
    let host = UUID(), otherHost = UUID()
    let connection = NSObject(), replacement = NSObject()
    let said = DictationDestination(host: host, tmuxSession: "main", connection: connection)
    XCTAssertTrue(said.admits(DictationDestination(host: host, tmuxSession: "main", connection: replacement)), "a reconnect into the session")
    XCTAssertFalse(said.admits(DictationDestination(host: host, tmuxSession: "work", connection: connection)), "another session")
    XCTAssertFalse(said.admits(DictationDestination(host: otherHost, tmuxSession: "main", connection: replacement)), "the same name on another host")
    XCTAssertFalse(said.admits(DictationDestination(host: host, tmuxSession: nil, connection: connection)), "detached from tmux")
    XCTAssertFalse(said.admits(nil), "the local prompt")
    let unnamed = DictationDestination(host: host, tmuxSession: nil, connection: connection)
    XCTAssertTrue(unnamed.admits(DictationDestination(host: host, tmuxSession: "main", connection: connection)),
                  "the same connection, its session named since")
    XCTAssertFalse(unnamed.admits(DictationDestination(host: host, tmuxSession: nil, connection: replacement)), "a new connection")
    XCTAssertFalse(DictationDestination(host: host, tmuxSession: nil).admits(DictationDestination(host: host, tmuxSession: nil)),
                   "a connection that is gone")
  }
}

final class VoiceStripTests: XCTestCase {
  /// Catches the trace jumping or repeating bars: only the levels a delivery
  /// added are new, while the window grows and once it slides.
  @MainActor
  func testNewLevelsAreOnlyThoseADeliveryAdded() {
    let window = (1...40).map(Float.init)
    XCTAssertEqual(VoiceStripView.newLevels([1, 2, 3, 4], after: [1, 2]), [3, 4])
    XCTAssertEqual(VoiceStripView.newLevels(Array(window.dropFirst(2)) + [41, 42], after: window), [41, 42])
    XCTAssertEqual(VoiceStripView.newLevels(Array(window.dropFirst(1)) + [41], after: window), [41])
    XCTAssertEqual(VoiceStripView.newLevels([5, 6], after: []), [5, 6])
    XCTAssertEqual(VoiceStripView.newLevels([], after: [1]), [])
  }
}
