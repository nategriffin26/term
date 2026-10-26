import AVFoundation
import XCTest
@testable import Term

final class TranscriptQueueTests: XCTestCase {
  private let offline = TranscriptionFailure(problem: .offline, retriesByItself: true)
  private let badKey = TranscriptionFailure(problem: .badKey, retriesByItself: false)

  private func queue(_ count: Int, run: Int = 0) -> (TranscriptQueue<String>, [Int]) {
    var q = TranscriptQueue<String>()
    let ids = (0..<count).map { i in
      let id = q.reserve(run: run, target: "t")
      q.setAudio(Data([UInt8(i)]), for: id)
      _ = q.send(id)
      return id
    }
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
  /// holds later ones back, and goes again when the network returns.
  func testOfflineSegmentWaitsThenTypesInOrder() {
    var (q, ids) = queue(2)
    q.fail(ids[0], offline)
    XCTAssertEqual(q.complete(ids[1], reply: "two").map(\.text), [])
    XCTAssertEqual(q.problem, .offline)
    XCTAssertEqual(q.count, 2)
    XCTAssertEqual(q.retry(all: false), [ids[0]])
    XCTAssertEqual(q.send(ids[0])?.audio, Data([0]))
    XCTAssertEqual(q.complete(ids[0], reply: "one").map(\.text), ["one", "two"])
  }

  /// Catches hammering OpenRouter with a refused key: only the user's retry sends those again.
  func testOnlyFailuresThatClearUpRetryByThemselves() {
    var (q, ids) = queue(2)
    q.fail(ids[0], badKey)
    q.fail(ids[1], offline)
    XCTAssertEqual(q.problem, .badKey)
    XCTAssertEqual(q.retry(all: false), [ids[1]])
    XCTAssertEqual(q.retry(all: true), ids)
  }

  /// Catches a held request not showing as offline.
  func testRequestHeldForTheNetworkIsOffline() {
    var (q, ids) = queue(1)
    q.waiting(ids[0])
    XCTAssertEqual(q.problem, .offline)
    q.connected()
    XCTAssertNil(q.problem)
  }

  /// Catches context leaking across runs or growing without bound: the prompt
  /// is this run's typed text, its last 200 characters.
  func testPromptIsTheRunsTypedTail() {
    var q = TranscriptQueue<String>()
    let first = q.reserve(run: 1, target: "t")
    q.setAudio(Data([1]), for: first)
    XCTAssertEqual(q.send(first)?.prompt, "")
    let long = String(repeating: "word ", count: 60) + "end."
    _ = q.complete(first, reply: long)
    let second = q.reserve(run: 1, target: "t")
    q.setAudio(Data([2]), for: second)
    let prompt = q.send(second)?.prompt ?? ""
    XCTAssertEqual(prompt.count, 200)
    XCTAssertTrue(prompt.hasSuffix("word end."))
    let other = q.reserve(run: 2, target: "t")
    q.setAudio(Data([3]), for: other)
    XCTAssertEqual(q.send(other)?.prompt, "")
  }

  /// Catches typing the prompt back (OpenAI's answer to near-silence) while keeping real short words.
  func testEchoOfThePromptIsNotTyped() {
    var (q, ids) = queue(3)
    XCTAssertEqual(q.complete(ids[0], reply: "Please check the config before deploying.").map(\.text),
                   ["Please check the config before deploying."])
    _ = q.send(ids[1])
    XCTAssertEqual(q.complete(ids[1], reply: "please check the config before deploying").map(\.text), [])
    _ = q.send(ids[2])
    XCTAssertEqual(q.complete(ids[2], reply: "Config.").map(\.text), ["Config."])
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

  /// Catches a discarded or closed tab's segment typing later or blocking others.
  func testDiscardAndGoneTargets() {
    var (q, ids) = queue(2)
    q.discard()
    XCTAssertEqual(q.complete(ids[0], reply: "late").map(\.text), [])
    XCTAssertTrue(q.isEmpty)
    var r = TranscriptQueue<String>()
    let a = r.reserve(run: 0, target: "closed"), b = r.reserve(run: 0, target: "open")
    r.setAudio(Data([0]), for: b)
    _ = r.send(b)
    XCTAssertEqual(r.complete(b, reply: "kept").map(\.text), [])
    XCTAssertEqual(r.remove { $0 == "closed" }.map(\.text), ["kept"])
    XCTAssertEqual(r.complete(a, reply: "gone").map(\.text), [])
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
    var typed: [String] = []
    var notices: [String] = []
    func typeDictation(_ text: String) { typed.append(text) }
    func dictationNotice(_ text: String) { notices.append(text) }
    func dictationNeedsSettings() {}
  }

  /// Answers with `reply(audio)` (the audio's bytes as text unless a test says
  /// otherwise) after `delay(text)`, or fails while `failure` is set.
  private final class Service: Transcriber, @unchecked Sendable {
    let lock = NSLock()
    private var _failure: TranscriptionFailure?
    private var _calls = 0
    var delay: @Sendable (String) -> Double = { _ in 0 }
    var reply: @Sendable (Data) -> String = { String(decoding: $0, as: UTF8.self) }
    var failure: TranscriptionFailure? {
      get { lock.withLock { _failure } }
      set { lock.withLock { _failure = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    func transcribe(_ audio: Data, prompt: String,
                    waiting: @escaping @Sendable () -> Void) async throws(TranscriptionFailure) -> String {
      let text = reply(audio)
      lock.withLock { _calls += 1 }
      try? await Task.sleep(for: .seconds(delay(text)))
      if let failure { throw failure }
      return text
    }
  }

  private func until(_ what: String, timeout: Double = 5, _ done: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(done(), what)
  }

  /// Catches replies typed in arrival order: "one" answers last but types first.
  func testSlowFirstSegmentStillTypesFirst() async {
    let service = Service()
    service.delay = { $0 == "one" ? 0.4 : 0 }
    let dictation = Dictation(transcriber: { service })
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
    let dictation = Dictation(transcriber: { service })
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
    let dictation = Dictation(transcriber: { service })
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
    let dictation = Dictation(transcriber: { service })
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
    let dictation = Dictation(transcriber: { service })
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
