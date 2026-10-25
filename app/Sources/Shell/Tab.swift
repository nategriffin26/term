import AudioToolbox
import UIKit

@MainActor
protocol TabHost: AnyObject {
  func tabDidChange(_ tab: Tab)
  func tabWantsClose(_ tab: Tab)
  func tabWantsSettings(_ tab: Tab)
  func tabWantsTmuxPicker(_ tab: Tab, host: Host)
}

/// One shell (Blink's space): a local prompt session, and while connected a
/// remote session shown in its place. Survives scene disconnects through
/// SessionRegistry and app termination through saved mosh state.
@MainActor
final class Tab {
  let id: UUID
  let view: TerminalView
  weak var host: TabHost?

  /// The local prompt. Always alive; shown whenever no remote is.
  let local: Session
  /// The remote session on screen.
  private(set) var remote: Session?
  /// A connection in progress: shown once it reports CONNECTED.
  private(set) var connecting: Session?
  /// What `remote`/`connecting` was opened with; reconnect and history reuse it.
  private(set) var target: Host?
  /// tmux session the remote is attached to, when known.
  private(set) var tmuxSession: String?

  private(set) var title = "term"
  /// The remote reported UNREACHABLE and has not been heard from since.
  private(set) var unreachable = false
  /// An in-place reconnect is running.
  private(set) var reconnecting = false
  private let autoReconnect = AutoReconnect()

  var editor: LineEditor
  private var settingsObserver: NSObjectProtocol?

  var current: Session { remote ?? local }
  var isConnected: Bool { remote != nil }
  /// Shown in session lists: the remote title, else the host, else "term".
  var displayTitle: String {
    if remote != nil, title != "term", !title.isEmpty { return title }
    return tmuxSession ?? target?.alias ?? title
  }

  /// Name in the session HUD and overview: the tmux session the remote runs
  /// in, else "shell".
  var sessionName: String {
    guard remote != nil || connecting != nil else { return "shell" }
    return tmuxSession ?? "shell"
  }

  /// Where the session runs: the host's alias, or nil at the local prompt.
  var hostName: String? {
    remote != nil || connecting != nil ? target?.alias : nil
  }

  init?(id: UUID = UUID()) {
    guard let local = Session(localCols: 80, rows: 24) else { return nil }
    self.id = id
    self.local = local
    view = TerminalView(session: local)
    editor = LineEditor(prompt: "term> ", style: "\u{1b}[1;34m", history: PromptHistory.load(),
                        completer: { before in
                          Command.complete(before, aliases: MainActor.assumeIsolated { ConfigStore.shared.hosts.map(\.alias) })
                        })
    wireLocal()
    wireAutoReconnect()
    applySettings()
    settingsObserver = NotificationCenter.default.addObserver(
      forName: .termSettingsChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applySettings() }
    }
    // Bracketed paste so a pasted command is edited, not run line by line.
    local.feed(Data("\u{1b}[?2004h".utf8))
  }

  /// A tab whose remote comes back from saved mosh state.
  convenience init?(restoring saved: SavedTab, state: Data) {
    self.init(id: saved.id)
    guard let session = Session(restore: state) else { return nil }
    target = saved.target
    tmuxSession = saved.tmuxSession
    title = saved.title
    wireRemote(session)
    remote = session
    view.session = session
    echo("Restored \(saved.target.alias).\r\n")
  }

  isolated deinit {
    if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
  }

  /// Shows the prompt on a fresh tab.
  func start() {
    echo("\u{1b}[2mType help for commands.\u{1b}[0m\r\n")
    prompt()
  }

  // MARK: - Connecting

  /// Opens `target` (its startup command, or `command` instead), replacing any remote.
  func connect(_ target: Host, tmuxSession: String? = nil) {
    connecting = nil
    let spec = Self.spec(for: target)
    guard let session = Session(connect: spec, cols: local.cols, rows: local.rows) else {
      echo("\u{1b}[31mCould not start a connection to \(target.alias).\u{1b}[0m\r\n")
      prompt()
      return
    }
    self.target = target
    self.tmuxSession = tmuxSession ?? Tmux.sessionName(inCommand: target.startupCommand)
    wireRemote(session)
    connecting = session
    if remote == nil {
      let via = target.transport == .mosh ? "mosh" : "ssh"
      echo("Connecting to \(target.alias) (\(target.user)@\(target.hostname)) over \(via)…\r\n")
    }
    host?.tabDidChange(self)
  }

  /// Replaces the remote's server in place, same screen. A tmux session ends
  /// the old mosh-server first (it is silent, and tmux keeps the session);
  /// the banner's button and the automatic reconnect both come here.
  func reconnect() {
    guard let remote, let target, !reconnecting else { return }
    let spec = Self.spec(for: target)
    reconnecting = true
    remote.reconnect(spec: spec, endOldServer: spec.runsInTmux)
    host?.tabDidChange(self)
  }

  /// Abandons a connection attempt; the screen stays as it is.
  func cancelConnecting() {
    connecting = nil
    host?.tabDidChange(self)
  }

  /// Ends the remote session and returns to the prompt.
  func disconnect() {
    connecting = nil
    if remote != nil { closeRemote(reason: "") }
  }

  static func spec(for host: Host) -> ConnectSpec {
    let keyName = host.keyName ?? Keychain.keys().first?.name
    return ConnectSpec(
      transport: host.transport, hostname: host.hostname, port: host.port, user: host.user,
      privateKey: keyName.flatMap(Keychain.privateKey(named:)),
      password: Keychain.password(for: host.id),
      hostKey: ConfigStore.shared.hostKey(for: host.knownHostsKey),
      command: host.startupCommand.isEmpty ? nil : host.startupCommand,
      moshServer: host.moshServer.isEmpty ? nil : host.moshServer,
      prediction: host.prediction, label: host.alias)
  }

  /// Only a mosh session inside tmux reconnects by itself: a new server loses nothing there.
  private func wireAutoReconnect() {
    autoReconnect.isEligible = { [weak self] in
      guard let self, remote != nil, !reconnecting, let target, target.transport == .mosh else { return false }
      return Self.spec(for: target).runsInTmux
    }
    autoReconnect.probe = { [weak self] in
      guard let target = self?.target else { return false }
      guard case .success(let out) = await RemoteExec.run(Self.spec(for: target), "true") else { return false }
      return out.status == 0
    }
    autoReconnect.reconnect = { [weak self] in self?.reconnect() }
  }

  private func wireLocal() {
    local.onOutput = { [weak self] data in self?.typed(data) }
    local.onGridChange = { [weak self] cols, _ in
      guard let self else { return }
      let redraw = editor.setColumns(cols)
      if !redraw.isEmpty { local.feed(Data(redraw.utf8)) }
    }
    local.onTitle = { [weak self] title in
      guard let self, remote == nil else { return }
      self.title = title
      host?.tabDidChange(self)
    }
    wireCommon(local)
  }

  private func wireRemote(_ session: Session) {
    session.onStatus = { [weak self, weak session] status, message in
      guard let self, let session else { return }
      statusChanged(session, status: status, message: message)
    }
    session.onTitle = { [weak self, weak session] title in
      guard let self, let session, session === remote else { return }
      self.title = title
      host?.tabDidChange(self)
    }
    session.onReconnect = { [weak self, weak session] failure in
      guard let self, let session, session === remote else { return }
      reconnecting = false
      autoReconnect.reconnectFinished(succeeded: failure == nil)
      host?.tabDidChange(self)
    }
    session.onHostKey = { [weak self] key in
      guard let self, let target else { return }
      ConfigStore.shared.pinHostKey(key, for: target.knownHostsKey)
      let fp = SSHKeys.fingerprint(key) ?? key
      echo("\u{1b}[2mPinned \(target.hostname)'s host key \(fp).\u{1b}[0m\r\n")
    }
    wireCommon(session)
    session.setTheme(AppSettings.shared.termTheme)
  }

  private func wireCommon(_ session: Session) {
    session.onBell = {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    session.onClipboard = { text in
      UIPasteboard.general.string = text
    }
  }

  private func statusChanged(_ session: Session, status: TermStatus, message: String) {
    switch Int(status.kind) {
    case Int(TERM_STATUS_CONNECTED.rawValue):
      unreachable = false
      if session === connecting {
        connecting = nil
        let old = remote
        remote = session
        view.session = session
        reconnecting = false
        autoReconnect.stop()
        _ = old  // freed when this scope ends
      } else if session === remote {
        autoReconnect.statusChanged(unreachable: false)
      }
    case Int(TERM_STATUS_UNREACHABLE.rawValue):
      if session === remote {
        unreachable = true
        autoReconnect.statusChanged(unreachable: true)
      }
    case Int(TERM_STATUS_CLOSED.rawValue):
      if session === connecting {
        connecting = nil
        if remote == nil {
          let why = message.isEmpty ? "Connection closed." : message
          echo("\u{1b}[31m\(why)\u{1b}[0m\r\n")
          prompt()
        }
      } else if session === remote {
        closeRemote(reason: message)
      }
    default:
      break
    }
    host?.tabDidChange(self)
  }

  private func closeRemote(reason: String) {
    let label = target?.alias ?? "host"
    remote = nil
    unreachable = false
    reconnecting = false
    autoReconnect.stop()
    view.session = local
    title = "term"
    if reason.isEmpty {
      echo("Connection to \(label) closed.\r\n")
    } else {
      echo("\u{1b}[31m\(reason)\u{1b}[0m\r\n")
    }
    prompt()
    host?.tabDidChange(self)
  }

  // MARK: - Settings

  func applySettings() {
    let s = AppSettings.shared
    view.fontSize = CGFloat(s.fontSize)
    view.fontFamily = s.fontFamily
    view.cursorBlinkEnabled = s.cursorBlink
    view.showsSmartKeysWithHardwareKeyboard = s.smartKeysWithHardwareKeyboard
    view.keyClicksEnabled = s.keyClickSound
    let theme = s.termTheme
    local.setTheme(theme)
    remote?.setTheme(theme)
    connecting?.setTheme(theme)
  }

  // MARK: - Persistence

  /// State that lets a mosh remote outlive the app; nil for local or SSH tabs.
  func saveState() -> (SavedTab, Data)? {
    guard let remote, let target, target.transport == .mosh, let blob = remote.save() else { return nil }
    return (SavedTab(id: id, target: target, tmuxSession: tmuxSession, title: title), blob)
  }

  func suspend() {
    autoReconnect.suspended()
    remote?.suspend()
    connecting?.suspend()
  }

  func resume() {
    remote?.resume()
    connecting?.resume()
    autoReconnect.resumed()
  }

  // MARK: - Prompt output

  func echo(_ text: String) {
    local.feed(Data(editor.printAbove(text).utf8))
  }

  func prompt() {
    local.feed(Data(editor.begin().utf8))
  }
}

extension Tab: Identifiable {}

/// Saved alongside a mosh state blob (SessionRegistry).
struct SavedTab: Codable, Equatable {
  var id: UUID
  var target: Host
  var tmuxSession: String?
  var title: String
}

/// The prompt's command history, one line per entry.
enum PromptHistory {
  static let url = AppDirectories.support.appending(path: "history.txt")

  static func load() -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  static func save(_ lines: [String]) {
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }
}
