import Foundation

/// Why queued speech is waiting.
enum VoiceProblem: Equatable, Sendable {
  /// The network is unreachable or dropped the request.
  case offline
  /// OpenRouter refused the key (401, 403).
  case badKey
  /// The account is out of credit (402).
  case noCredit
  /// No such model (404).
  case modelNotFound
  /// Anything else, in the service's words.
  case other(String)

  /// Fixed in Settings › Voice, so tapping the strip opens it rather than retrying.
  var needsSettings: Bool { self == .badKey || self == .noCredit || self == .modelNotFound }
}

/// Why a part did not come back as text.
struct TranscriptionFailure: Error, Equatable {
  var problem: VoiceProblem
  /// The network dropping, rate limits and upstream errors clear up by
  /// themselves: the part goes again without a tap. The rest wait for the user.
  var retriesByItself: Bool
}

/// Recordings in the order they were stopped, each sent as one or more
/// parts. Parts are transcribed two at a time; a recording's text is typed
/// once, joined in order, when all its parts are back and every earlier
/// recording's text is out, so replies that return out of order still type
/// in order. A failed part keeps its audio and its place until it succeeds
/// or is discarded; one that fails by itself goes again on its own schedule
/// (2 s, then 4, 8 … up to a minute), which no other part's answer moves.
struct TranscriptQueue<Target> {
  enum Status: Equatable {
    /// Waiting for its audio to be encoded and spooled.
    case encoding
    /// Spooled, waiting for a request slot.
    case ready
    case sending
    /// Sent while the network was unreachable; it goes when the network returns.
    case waiting
    case done(String)
    case failed(TranscriptionFailure)
  }

  struct Entry {
    let id: Int
    /// The recording the part is from.
    let recording: Int
    let target: Target
    /// What the transcriber is told the part is about (`DictationPrompt`).
    let prompt: String
    /// The m4a file the part is spooled to.
    var audio: URL?
    var status = Status.encoding
    /// Failures in a row that cleared up by themselves.
    var failures = 0
    /// When the latest such failure goes again.
    var retryAt: ContinuousClock.Instant?
  }

  /// A part to send now.
  struct Request {
    let id: Int
    let audio: URL
    let prompt: String
  }

  /// A recording's text, ready to type.
  struct Typed {
    let target: Target
    let text: String
  }

  /// Requests in flight at once; the rest wait their turn in order.
  static var slots: Int { 2 }

  private(set) var entries: [Entry] = []
  private var nextID = 0
  private var nextRecording = 0
  /// Spool files of parts no longer queued, for the owner to delete.
  private var released: [URL] = []

  var isEmpty: Bool { entries.isEmpty }
  /// Recordings not typed yet.
  var count: Int {
    var count = 0, last: Int?
    for entry in entries where entry.recording != last {
      count += 1
      last = entry.recording
    }
    return count
  }

  /// Why the queue is stuck, if it is: the first failed or offline part's problem.
  var problem: VoiceProblem? {
    for entry in entries {
      switch entry.status {
      case .waiting: return .offline
      case .failed(let failure): return failure.problem
      default: continue
      }
    }
    return nil
  }

  /// The earliest time a failed part goes again by itself.
  var nextRetry: ContinuousClock.Instant? {
    entries.lazy.filter { if case .failed = $0.status { true } else { false } }.compactMap(\.retryAt).min()
  }

  /// Holds a recording's place in order before its parts' audio is ready; returns the parts' ids.
  mutating func reserve(parts: Int, target: Target, prompt: String) -> [Int] {
    defer { nextRecording += 1 }
    return (0..<parts).map { _ in
      defer { nextID += 1 }
      entries.append(Entry(id: nextID, recording: nextRecording, target: target, prompt: prompt))
      return nextID
    }
  }

  /// The spooled audio: the part waits for a request slot.
  mutating func setAudio(_ audio: URL, for id: Int) {
    guard let i = index(id), entries[i].status == .encoding else {
      released.append(audio)
      return
    }
    entries[i].audio = audio
    entries[i].status = .ready
  }

  /// Marks parts sent, earliest first, while a slot is free; returns their requests.
  mutating func send() -> [Request] {
    var free = Self.slots - entries.count { $0.status == .sending || $0.status == .waiting }
    var requests: [Request] = []
    for i in entries.indices where free > 0 && entries[i].status == .ready {
      guard let audio = entries[i].audio else { continue }
      entries[i].status = .sending
      requests.append(Request(id: entries[i].id, audio: audio, prompt: entries[i].prompt))
      free -= 1
    }
    return requests
  }

  /// The request is held until the network returns.
  mutating func waiting(_ id: Int) {
    guard let i = index(id), entries[i].status == .sending else { return }
    entries[i].status = .waiting
  }

  /// The network is back: held requests are on their way.
  mutating func connected() {
    for i in entries.indices where entries[i].status == .waiting { entries[i].status = .sending }
  }

  /// A reply: returns every recording now ready to type, in order.
  mutating func complete(_ id: Int, reply: String) -> [Typed] {
    guard let i = index(id) else { return [] }
    let text = DictatedText.clean(reply)
    entries[i].status = .done(DictatedText.isOtherScript(text) ? "" : text)
    return popReady()
  }

  /// A failed request at `now`. One that clears up by itself goes again
  /// after 2 s, doubling with each failure in a row, up to a minute.
  mutating func fail(_ id: Int, _ failure: TranscriptionFailure, at now: ContinuousClock.Instant) {
    guard let i = index(id) else { return }
    entries[i].status = .failed(failure)
    guard failure.retriesByItself else {
      entries[i].retryAt = nil
      return
    }
    entries[i].failures += 1
    entries[i].retryAt = now + Self.retryDelay(after: entries[i].failures)
  }

  static func retryDelay(after failures: Int) -> Duration {
    min(.seconds(2) * (1 << min(max(failures - 1, 0), 5)), .seconds(60))
  }

  /// Failed parts go again, ignoring their schedule: only those that clear
  /// up by themselves, unless the user asked, whose retry also starts the schedule over.
  mutating func retry(all: Bool) {
    for i in entries.indices {
      guard case .failed(let failure) = entries[i].status, all || failure.retriesByItself else { continue }
      entries[i].status = .ready
      if all { entries[i].failures = 0 }
    }
  }

  /// Failed parts whose time to go again has come by `now`.
  mutating func retryDue(at now: ContinuousClock.Instant) {
    for i in entries.indices {
      guard case .failed = entries[i].status, let at = entries[i].retryAt, at <= now else { continue }
      entries[i].status = .ready
    }
  }

  /// Forgets every recording not typed yet; replies still on their way are ignored.
  mutating func discard() {
    released += entries.compactMap(\.audio)
    entries.removeAll()
  }

  /// Gives up one part (its audio could not be encoded); returns what can now be typed.
  mutating func drop(_ id: Int) -> [Typed] {
    guard let i = index(id) else { return [] }
    if let audio = entries[i].audio { released.append(audio) }
    entries.remove(at: i)
    return popReady()
  }

  /// Spool files no part needs any more; each is returned once.
  mutating func takeReleasedAudio() -> [URL] {
    defer { released = [] }
    return released
  }

  /// The first recordings whose parts are all back, as one text each.
  private mutating func popReady() -> [Typed] {
    var ready: [Typed] = []
    while let first = entries.first {
      let parts = entries.prefix { $0.recording == first.recording }
      var text = ""
      for part in parts {
        guard case .done(let said) = part.status else { return ready }
        if !said.isEmpty { text += DictatedText.typed(said, continuing: !text.isEmpty) }
      }
      released += parts.compactMap(\.audio)
      entries.removeFirst(parts.count)
      if !text.isEmpty { ready.append(Typed(target: first.target, text: text)) }
    }
    return ready
  }

  private func index(_ id: Int) -> Int? { entries.firstIndex { $0.id == id } }
}

/// How a transcript becomes typed text.
enum DictatedText {
  /// One line of printable text: control characters (an escape could end a
  /// bracketed paste early and run what follows) are dropped, and line
  /// breaks, tabs and runs of spaces become one space, so a transcript
  /// never presses Enter.
  static func clean(_ reply: String) -> String {
    var out = ""
    var space = false
    for scalar in reply.unicodeScalars {
      if scalar.properties.isWhitespace || scalar == "\u{2028}" || scalar == "\u{2029}" {
        space = !out.isEmpty
        continue
      }
      if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format { continue }
      if space { out.append(" ") }
      space = false
      out.unicodeScalars.append(scalar)
    }
    return out
  }

  /// With English fixed, a reply mostly in another script (Cyrillic,
  /// Japanese…) is the model making text up for noise, never what was said.
  static func isOtherScript(_ reply: String) -> Bool {
    let other = reply.matches(of: /[\p{L}--\p{Script=Latin}]/).count
    return other > reply.matches(of: /\p{Script=Latin}/).count
  }

  /// What goes after dictated text: a space first when it continues it,
  /// unless it opens with punctuation that closes onto the word before.
  static func typed(_ text: String, continuing: Bool) -> String {
    guard continuing, let first = text.first, !",.;:!?)]}%…".contains(first) else { return text }
    return " " + text
  }
}
