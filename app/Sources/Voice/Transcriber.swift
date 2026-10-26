import AVFoundation
import Foundation

/// Turns one spoken segment into text.
protocol Transcriber: Sendable {
  /// `audio` is an m4a file; `prompt` is what was typed just before it, for
  /// spelling and context. `waiting` runs if the request is held until the
  /// network returns.
  func transcribe(_ audio: URL, prompt: String,
                  waiting: @escaping @Sendable () -> Void) async throws(TranscriptionFailure) -> String
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

  func transcribe(_ audio: URL, prompt: String,
                  waiting: @escaping @Sendable () -> Void) async throws(TranscriptionFailure) -> String {
    guard let audio = try? Data(contentsOf: audio) else {
      throw TranscriptionFailure(problem: .other("The recording is gone"), retriesByItself: false)
    }
    let request = Self.request(audio: audio, prompt: prompt, model: model, key: key, baseURL: baseURL)
    let data: Data, response: URLResponse
    do {
      (data, response) = try await Self.session.data(for: request, delegate: WaitingDelegate(waiting: waiting))
    } catch let error as URLError {
      throw Self.failure(error)
    } catch {
      throw TranscriptionFailure(problem: .other(error.localizedDescription), retriesByItself: false)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return try Self.text(status: status, body: data)
  }

  /// The request: the audio as base64 m4a, English, and the prompt for
  /// OpenAI's models (OpenRouter ignores a top-level prompt; others ignore this).
  static func request(audio: Data, prompt: String, model: String, key: String, baseURL: URL) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: "audio/transcriptions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = [
      "model": model,
      "input_audio": ["data": audio.base64EncodedString(), "format": "m4a"],
      "language": "en",
    ]
    if !prompt.isEmpty { body["provider"] = ["options": ["openai": ["prompt": prompt]]] }
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
}

/// Speech as OpenRouter takes it: AAC in an m4a, 16 kHz mono, 32 kbps (about 4 KB a second).
enum SpeechAudio {
  static func m4a(_ samples: [Float]) throws -> Data {
    guard !samples.isEmpty else { throw CocoaError(.fileWriteUnknown) }
    let rate = Double(SpeechSegmenter.sampleRate)
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
  /// a short segment's audio), moving the sample offsets ('stco') back to match.
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
