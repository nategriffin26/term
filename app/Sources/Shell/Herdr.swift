import Foundation

/// herdr is the session store shared with the Mac: workspaces of panes, each
/// pane maybe running a coding agent whose state herdr tracks. The phone lists
/// them and reads history over SSH exec; a tab direct-attaches one pane's
/// terminal from inside mosh-server.
enum Herdr {
  /// An agent's lifecycle state as herdr reports it, most urgent first.
  enum State: String, Codable, Sendable, CaseIterable {
    case blocked, done, working, idle, unknown
  }

  /// One pane, where a tab attaches.
  struct Pane: Codable, Equatable, Sendable, Identifiable {
    /// Public pane id, e.g. `w1:p2`. Survives a herdr server restart.
    var id: String
    /// The terminal in the pane, e.g. `term_65eaf9d8175d11`: what attach
    /// takes. A server restart gives the pane a new one.
    var terminal: String
    /// The workspace's label.
    var workspace: String
    /// Agent kind, e.g. `omp`, when one runs in the pane.
    var agent: String?
    /// The agent's live name, when it has one.
    var name: String?
    /// Nil when no agent runs in the pane.
    var state: State?
    var cwd: String?

    /// Row title under its workspace in the picker.
    var title: String { name ?? agent ?? "shell" }
    /// Name in the HUD, the overview and the window title.
    var sessionName: String { name ?? workspace }
    /// Sort key: blocked agents first, panes without an agent last.
    var rank: Int { state.map { State.allCases.firstIndex(of: $0)! } ?? State.allCases.count }
  }

  struct Workspace: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    /// Most urgent first, then herdr's order.
    var panes: [Pane]
    /// The pane in front: the active tab's focused pane.
    var focused: String?
    var rank: Int { panes.map(\.rank).min() ?? State.allCases.count }
  }

  struct Snapshot: Equatable, Sendable {
    /// Most urgent first, then herdr's order.
    var workspaces: [Workspace]

    var panes: [Pane] { workspaces.flatMap(\.panes) }

    /// What `herdr host NAME` attaches: an agent's name, a pane id, a
    /// workspace label (its pane in front) or a terminal id, in that order.
    func resolve(_ name: String) -> Pane? {
      if let p = panes.first(where: { $0.name == name || $0.id == name }) { return p }
      if let w = workspaces.first(where: { $0.label == name }) {
        return w.panes.first { $0.id == w.focused } ?? w.panes.first
      }
      return panes.first { $0.terminal == name }
    }

    /// `pane` as it is now: the same terminal, else the same pane id (after
    /// a server restart its terminal is new).
    func current(_ pane: Pane) -> Pane? {
      panes.first { $0.terminal == pane.terminal } ?? panes.first { $0.id == pane.id }
    }

    /// The pane a startup command attaches.
    func pane(for target: Target) -> Pane? {
      switch target {
      case .terminal(let id): panes.first { $0.terminal == id }
      case .agent(let name): panes.first { $0.name == name || $0.id == name }
      }
    }
  }

  enum Failure: Error, Equatable {
    case notInstalled
    case notRunning
    case failed(String)

    func message(host: String) -> String {
      switch self {
      case .notInstalled: "herdr is not installed on \(host)."
      // Never started from here: a server born under SSH lacks the Mac's
      // privacy grants, and every pane under it inherits that.
      case .notRunning: "herdr is not running on \(host). Start it on the computer."
      case .failed(let text): text
      }
    }
  }

  // MARK: - Commands

  /// herdr installs to ~/.local/bin, and non-interactive SSH on macOS has
  /// neither that nor Homebrew on PATH. Appended, so a herdr on PATH wins.
  static let path = #"PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin""#
  private static let cli = "\(path) herdr"

  static let snapshotCommand = "\(cli) api snapshot 2>&1"

  /// mosh-server's command: puts the pane's terminal on this tab, taking
  /// input and size from any other direct attach (an in-place reconnect's
  /// new server takes it from the old one).
  static func attachCommand(_ terminal: String) -> String {
    "env \(path) herdr terminal attach \(Command.shellQuote(terminal)) --takeover"
  }

  /// Scrollback plus screen with colors, soft wraps joined so lines rewrap
  /// at the phone's width.
  static func historyCommand(_ pane: String, lines: Int = 3000) -> String {
    "\(cli) pane read \(Command.shellQuote(pane)) --source recent-unwrapped --lines \(lines) --ansi 2>&1"
  }

  static func paneCommand(_ pane: String) -> String {
    "\(cli) pane get \(Command.shellQuote(pane)) 2>&1"
  }

  /// herdr opens a missing folder as home without a word, so the shell goes
  /// there first and says when it cannot.
  static func createCommand(cwd: String) -> String {
    let folder = cwd.trimmingCharacters(in: .whitespaces)
    let missing = Command.shellQuote("No folder \(folder.isEmpty ? "~" : folder).")
    return "if cd \(shellPath(folder)) 2>/dev/null; then \(cli) workspace create --cwd \"$PWD\" --no-focus 2>&1; "
      + "else echo \(missing); exit 1; fi"
  }

  /// A directory for the remote shell: `~` and `~/…` expand there, anything
  /// else is quoted.
  static func shellPath(_ path: String) -> String {
    let p = path.trimmingCharacters(in: .whitespaces)
    if p.isEmpty || p == "~" { return "~" }
    if p.hasPrefix("~/") { return "~/" + Command.shellQuote(String(p.dropFirst(2))) }
    return Command.shellQuote(p)
  }

  /// `path` with the user's home shown as `~`.
  static func displayPath(_ path: String, user: String) -> String {
    for home in ["/Users/\(user)", "/home/\(user)"] {
      if path == home { return "~" }
      if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    }
    return path
  }

  // MARK: - Parsing

  static func parseSnapshot(status: Int32, output: Data) -> Result<Snapshot, Failure> {
    decode(RawSnapshot.self, status: status, output: output).map { raw in
      let s = raw.snapshot
      let names = Dictionary((s.agents ?? []).compactMap { a in a.name.map { (a.paneId, $0) } }, uniquingKeysWith: { a, _ in a })
      let focused = Dictionary((s.layouts ?? []).compactMap { l in l.focusedPaneId.map { (l.tabId, $0) } }, uniquingKeysWith: { a, _ in a })
      let workspaces = s.workspaces.map { w in
        let label = w.label ?? w.workspaceId
        let panes = s.panes.filter { $0.workspaceId == w.workspaceId }
          .map { $0.pane(workspace: label, name: names[$0.paneId]) }
        return Workspace(id: w.workspaceId, label: label, panes: stableSorted(panes, by: \.rank),
                         focused: w.activeTabId.flatMap { focused[$0] })
      }
      return Snapshot(workspaces: stableSorted(workspaces, by: \.rank))
    }
  }

  /// The pane of a workspace `createCommand` made.
  static func parseCreated(status: Int32, output: Data) -> Result<Pane, Failure> {
    decode(RawCreated.self, status: status, output: output).map { raw in
      raw.rootPane.pane(workspace: raw.workspace.label ?? raw.workspace.workspaceId, name: nil)
    }
  }

  /// The folder a pane's foreground process is in, from `paneCommand`.
  static func parseFolder(status: Int32, output: Data) -> Result<String, Failure> {
    decode(RawPaneInfo.self, status: status, output: output).flatMap { raw in
      guard let path = raw.pane.foregroundCwd ?? raw.pane.cwd, path.hasPrefix("/") else {
        return .failure(.failed("herdr knows no folder for pane \(raw.pane.paneId)."))
      }
      return .success(path)
    }
  }

  /// `historyCommand` output: the pane's text, or why there is none.
  static func parseHistory(status: Int32, output: Data) -> Result<Data, Failure> {
    status == 0 ? .success(output) : .failure(failure(status: status, output: output))
  }

  // MARK: - Startup commands

  /// What a startup command attaches to.
  enum Target: Equatable, Sendable {
    /// `herdr terminal attach ID`
    case terminal(String)
    /// `herdr agent attach NAME`: an agent's name or its pane id.
    case agent(String)
  }

  /// Whether `command` runs herdr (after `env` and NAME=value words), so the
  /// session outlives its connection.
  static func runs(_ command: String) -> Bool {
    program(in: command) != nil
  }

  static func target(inCommand command: String) -> Target? {
    guard var words = program(in: command) else { return nil }
    // Global options that take a value come before the subcommand.
    var positional: [String] = []
    while !words.isEmpty {
      let word = words.removeFirst()
      if ["--session", "--machine", "--remote"].contains(word) {
        if !words.isEmpty { words.removeFirst() }
      } else if !word.hasPrefix("-") {
        positional.append(word)
      }
    }
    guard positional.count >= 3, positional[1] == "attach" else { return nil }
    switch positional[0] {
    case "terminal": return .terminal(positional[2])
    case "agent": return .agent(positional[2])
    default: return nil
    }
  }

  /// The words after the herdr program, or nil when the command runs something else.
  private static func program(in command: String) -> [String]? {
    guard case .success(var words) = Command.tokenize(command) else { return nil }
    if let first = words.first, (first as NSString).lastPathComponent == "env" { words.removeFirst() }
    while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
    guard let first = words.first, (first as NSString).lastPathComponent == "herdr" else { return nil }
    return Array(words.dropFirst())
  }

  // MARK: - JSON

  private struct Envelope<R: Decodable>: Decodable {
    var result: R?
    var error: APIError?
  }

  private struct APIError: Decodable {
    var code: String
    var message: String
  }

  private struct RawSnapshot: Decodable {
    struct Body: Decodable {
      var workspaces: [RawWorkspace]
      var panes: [RawPane]
      var agents: [RawAgent]?
      var layouts: [RawLayout]?
    }
    var snapshot: Body
  }

  private struct RawWorkspace: Decodable {
    var workspaceId: String
    var label: String?
    var activeTabId: String?
  }

  private struct RawPane: Decodable {
    var paneId: String
    var terminalId: String
    var workspaceId: String
    var agent: String?
    var agentStatus: String?
    var cwd: String?
    var foregroundCwd: String?

    func pane(workspace: String, name: String?) -> Pane {
      Pane(id: paneId, terminal: terminalId, workspace: workspace, agent: agent, name: name,
           state: agent == nil ? nil : State(rawValue: agentStatus ?? "") ?? .unknown,
           cwd: foregroundCwd ?? cwd)
    }
  }

  private struct RawAgent: Decodable {
    var paneId: String
    var name: String?
  }

  private struct RawLayout: Decodable {
    var tabId: String
    var focusedPaneId: String?
  }

  private struct RawCreated: Decodable {
    var workspace: RawWorkspace
    var rootPane: RawPane
  }

  private struct RawPaneInfo: Decodable {
    var pane: RawPane
  }

  /// herdr prints one JSON object: `result` on success, `error` (exit 1) on
  /// failure.
  private static func decode<R: Decodable>(_ type: R.Type, status: Int32, output: Data) -> Result<R, Failure> {
    if status == 0, let result = envelope(R.self, output)?.result { return .success(result) }
    return .failure(failure(status: status, output: output))
  }

  private static func failure(status: Int32, output: Data) -> Failure {
    // The shell exits 127 when it cannot find herdr.
    if status == 127 { return .notInstalled }
    if let error = envelope(Anything.self, output)?.error {
      return error.code == "server_not_running" ? .notRunning : .failed(error.message)
    }
    if status == 0 { return .failed("Term could not read herdr's answer.") }
    let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(text.isEmpty ? "herdr exited with status \(status)." : text)
  }

  /// Any `result`: only `error` is read.
  private struct Anything: Decodable {
    init(from decoder: Decoder) {}
  }

  private static func envelope<R: Decodable>(_ type: R.Type, _ output: Data) -> Envelope<R>? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    if let whole = try? decoder.decode(Envelope<R>.self, from: output) { return whole }
    // Anything herdr logs before its answer comes first; the JSON is the last line.
    let lines = output.split(separator: UInt8(ascii: "\n"))
    return lines.last.flatMap { try? decoder.decode(Envelope<R>.self, from: Data($0)) }
  }

  private static func stableSorted<T>(_ items: [T], by key: (T) -> Int) -> [T] {
    items.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
  }
}

extension Herdr {
  /// Runs one of the commands above on `host` and parses its output.
  static func run<T>(_ command: String, on host: Host,
                     _ parse: (Int32, Data) -> Result<T, Failure>) async -> Result<T, Failure> {
    switch await RemoteExec.run(Tab.spec(for: host), command) {
    case .failure(let failure): .failure(.failed(failure.message))
    case .success(let output): parse(output.status, output.stdout)
    }
  }

  /// Brings each attached tab's pane name and agent state up to date: one
  /// snapshot per host.
  @MainActor
  static func refresh(_ tabs: [Tab]) async {
    let attached = tabs.filter { $0.isConnected && $0.target.map { Herdr.runs($0.startupCommand) } == true }
    let byHost = Dictionary(grouping: attached) { "\($0.target!.user)@\($0.target!.knownHostsKey)" }
    for group in byHost.values {
      guard let host = group.first?.target,
            case .success(let snapshot) = await run(snapshotCommand, on: host, parseSnapshot) else { continue }
      for tab in group { tab.update(from: snapshot) }
    }
  }
}

/// term_exec as async: one command on a host over SSH, output and status back.
enum RemoteExec {
  struct Output: Sendable {
    var status: Int32
    var stdout: Data
  }

  struct Failure: Error, Equatable {
    var message: String
  }

  private final class Box: Sendable {
    let continuation: CheckedContinuation<Result<Output, Failure>, Never>
    init(_ c: CheckedContinuation<Result<Output, Failure>, Never>) { continuation = c }
  }

  static func run(_ spec: ConnectSpec, _ command: String) async -> Result<Output, Failure> {
    await withCheckedContinuation { continuation in
      let ctx = Unmanaged.passRetained(Box(continuation)).toOpaque()
      spec.withTermConnect(cols: 0, rows: 0) { c in
        term_exec(c, command, ctx) { ctx, status, out, len, error in
          let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
          if let error {
            box.continuation.resume(returning: .failure(Failure(message: String(cString: error))))
          } else {
            let data = out.map { Data(bytes: $0, count: len) } ?? Data()
            box.continuation.resume(returning: .success(Output(status: status, stdout: data)))
          }
        }
      }
    }
  }
}
