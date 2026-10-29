import AVFoundation
import Foundation
import Synchronization

/// Turns one part of a recording into text.
protocol Transcriber: Sendable {
  /// Opens the connection the next request will use, without waiting for
  /// it: called as listening starts, so the request after the stop finds it open.
  func prewarm()
  /// `audio` is an m4a file; `words` are the words to get right. `waiting`
  /// runs if the request is held until the network returns.
  func transcribe(_ audio: URL, words: [String],
                  waiting: @escaping @Sendable () -> Void) async throws(TranscriptionFailure) -> Transcript
}

/// A part's text, and what the device log says of its request (never the text).
struct Transcript: Sendable, Equatable {
  let text: String
  let model: String
  /// The audio sent, before base64.
  let bytes: Int
  /// From sending the request to the whole reply.
  let milliseconds: Int
  let status: Int
  /// The provider that served it, when OpenRouter names one (`X-Provider-Name`).
  let provider: String?
}

/// A model Settings › Voice offers, with where its request carries the
/// words to get right. OpenRouter ignores a list sent top-level and passes
/// on only the serving provider's `provider.options` (measured 2026-10-28,
/// local research bench: each field below recalled more listed words, with
/// no false insertions).
struct VoiceModel: Identifiable, Sendable {
  let id: String
  let name: String
  /// US dollars per hour of audio, as the bench was billed.
  let dollarsPerHour: Double
  let words: WordsField

  enum WordsField: Sendable {
    case openAIKeywords, assemblyAIKeyterms, elevenLabsKeyterms
  }

  /// Most accurate on terminal dictation with the words (0.39% WER, every listed word right).
  static let recommended = menu[0]

  static let menu = [
    VoiceModel(id: "openai/gpt-transcribe", name: "GPT Transcribe", dollarsPerHour: 0.28, words: .openAIKeywords),
    VoiceModel(id: "assemblyai/universal-3-6-pro", name: "Universal-3.6 Pro", dollarsPerHour: 0.30,
               words: .assemblyAIKeyterms),
    VoiceModel(id: "elevenlabs/scribe-v2", name: "Scribe v2", dollarsPerHour: 0.22, words: .elevenLabsKeyterms),
  ]

  static func named(_ id: String) -> VoiceModel? {
    menu.first { $0.id == id }
  }

  /// Whisper, the GPT-4o family and MAI-Transcribe 2: a stored one moves to
  /// `recommended` at launch. Whisper dropped words from long recordings,
  /// GPT-4o writes foreign text for silence, and MAI refuses m4a.
  static func isRetired(_ id: String) -> Bool {
    id.hasPrefix("openai/whisper-") || id.hasPrefix("openai/gpt-4o") || id == "microsoft/mai-transcribe-2"
  }

  /// `provider.options` carrying `words` in this model's field.
  func options(_ words: [String]) -> [String: Any] {
    switch self.words {
    case .openAIKeywords: ["openai": ["keywords": words]]
    case .assemblyAIKeyterms: ["assemblyai": ["keyterms_prompt": words]]
    case .elevenLabsKeyterms: ["elevenlabs": ["keyterms": words]]
    }
  }
}

/// OpenRouter's speech-to-text endpoint (POST /audio/transcriptions, JSON).
struct OpenRouterTranscriber: Transcriber {
  static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!

  let key: String
  let model: String
  var baseURL = defaultBaseURL

  /// Long waits rather than lost speech: a request waits for the network
  /// (up to a day) instead of failing, and only 5 minutes without a byte
  /// from the server ends it.
  static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 300
    config.timeoutIntervalForResource = 24 * 60 * 60
    return URLSession(configuration: config)
  }()

  /// A pre-warm is out on `session`: at most one at a time, so starts and
  /// stops against a stalled endpoint never pile requests up.
  private static let prewarming = Atomic<Bool>(false)

  /// A tiny authenticated request (the key's own record) on the session the
  /// transcription uses, so DNS, TCP and TLS are done by the stop. It gives
  /// up after 5 s without a byte, and without a network it is dropped
  /// rather than waiting for one.
  func prewarm() {
    guard Self.prewarming.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
      return
    }
    var request = URLRequest(url: baseURL.appending(path: "key"))
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let task = Self.session.dataTask(with: request) { _, _, _ in
      Self.prewarming.store(false, ordering: .releasing)
    }
    task.delegate = PrewarmDelegate()
    task.resume()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { task.cancel() }
  }

  func transcribe(_ audio: URL, words: [String],
                  waiting: @escaping @Sendable () -> Void) async throws(TranscriptionFailure) -> Transcript {
    guard let sent = try? Data(contentsOf: audio) else {
      throw TranscriptionFailure(problem: .other("The recording is gone"), retriesByItself: false)
    }
    let request = Self.request(audio: sent, words: words, model: model, key: key, baseURL: baseURL)
    let start = ContinuousClock.now
    let data: Data, response: URLResponse
    do {
      (data, response) = try await Self.session.data(for: request, delegate: WaitingDelegate(waiting: waiting))
    } catch let error as URLError {
      throw Self.failure(error)
    } catch {
      throw TranscriptionFailure(problem: .other(error.localizedDescription), retriesByItself: false)
    }
    let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    return Transcript(text: try Self.text(status: status, body: data), model: model, bytes: sent.count,
                      milliseconds: milliseconds, status: status, provider: http?.value(forHTTPHeaderField: "X-Provider-Name"))
  }

  /// The request: the audio as base64 m4a, English, and the words in the
  /// model's own field (`VoiceModel.options`); a model off the menu gets none.
  static func request(audio: Data, words: [String], model: String, key: String, baseURL: URL) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: "audio/transcriptions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = [
      "model": model,
      "input_audio": ["data": audio.base64EncodedString(), "format": "m4a"],
      "language": "en",
    ]
    if !words.isEmpty, let options = VoiceModel.named(model)?.options(words) {
      body["provider"] = ["options": options]
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return request
  }

  /// The reply's text, or why there is none.
  static func text(status: Int, body: Data) throws(TranscriptionFailure) -> String {
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    if status == 200, let text = json?["text"] as? String { return text }
    let error = json?["error"] as? [String: Any]
    let message = (error?["message"] as? String) ?? (status == 200 ? "Unexpected reply" : "HTTP \(status)")
    switch status {
    case 401, 403: throw TranscriptionFailure(problem: .badKey, retriesByItself: false)
    case 402: throw TranscriptionFailure(problem: .noCredit, retriesByItself: false)
    case 404: throw TranscriptionFailure(problem: .modelNotFound, retriesByItself: false)
    case 200, 408, 429, 500...599: throw TranscriptionFailure(problem: .other(message), retriesByItself: true)
    default: throw TranscriptionFailure(problem: .other(message), retriesByItself: false)
    }
  }

  static func failure(_ error: URLError) -> TranscriptionFailure {
    let offline: Set<URLError.Code> = [
      .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
      .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
      .secureConnectionFailed, .cannotLoadFromNetwork,
    ]
    guard offline.contains(error.code) else {
      return TranscriptionFailure(problem: .other(error.localizedDescription), retriesByItself: false)
    }
    return TranscriptionFailure(problem: .offline, retriesByItself: true)
  }

  private final class WaitingDelegate: NSObject, URLSessionTaskDelegate {
    let waiting: @Sendable () -> Void
    init(waiting: @escaping @Sendable () -> Void) { self.waiting = waiting }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { waiting() }
  }

  private final class PrewarmDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { task.cancel() }
  }
}

/// The words to get right as both requests carry them.
enum DictationWords {
  /// 400 characters joined with ", " (about 50 short terms): the bench's list
  /// was 32 terms in 323 characters, with no listed word written where a
  /// sound-alike was said on any model. Longer lists are unmeasured.
  static let length = 400

  /// Whether `words` fit, joined with ", ".
  static func fit(_ words: [String]) -> Bool {
    words.joined(separator: ", ").count <= length
  }

  /// The first of `words` that fit, whole and in order.
  static func bounded(_ words: [String]) -> [String] {
    var kept: [String] = []
    for word in words where fit(kept + [word]) { kept.append(word) }
    return kept
  }

  /// `words` with `word` (trimmed) at the end, unchanged for an empty or
  /// listed word; nil when it does not fit.
  static func adding(_ word: String, to words: [String]) -> [String]? {
    let new = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !new.isEmpty, !words.contains(new) else { return words }
    return fit(words + [new]) ? words + [new] : nil
  }
}

/// Speech as OpenRouter takes it: AAC in an m4a, 16 kHz mono, 32 kbps (about 4 KB a second).
enum SpeechAudio {
  static func m4a(_ samples: ArraySlice<Float>) throws -> Data {
    guard !samples.isEmpty else { throw CocoaError(.fileWriteUnknown) }
    let rate = Double(Recording.sampleRate)
    let url = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
    ]
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
      throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    file.close()
    return compact(try Data(contentsOf: url))
  }

  /// Drops the ~24 KB 'free' atom AVAudioFile pads an m4a with (more than
  /// a short part's audio), moving the sample offsets ('stco') back to match.
  static func compact(_ m4a: Data) -> Data {
    var bytes = [UInt8](m4a)
    func u32(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    func atoms(in range: Range<Int>) -> [(type: String, range: Range<Int>)] {
      var out: [(String, Range<Int>)] = [], i = range.lowerBound
      while i + 8 <= range.upperBound {
        let size = u32(i)
        guard size >= 8, i + size <= range.upperBound else { return out }
        out.append((String(decoding: bytes[i + 4..<i + 8], as: UTF8.self), i..<i + size))
        i += size
      }
      return out
    }
    let top = atoms(in: 0..<bytes.count)
    guard let free = top.first(where: { $0.type == "free" }), let mdat = top.first(where: { $0.type == "mdat" }),
          free.range.upperBound <= mdat.range.lowerBound else { return m4a }
    let shift = free.range.count
    func adjust(_ range: Range<Int>) {
      for atom in atoms(in: range) {
        switch atom.type {
        case "moov", "trak", "mdia", "minf", "stbl": adjust(atom.range.lowerBound + 8..<atom.range.upperBound)
        case "stco":
          let count = u32(atom.range.lowerBound + 12)
          for k in 0..<count {
            let at = atom.range.lowerBound + 16 + 4 * k
            guard at + 4 <= atom.range.upperBound else { return }
            let moved = u32(at) - shift
            for b in 0..<4 { bytes[at + b] = UInt8((moved >> (24 - 8 * b)) & 0xFF) }
          }
        default: break
        }
      }
    }
    adjust(0..<free.range.lowerBound)
    bytes.removeSubrange(free.range)
    return Data(bytes)
  }
}
