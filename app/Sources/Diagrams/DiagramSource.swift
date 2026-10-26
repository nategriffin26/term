import Foundation

/// The Mermaid sources a remote tmux session published for its drawings:
/// Term's omp extension keeps them in the pane option `@diagrams`
/// (`{"v":1,"d":[{"h":hash,"t":unix s,"src":source}]}`, newest last).
/// Fetched over SSH exec only while the screen shows a drawing no known
/// source matches, and kept by hash for the life of the connection.
@MainActor
final class DiagramSource {
  struct Entry: Equatable, Sendable {
    var hash: String
    var time: Double
    var source: String
  }

  /// Fetches that may miss one unmatched drawing: the first can race omp
  /// publishing it, and a drawing with no source (a table, tool output) must
  /// not fetch for as long as it stays on screen.
  static let triesPerDrawing = 3
  /// Least time between two fetches.
  let fetchInterval: Duration
  /// Sources kept, oldest dropped first.
  static let capacity = 64

  /// Runs a command on the host and returns its stdout, nil on failure.
  typealias Exec = @MainActor (String) async -> Data?

  private let exec: Exec
  let command: String
  private(set) var candidates: [DiagramMatcher.Candidate] = []
  private var entries: [String: Entry] = [:]
  /// Fetches started while each unmatched drawing (by its words) was on screen.
  private var tries: [String: Int] = [:]
  private var fetching = false
  private var lastFetch: ContinuousClock.Instant?
  private var retry: Task<Void, Never>?
  /// New sources arrived, or a fetch finished: match the screen again.
  var onChange: (() -> Void)?

  init(tmuxSession: String?, fetchInterval: Duration = .milliseconds(1500), exec: @escaping Exec) {
    self.exec = exec
    self.fetchInterval = fetchInterval
    command = Self.fetchCommand(tmuxSession: tmuxSession)
  }

  convenience init(host: Host, tmuxSession: String?) {
    self.init(tmuxSession: tmuxSession) { command in
      guard case .success(let out) = await RemoteExec.run(Tab.spec(for: host), command), out.status == 0 else { return nil }
      return out.stdout
    }
  }

  isolated deinit { retry?.cancel() }

  func source(_ hash: String) -> String? { entries[hash]?.source }

  /// Every pane of the session (all of tmux's when the session is unknown)
  /// that publishes diagrams: one JSON value per line.
  static func fetchCommand(tmuxSession: String?) -> String {
    let target = tmuxSession.map { "-s -t \(Command.shellQuote("=" + $0))" } ?? "-a"
    return "\(Tmux.path); tmux list-panes \(target) -f '#{@diagrams}' -F '#{@diagrams}' 2>/dev/null; exit 0"
  }

  static func parse(_ output: Data) -> [Entry] {
    String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).flatMap { line -> [Entry] in
      guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            value["v"] as? Int == 1, let list = value["d"] as? [[String: Any]] else { return [] }
      return list.compactMap { d in
        guard let hash = d["h"] as? String, let source = d["src"] as? String, !source.isEmpty else { return nil }
        return Entry(hash: hash, time: (d["t"] as? NSNumber)?.doubleValue ?? 0, source: source)
      }
    }
  }

  /// The screen shows drawings no source matches, each named by its words:
  /// fetch once more for those that have tries left.
  func unmatched(_ drawings: Set<String>) {
    let open = drawings.filter { tries[$0, default: 0] < Self.triesPerDrawing }
    guard !open.isEmpty, !fetching, retry == nil else { return }
    let clock = ContinuousClock()
    if let last = lastFetch, clock.now < last + fetchInterval {
      retry = Task { [weak self, fetchInterval] in
        try? await clock.sleep(until: last + fetchInterval)
        guard let self, !Task.isCancelled else { return }
        retry = nil
        onChange?()
      }
      return
    }
    if tries.count > 512 { tries.removeAll() }
    for d in open { tries[d, default: 0] += 1 }
    fetching = true
    lastFetch = clock.now
    Task {
      let output = await exec(command)
      fetching = false
      if let output { merge(Self.parse(output)) }
      onChange?()
    }
  }

  func merge(_ fetched: [Entry]) {
    var changed = false
    for e in fetched where entries[e.hash] == nil || entries[e.hash]!.time < e.time {
      entries[e.hash] = e
      changed = true
    }
    guard changed else { return }
    if entries.count > Self.capacity {
      for e in entries.values.sorted(by: { $0.time < $1.time }).prefix(entries.count - Self.capacity) {
        entries[e.hash] = nil
      }
    }
    candidates = entries.values.sorted { $0.time < $1.time }
      .map { DiagramMatcher.Candidate(hash: $0.hash, time: $0.time, source: $0.source) }
  }
}
