import Foundation

/// The messages an omp agent published for the active pane of a tmux session
/// (Term's omp extension keeps them in the pane option `@messages`, and the
/// ids the user has read in `@read`; integrations/omp/term-agent.ts), and
/// where each one starts in the pane's history. Positions are found on the
/// host each refresh by searching the pane's history for each message's head
/// (only the matching lines come back), never stored: omp rewrites the whole
/// history on a resize and tmux drops its oldest lines at the limit.
@MainActor
final class MessageRail {
  struct Message: Equatable, Sendable {
    var id: String
    var time: Date
    /// How its first line starts on the terminal.
    var head: String
  }

  /// A message found in the history.
  struct Mark: Equatable, Sendable {
    var message: Message
    /// Its first line's number in the pane's history and screen, 1 = the oldest line.
    var line: Int
    /// That line from the head on, as the terminal shows it.
    var text: String
  }

  /// The pane the rail maps, as the last refresh read it.
  struct Pane: Equatable, Sendable {
    var id: String
    var historySize: Int
    var height: Int
    /// Rows of the client above the pane: tmux's status line on top, and the pane's top in its window.
    var top: Int
    var inCopyMode: Bool
    /// Lines the copy mode view is scrolled up from the bottom.
    var scrollPosition: Int

    /// Lines the rail maps: the history and the screen.
    var lines: Int { historySize + height }
  }

  /// Runs a command on the host and returns its stdout, nil on failure.
  typealias Exec = @MainActor (String) async -> Data?

  let tmuxSession: String
  private let exec: Exec
  private(set) var pane: Pane?
  /// Newest last, as published.
  private(set) var messages: [Message] = []
  /// Oldest first.
  private(set) var marks: [Mark] = []
  /// Ids the host's `@read` holds, and those read here since it was last read.
  private var hostRead: Set<String> = []
  private var readHere: Set<String> = []
  /// The agent stopped for the user: its newest message is the one it waits on.
  private(set) var agentStopped = false
  private var agentMessages: Int?
  /// The terminal shows this rail: only then does a new message refresh it.
  var isShown = false
  /// Marks, read state or the pane changed.
  var onChange: (() -> Void)?

  /// Least time between refreshes the agent poll asks for; one asked for
  /// sooner runs when it has passed.
  static let refreshInterval: TimeInterval = 3
  private var refreshing = false
  private var refreshAgain = false
  private var lastRefresh: Date?
  private var pending: Task<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  /// When each unread message's head was first seen on screen in the current run of sightings.
  private var sightings: [String: Date] = [:]
  /// The device log line last written, so an unchanged refresh writes none.
  private var logged = ""

  init(tmuxSession: String, exec: @escaping Exec) {
    self.tmuxSession = tmuxSession
    self.exec = exec
  }

  convenience init(host: Host, tmuxSession: String) {
    self.init(tmuxSession: tmuxSession) { command in
      guard case .success(let out) = await RemoteExec.run(Tab.spec(for: host), command), out.status == 0 else { return nil }
      return out.stdout
    }
    observeAgent(host: host)
  }

  isolated deinit { pending?.cancel() }

  func isRead(_ id: String) -> Bool { hostRead.contains(id) || readHere.contains(id) }

  /// Messages not yet read, located or not.
  var unread: [Message] { messages.filter { !isRead($0.id) } }

  // MARK: - Refresh

  /// Reads the pane and finds its messages again: `force` at once (one
  /// running is followed by another), else at most once per `refreshInterval`.
  func refresh(force: Bool = false) {
    if refreshing {
      refreshAgain = true
      return
    }
    if !force, let lastRefresh {
      let wait = Self.refreshInterval - Date.now.timeIntervalSince(lastRefresh)
      if wait > 0 {
        guard pending == nil else { return }
        pending = Task { [weak self] in
          try? await Task.sleep(for: .seconds(wait))
          guard let self, !Task.isCancelled else { return }
          pending = nil
          refresh()
        }
        return
      }
    }
    pending?.cancel()
    pending = nil
    refreshing = true
    Task { await run() }
  }

  /// Returns once a refresh started from now on has finished.
  func refreshed() async {
    refresh(force: true)
    await withCheckedContinuation { waiters.append($0) }
  }

  private func run() async {
    lastRefresh = .now
    // The heads already known go with the read; new ones need a second pass.
    var heads = Set(messages.map(\.head))
    var result: Refresh?
    for _ in 0..<2 {
      guard let output = await exec(Self.refreshCommand(tmuxSession: tmuxSession, heads: heads.sorted())) else { break }
      let read = Self.parseRefresh(output)
      result = read
      let fresh = Set(read.messages.map(\.head))
      if fresh.isSubset(of: heads) { break }
      heads = fresh
    }
    if let result { apply(result) }
    if refreshAgain {
      refreshAgain = false
      await run()
      return
    }
    refreshing = false
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  private func apply(_ read: Refresh) {
    pane = read.pane
    messages = read.messages
    hostRead = read.read
    readHere.subtract(hostRead)
    marks = read.pane == nil ? [] : Self.locate(read.messages, in: read.lines)
    logLocated()
    onChange?()
  }

  /// One device log line whenever what the rail found changes.
  private func logLocated() {
    let located = Set(marks.map(\.message.id))
    let missing = messages.filter { !located.contains($0.id) }
    let line = "messages=\(messages.count) located=\(located.count) unlocated=\(missing.count)"
      + " unlocated_unread=\(missing.count { !isRead($0.id) })"
    guard line != logged else { return }
    logged = line
    DiagnosticLog.record(.rail, "located", "tmux=\(DiagnosticLog.name(tmuxSession)) " + line)
  }

  // MARK: - Agent

  /// The agent poll's view of this session: a new message, or a change of
  /// state, refreshes a rail on screen.
  func agentChanged(messages count: Int?, stopped: Bool) {
    let stoppedChanged = stopped != agentStopped
    agentStopped = stopped
    let newMessages = count != agentMessages
    agentMessages = count
    if stoppedChanged { onChange?() }
    if newMessages || stoppedChanged, isShown { refresh() }
  }

  private func observeAgent(host: Host) {
    let read = { [tmuxSession] in TmuxStore.shared.agent(on: host, session: tmuxSession) }
    let agent = withObservationTracking(read) { [weak self] in
      Task { @MainActor in self?.observeAgent(host: host) }
    }
    agentChanged(messages: agent?.messages, stopped: agent?.state.isStop == true)
  }

  // MARK: - Reading

  /// The pane rows the terminal shows now, as text: a head seen there for a
  /// second makes its message read. Returns the ids read by this sighting.
  @discardableResult
  func saw(_ screen: String, at now: Date = .now) -> [String] {
    var done: [String] = []
    var seen: Set<String> = []
    for message in unread where screen.contains(message.head) {
      seen.insert(message.id)
      let first = sightings[message.id] ?? now
      sightings[message.id] = first
      if now.timeIntervalSince(first) >= Self.viewedAfter { done.append(message.id) }
    }
    sightings = sightings.filter { seen.contains($0.key) }
    markRead(done)
    return done
  }

  /// How long a message's first line stays on screen before it counts as read.
  static let viewedAfter: TimeInterval = 1

  /// Read here and on the host, for every device.
  func markRead(_ ids: [String]) {
    let ids = ids.filter { !isRead($0) }
    guard !ids.isEmpty, let pane else { return }
    readHere.formUnion(ids)
    for id in ids { sightings[id] = nil }
    onChange?()
    let command = Self.readCommand(pane: pane.id, ids: ids)
    Task { _ = await exec(command) }
  }

  // MARK: - Jumping

  /// Where a jump left the pane: the row (0 = the pane's top) its message starts on.
  enum Jump: Equatable {
    case shown(row: Int)
    /// The message is no longer in the history.
    case gone
    case failed
  }

  /// Scrolls the pane (tmux copy mode) so the message's first line is on its
  /// second row, or to the bottom when it is already on the screen there.
  /// A history that moved since the refresh is read again first.
  func jump(to id: String) async -> Jump {
    markRead([id])
    for attempt in 0..<2 {
      if attempt == 1 { await refreshed() }
      guard let pane, let mark = marks.first(where: { $0.message.id == id }) else { return .gone }
      guard let output = await exec(Self.jumpCommand(pane: pane.id, line: mark.line, head: mark.message.head)) else { return .failed }
      switch Self.parseJump(output, line: mark.line) {
      case .shown(let row, let position):
        self.pane?.inCopyMode = position > 0
        self.pane?.scrollPosition = position
        onChange?()
        return .shown(row: row)
      case .stale: continue
      case nil: return .failed
      }
    }
    return .gone
  }

  /// Leaves copy mode: the pane follows its output again.
  func backToLive() {
    guard let pane else { return }
    self.pane?.inCopyMode = false
    self.pane?.scrollPosition = 0
    onChange?()
    let command = Self.liveCommand(pane: pane.id)
    Task { _ = await exec(command) }
  }

  /// Reads where the copy mode view is after the user scrolled (once the
  /// wheel events, which travel on the terminal's own connection, have arrived).
  func followViewport() {
    guard let pane else { return }
    let command = Self.viewportCommand(pane: pane.id)
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      guard let output = await exec(command), let viewport = Self.parseViewport(output),
            self.pane?.id == pane.id else { return }
      self.pane?.historySize = viewport.historySize
      self.pane?.inCopyMode = viewport.inCopyMode
      self.pane?.scrollPosition = viewport.scrollPosition
      onChange?()
    }
  }
}

// MARK: - Commands and parsing

extension MessageRail {
  /// Starts each section of a refresh's output: ASCII record separator.
  static let sectionMark = "\u{1E}"

  /// pane fields, tab-separated.
  static let paneFormat = "#{pane_id}\t#{history_size}\t#{pane_height}\t#{pane_top}"
    + "\t#{?#{==:#{status-position},top},#{status},off}\t#{pane_in_mode}\t#{scroll_position}"

  /// Ends the heads in a refresh's script.
  static let headsEnd = "TERM_RAIL_HEADS"

  /// One exec: the session's active pane, its `@messages` and `@read`, then
  /// the lines of its history and screen holding any of `heads` (numbered,
  /// cut to 400 characters). A session that has ended prints nothing.
  static func refreshCommand(tmuxSession: String, heads: [String]) -> String {
    var lines = [
      Tmux.path,
      "t=$(tmux display-message -p -t \(Command.shellQuote("=" + tmuxSession + ":")) '#{pane_id}' 2>/dev/null)",
      #"[ -n "$t" ] || exit 0"#,
      #"tmux display-message -p -t "$t" '\#(paneFormat)'"#,
      #"printf '\036\n'; tmux show-options -pqv -t "$t" @messages"#,
      #"printf '\036\n'; tmux show-options -pqv -t "$t" @read"#,
      #"printf '\036\n'"#,
    ]
    // A head can never be a line of its own end mark, nor an empty pattern (which grep matches everywhere).
    let patterns = heads.filter { !$0.isEmpty && !$0.contains("\n") && $0 != headsEnd }
    if !patterns.isEmpty {
      lines.append(#"f=$(mktemp) || exit 0"#)
      lines.append("cat > \"$f\" <<'\(headsEnd)'\n" + patterns.joined(separator: "\n") + "\n\(headsEnd)")
      lines.append(#"tmux capture-pane -p -S - -E - -t "$t" | grep -n -F -f "$f" | cut -c1-400; rm -f "$f""#)
    }
    lines.append("exit 0")
    return lines.joined(separator: "\n")
  }

  struct Refresh: Equatable {
    var pane: Pane?
    var messages: [Message] = []
    var read: Set<String> = []
    /// Numbered lines holding a head, in order.
    var lines: [(number: Int, text: String)] = []

    static func == (a: Refresh, b: Refresh) -> Bool {
      a.pane == b.pane && a.messages == b.messages && a.read == b.read
        && a.lines.map(\.number) == b.lines.map(\.number) && a.lines.map(\.text) == b.lines.map(\.text)
    }
  }

  static func parseRefresh(_ output: Data) -> Refresh {
    let sections = String(decoding: output, as: UTF8.self).components(separatedBy: sectionMark + "\n")
    guard sections.count >= 4, let pane = parsePane(sections[0]) else { return Refresh() }
    let lines = sections[3].split(whereSeparator: \.isNewline).compactMap { line -> (number: Int, text: String)? in
      guard let colon = line.firstIndex(of: ":"), let number = Int(line[..<colon]) else { return nil }
      return (number, String(line[line.index(after: colon)...]))
    }
    return Refresh(pane: pane, messages: parseMessages(sections[1]),
                   read: Set(sections[2].split(whereSeparator: \.isWhitespace).map(String.init)), lines: lines)
  }

  private static func parsePane(_ text: String) -> Pane? {
    let f = text.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 6, f[0].hasPrefix("%"), let history = Int(f[1]), let height = Int(f[2]), let top = Int(f[3]) else { return nil }
    let status = f[4] == "on" ? 1 : Int(f[4]) ?? 0
    return Pane(id: f[0], historySize: history, height: height, top: status + top, inCopyMode: f[5] == "1",
                scrollPosition: f.count > 6 ? Int(f[6]) ?? 0 : 0)
  }

  /// `@messages` as published (`{"v":1,"m":[{"i","t","h"}]}`); entries missing a field are dropped.
  static func parseMessages(_ text: String) -> [Message] {
    guard let value = try? JSONSerialization.jsonObject(with: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any],
          value["v"] as? Int == 1, let list = value["m"] as? [[String: Any]] else { return [] }
    return list.compactMap { m in
      guard let id = m["i"] as? String, !id.isEmpty, let head = m["h"] as? String, !head.isEmpty,
            let time = (m["t"] as? NSNumber)?.doubleValue else { return nil }
      return Message(id: id, time: Date(timeIntervalSince1970: time), head: head)
    }
  }

  /// Each message at the line it starts on: the newest takes the last line
  /// holding its head, each older one the last such line above the newer
  /// one's. A head repeated later (an older message quoted, the same words
  /// again) so never pulls an older message below a newer one.
  static func locate(_ messages: [Message], in lines: [(number: Int, text: String)]) -> [Mark] {
    var below = Int.max
    var marks: [Mark] = []
    for message in messages.reversed() {
      guard let hit = lines.last(where: { $0.number < below && $0.text.contains(message.head) }),
            let start = hit.text.range(of: message.head) else { continue }
      below = hit.number
      marks.append(Mark(message: message, line: hit.number, text: shownLine(hit.text[start.lowerBound...])))
    }
    return marks.reversed()
  }

  /// A line from its head on, without the border of a box omp drew around it.
  private static func shownLine(_ text: Substring) -> String {
    var text = text.trimmingCharacters(in: .whitespaces)
    while let last = text.last, last == "│" || last == "┃" || last.isWhitespace { text.removeLast() }
    return text
  }

  /// Checks the line still holds the head (else prints `stale`), then puts
  /// it on the pane's second row in copy mode, or leaves copy mode when the
  /// screen already shows it there; prints `jumped HISTORY POSITION`.
  static func jumpCommand(pane: String, line: Int, head: String) -> String {
    [
      Tmux.path,
      "t=\(Command.shellQuote(pane)); h=\(Command.shellQuote(head)); l=\(line)",
      #"hs=$(tmux display-message -p -t "$t" '#{history_size}') || exit 0"#,
      #"r=$((l - 1 - hs))"#,
      #"case "$(tmux capture-pane -p -t "$t" -S "$r" -E "$r" 2>/dev/null)" in *"$h"*) ;; *) echo stale; exit 0;; esac"#,
      #"n=$((hs - l + 2)); [ "$n" -gt "$hs" ] && n=$hs"#,
      #"if [ "$n" -ge 1 ]; then tmux copy-mode -e -t "$t" \; send-keys -X -t "$t" goto-line "$n"; else n=0; tmux if-shell -F -t "$t" '#{pane_in_mode}' "send-keys -X -t $t cancel"; fi"#,
      #"echo "jumped $hs $n""#,
    ].joined(separator: "\n")
  }

  enum JumpOutput: Equatable {
    /// The row of the pane the line is on now, and the copy mode position (0: live).
    case shown(row: Int, position: Int)
    case stale
  }

  static func parseJump(_ output: Data, line: Int) -> JumpOutput? {
    let words = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace)
    if words.first == "stale" { return .stale }
    guard words.count == 3, words[0] == "jumped", let history = Int(words[1]), let position = Int(words[2]) else { return nil }
    // The view's top line is `history - position` (0-based, the oldest line 0).
    return .shown(row: line - 1 - (history - position), position: position)
  }

  static func liveCommand(pane: String) -> String {
    "\(Tmux.path); tmux if-shell -F -t \(Command.shellQuote(pane)) '#{pane_in_mode}' \(Command.shellQuote("send-keys -X -t \(pane) cancel"))"
  }

  /// Appends ids to the pane's `@read` (tmux expands the old value itself, so
  /// another writer's append is never lost).
  static func readCommand(pane: String, ids: [String]) -> String {
    ([Tmux.path] + ids.map { id in
      "tmux set-option -p -F -t \(Command.shellQuote(pane)) @read \(Command.shellQuote("#{@read} " + id))"
    }).joined(separator: "; ")
  }

  static func viewportCommand(pane: String) -> String {
    "\(Tmux.path); tmux display-message -p -t \(Command.shellQuote(pane)) '#{history_size}\t#{pane_in_mode}\t#{scroll_position}'"
  }

  static func parseViewport(_ output: Data) -> (historySize: Int, inCopyMode: Bool, scrollPosition: Int)? {
    let f = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
      .split(separator: "\t", omittingEmptySubsequences: false)
    guard f.count >= 2, let history = Int(f[0]) else { return nil }
    return (history, f[1] == "1", f.count > 2 ? Int(f[2]) ?? 0 : 0)
  }
}
