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

/// Why a segment did not come back as text.
struct TranscriptionFailure: Error, Equatable {
  var problem: VoiceProblem
  /// The network dropping, rate limits and upstream errors clear up by
  /// themselves: the segment goes again without a tap. The rest wait for the user.
  var retriesByItself: Bool
}

/// Dictated segments in spoken order. Each is transcribed on its own, at
/// once, and its text is typed only after every earlier segment's, so
/// replies that return out of order still type in order. A failed segment
/// keeps its audio and its place until it succeeds or is discarded.
struct TranscriptQueue<Target> {
  enum Status: Equatable {
    /// Waiting for its audio to be encoded.
    case encoding
    case sending
    /// Sent while the network was unreachable; it goes when the network returns.
    case waiting
    case done(String)
    case failed(TranscriptionFailure)
  }

  struct Entry {
    let id: Int
    /// One listening session: context carries over within it, not across.
    let run: Int
    let target: Target
    var audio: Data?
    var status = Status.encoding
    /// The prompt sent with the latest request, to recognise a reply that only echoes it.
    var prompt = ""
  }

  /// A transcript ready to type, in spoken order.
  struct Typed {
    let target: Target
    let text: String
  }

  private(set) var entries: [Entry] = []
  private var nextID = 0
  /// What each run has typed so far, the tail of it.
  private var typedByRun: [Int: String] = [:]

  /// The context sent with a request: the run's last 200 typed characters.
  static var contextLength: Int { 200 }

  var isEmpty: Bool { entries.isEmpty }
  /// Segments not typed yet.
  var count: Int { entries.count }

  /// Why the queue is stuck, if it is: the first failed or offline segment's problem.
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

  /// Holds a segment's place in spoken order before its audio is ready.
  mutating func reserve(run: Int, target: Target) -> Int {
    defer { nextID += 1 }
    entries.append(Entry(id: nextID, run: run, target: target))
    return nextID
  }

  /// The encoded audio; the segment is then sent.
  mutating func setAudio(_ audio: Data, for id: Int) {
    guard let i = index(id) else { return }
    entries[i].audio = audio
  }

  /// Marks the segment sent and returns its audio and the prompt to send with it.
  mutating func send(_ id: Int) -> (audio: Data, prompt: String)? {
    guard let i = index(id), let audio = entries[i].audio else { return nil }
    let prompt = String((typedByRun[entries[i].run] ?? "").suffix(Self.contextLength))
    entries[i].status = .sending
    entries[i].prompt = prompt
    return (audio, prompt)
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

  /// A reply: returns everything now ready to type, in order.
  mutating func complete(_ id: Int, reply: String) -> [Typed] {
    guard let i = index(id) else { return [] }
    let text = DictatedText.clean(reply)
    let madeUp = DictatedText.isEcho(text, of: entries[i].prompt) || DictatedText.isOtherScript(text)
    entries[i].status = .done(madeUp ? "" : text)
    return popReady()
  }

  mutating func fail(_ id: Int, _ failure: TranscriptionFailure) {
    guard let i = index(id) else { return }
    entries[i].status = .failed(failure)
  }

  /// Failed segments to send again: only those that clear up by themselves,
  /// unless the user asked. Returns their ids, in order.
  mutating func retry(all: Bool) -> [Int] {
    entries.compactMap { entry in
      guard case .failed(let failure) = entry.status, all || failure.retriesByItself else { return nil }
      return entry.id
    }
  }

  /// Forgets every segment not typed yet; replies still on their way are ignored.
  mutating func discard() {
    entries.removeAll()
  }

  /// Drops segments whose target is gone (its tab closed); returns what can now be typed.
  mutating func remove(where gone: (Target) -> Bool) -> [Typed] {
    entries.removeAll { gone($0.target) }
    return popReady()
  }

  /// Gives up one segment (its audio could not be encoded); returns what can now be typed.
  mutating func drop(_ id: Int) -> [Typed] {
    entries.removeAll { $0.id == id }
    return popReady()
  }

  private mutating func popReady() -> [Typed] {
    var ready: [Typed] = []
    while let first = entries.first, case .done(let text) = first.status {
      entries.removeFirst()
      guard !text.isEmpty else { continue }
      let before = typedByRun[first.run].map { $0 + " " } ?? ""
      typedByRun[first.run] = String((before + text).suffix(Self.contextLength))
      ready.append(Typed(target: first.target, text: text))
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

  /// OpenAI's models answer near-silence with their prompt; a reply that is
  /// most of the prompt again is that, not speech.
  static func isEcho(_ reply: String, of prompt: String) -> Bool {
    let said = comparable(reply), context = comparable(prompt)
    guard !said.isEmpty, !context.isEmpty else { return false }
    return context.contains(said) && said.count * 10 >= context.count * 4
  }

  /// With English fixed, a reply mostly in another script (Cyrillic,
  /// Japanese…) is the model making text up for noise, never what was said.
  static func isOtherScript(_ reply: String) -> Bool {
    let other = reply.matches(of: /[\p{L}--\p{Script=Latin}]/).count
    return other > reply.matches(of: /\p{Script=Latin}/).count
  }

  /// What goes to the terminal: a space first when it continues dictated
  /// text, unless it opens with punctuation that closes onto the word before.
  static func typed(_ text: String, continuing: Bool) -> String {
    guard continuing, let first = text.first, !",.;:!?)]}%…".contains(first) else { return text }
    return " " + text
  }

  private static func comparable(_ text: String) -> String {
    text.lowercased().unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
      .map(String.init).joined()
      .split(separator: " ").joined(separator: " ")
  }
}
