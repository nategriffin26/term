import Foundation

/// What an omp agent in a tmux session is doing, and whether it stopped for
/// him. Its pane publishes it as the pane option `@agent` (Term's omp
/// extension, integrations/omp/term-agent.ts); without the extension, omp's
/// terminal title still says working, asks you or idle.
struct AgentInfo: Equatable, Sendable {
  enum State: String, Sendable {
    case working, ask, approval, done, error, aborted, idle
    /// Mid-turn when it last wrote, and omp is gone from its pane (a crash).
    case exited

    /// It stopped for him: notifies until he has seen it.
    var isStop: Bool {
      switch self {
      case .ask, .approval, .done, .error, .aborted, .exited: true
      case .working, .idle: false
      }
    }

    /// How much it needs him, when a session runs several agents.
    fileprivate var rank: Int {
      switch self {
      case .ask: 7
      case .approval: 6
      case .error: 5
      case .exited: 4
      case .aborted: 3
      case .done: 2
      case .working: 1
      case .idle: 0
      }
    }
  }

  struct Todo: Equatable, Sendable {
    var done: Int
    var total: Int
    /// The task in progress.
    var current: String?
  }

  /// tmux's name for the session it runs in.
  var session: String
  var state: State
  /// When this state began.
  var since: Date?
  var title: String?
  /// The step it is on while working.
  var doing: String?
  var todo: Todo?
  /// The question it asks, or the tool waiting for approval.
  var question: String?
  /// The question's choices.
  var options: [String] = []
  /// The final answer of its last turn, cut short.
  var answer: String?
  /// How long its last turn ran.
  var took: TimeInterval?
  var model: String?
  var thinking: String?
  /// Percent of the context window in use.
  var context: Int?
  /// Dollars spent, subagents included.
  var cost: Double?
  var subagents = 0
  var path: String?
  var branch: String?
  /// When it last stopped for him.
  var stoppedAt: Date?
  /// It stopped for him after he last saw the session (entered it in Term,
  /// cleared it, or prompted omp on any device).
  var unread = false
  /// Read from omp's terminal title: state and title only.
  var fromTitle = false

  /// Which of a session's agents speaks for it: one he hasn't seen first,
  /// then the one that needs him most.
  func outranks(_ other: AgentInfo) -> Bool {
    if unread != other.unread { return unread }
    return state.rank > other.state.rank
  }
}

extension Tmux {
  /// Starts the agent panes in an exec's output: ASCII group separator.
  static let agentMark: UInt8 = 0x1D

  /// Panes that publish `@agent`, or carry omp's title (`π > title`).
  static let agentFilter = "#{||:#{@agent},#{m:π *,#{pane_title}}}"

  /// list-panes fields, tab-separated. The payload goes last: JSON has no raw
  /// tab, so the last tab on a line starts it whatever the title holds.
  static let agentFields = ["session_id", "pane_current_command", "@seen", "session_name", "pane_title", "@agent"]

  /// A payload whose heartbeat (every 30 s) is older than this has stopped writing.
  static let agentStaleAfter: TimeInterval = 90

  /// Prints the mark, then one line per agent pane. A tmux too old for
  /// filters, or no server, prints no agents rather than failing the exec.
  static var agentsScript: String {
    let format = agentFields.map { "#{\($0)}" }.joined(separator: "\t")
    return #"printf '\035\n'; tmux list-panes -a -f '\#(agentFilter)' -F '\#(format)' 2>/dev/null"#
  }

  /// The agent panes alone: the badge's check while the tmux tab is closed.
  static func agentsCommand() -> String {
    [path, agentsScript, "exit 0"].joined(separator: "; ")
  }

  /// Marks sessions (ids) seen now, by the host's clock (the one their stops
  /// are stamped with).
  static func seenCommand(ids: [String]) -> String {
    ([path, "n=$(date +%s)"] + ids.map { "tmux set-option -t \(Command.shellQuote($0)) @seen \"$n\"" }).joined(separator: "; ")
  }

  /// Each session's agent (by session id) from an agent section: the one
  /// that speaks for it when it runs several.
  static func parseAgents(_ section: String, now: Date = .now) -> [String: AgentInfo] {
    var agents: [String: AgentInfo] = [:]
    for line in section.split(whereSeparator: \.isNewline) {
      guard let (id, agent) = parseAgent(line, now: now) else { continue }
      if let known = agents[id], !agent.outranks(known) { continue }
      agents[id] = agent
    }
    return agents
  }

  static func parseAgents(_ output: Data, now: Date = .now) -> [String: AgentInfo] {
    guard let mark = output.firstIndex(of: agentMark) else { return [:] }
    return parseAgents(String(decoding: output[output.index(after: mark)...], as: UTF8.self), now: now)
  }

  private static func parseAgent(_ line: Substring, now: Date) -> (String, AgentInfo)? {
    let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
    guard f.count == 4, f[0].hasPrefix("$") else { return nil }
    let command = String(f[1])
    let seen = TimeInterval(f[2]) ?? 0
    var rest = f[3]
    var payload: Substring = ""
    if let tab = rest.lastIndex(of: "\t") {
      payload = rest[rest.index(after: tab)...]
      rest = rest[..<tab]
    }
    let (name, title) = rest.firstIndex(of: "\t").map { (rest[..<$0], rest[rest.index(after: $0)...]) } ?? (rest, "")
    let agent = published(payload, command: command, seen: seen, now: now) ?? fromTitle(title, command: command)
    guard var agent else { return nil }
    agent.session = String(name)
    return (String(f[0]), agent)
  }

  /// The agent as its extension wrote it; nil when missing or unreadable.
  private static func published(_ payload: Substring, command: String, seen: TimeInterval, now: Date) -> AgentInfo? {
    guard payload.first == "{",
          let p = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
          let state = (p["state"] as? String).flatMap(AgentInfo.State.init(rawValue:)), state != .exited
    else { return nil }
    let date = { (key: String, dict: [String: Any]) -> Date? in (dict[key] as? Double).map { Date(timeIntervalSince1970: $0) } }
    var agent = AgentInfo(session: "", state: state)
    agent.since = date("since", p)
    agent.title = (p["title"] as? String).flatMap(plainTitle)
    agent.doing = p["doing"] as? String
    if let todo = p["todo"] as? [Any], todo.count >= 2, let done = todo[0] as? Int, let total = todo[1] as? Int {
      agent.todo = .init(done: done, total: total, current: todo.count > 2 ? todo[2] as? String : nil)
    }
    agent.question = p["q"] as? String
    agent.options = p["opts"] as? [String] ?? []
    agent.answer = p["last"] as? String
    agent.took = p["took"] as? Double
    agent.model = p["model"] as? String
    agent.thinking = p["think"] as? String
    agent.context = p["ctx"] as? Int
    agent.cost = p["cost"] as? Double
    agent.subagents = p["subs"] as? Int ?? 0
    agent.path = p["cwd"] as? String
    agent.branch = p["branch"] as? String
    agent.stoppedAt = (p["stop"] as? [String: Any]).flatMap { date("at", $0) }
    // Mid-turn, silent past its heartbeat, and its pane is back at a shell: omp died there.
    if [.working, .ask, .approval].contains(state), let written = date("t", p),
       now.timeIntervalSince(written) > agentStaleAfter, isShell(command) {
      agent.state = .exited
      agent.stoppedAt = written
    }
    agent.unread = agent.state.isStop && (agent.stoppedAt?.timeIntervalSince1970 ?? 0) > seen
    return agent
  }

  /// omp without the extension: `π > title` idle, `π ⠋ title` working,
  /// `π ! title` asks. Not once the pane is back at a shell: that title is
  /// left over.
  private static func fromTitle(_ title: Substring, command: String) -> AgentInfo? {
    guard title.hasPrefix("π "), !isShell(command) else { return nil }
    let rest = title.dropFirst(2)
    let state: AgentInfo.State
    switch rest.first {
    case ">": state = .idle
    case "!": state = .ask
    case .some("\u{2801}"..."\u{28FF}"): state = .working
    default: return nil
    }
    var agent = AgentInfo(session: "", state: state, fromTitle: true)
    agent.title = plainTitle(rest.dropFirst())
    return agent
  }

  private static func isShell(_ command: String) -> Bool {
    ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu"].contains(command.trimmingPrefix("-"))
  }

  /// A title without the icon omp puts in front of it (a Nerd Font glyph
  /// the menu's fonts don't have).
  static func plainTitle(_ title: some StringProtocol) -> String? {
    let scalars = Substring(title).unicodeScalars.drop { $0.properties.generalCategory == .privateUse || $0.properties.isWhitespace }
    let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }
}
