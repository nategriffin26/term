import AudioToolbox
import UIKit

@MainActor
protocol TabHost: AnyObject {
  func tabDidChange(_ tab: Tab)
  func tabWantsClose(_ tab: Tab)
  func tabWantsSettings(_ tab: Tab)
  func tabWantsTmuxSessions(_ tab: Tab, host: Host)
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
  /// Shown instead of the prompt while `connecting` comes up: the screen of
  /// the tmux session it attaches to, as last captured.
  private var preview: Session?
  /// What `remote`/`connecting` was opened with; reconnect and history reuse it.
  private(set) var target: Host?
  /// tmux session the remote is attached to, when known.
  private(set) var tmuxSession: String?

  private(set) var title = "term"
  /// The remote reported UNREACHABLE and has not been heard from since.
  private(set) var unreachable = false
  /// An in-place reconnect is running.
  private(set) var reconnecting = false
  /// A short line for the pane's banner: an upload's progress, or why it failed.
  private(set) var notice: Notice?
  /// The upload the banner's Cancel stops.
  var upload: Task<Void, Never>?
  private var noticeTimer: Task<Void, Never>?
  private let autoReconnect = AutoReconnect()
  private var attachmentProbe: Task<Void, Never>?
  private var reconnectPreparation: Task<Void, Never>?
  private var foreground = true
  private var firstAttachmentObservation = true
  /// Watches for an answer to the agent in the pane this tab shows.
  private var answerWatch = AnswerWatch()

  var pollsTmuxAttachment: Bool {
    foreground && !unreachable && !reconnecting && remote != nil && connecting == nil
  }

  var editor: LineEditor
  private var settingsObserver: NSObjectProtocol?

  /// What History shows: the tmux session the tab is attached to, else the
  /// tab's own buffer. Never a guess at a session on the server.
  var historySource: HistorySource? {
    guard let remote, target != nil else { return nil }
    return tmuxSession.map { .tmux(session: $0) } ?? .scrollback(remote.history())
  }

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

  /// Where dictated text said here goes: the remote on screen, as its host
  /// and tmux session; nil at the local prompt or while a preview shows.
  var dictationDestination: DictationDestination? {
    guard let remote, let target, view.session === remote else { return nil }
    return DictationDestination(host: target.id, tmuxSession: tmuxSession, connection: remote,
                                acceptsInput: !unreachable && !reconnecting)
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
    view.diagnosticName = { [weak self] in self?.sessionName ?? "closed" }
    view.onSubmit = { [weak self] in self?.submitted() }
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
    session.diagrams = DiagramSource(host: saved.target, tmuxSession: saved.tmuxSession)
    session.rail = saved.tmuxSession.map { MessageRail(host: saved.target, tmuxSession: $0) }
    wireRemote(session)
    remote = session
    view.session = session
    observeTmuxAttachment()
    echo("Restored \(saved.target.alias).\r\n")
  }

  isolated deinit {
    attachmentProbe?.cancel()
    reconnectPreparation?.cancel()
    if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
  }

  /// Shows the prompt on a fresh tab.
  func start() {
    echo("\u{1b}[2mType help for commands.\u{1b}[0m\r\n")
    prompt()
  }

  // MARK: - Connecting

  /// Opens `target` (its startup command, or `command` instead for this
  /// connection only; reconnects use the startup command), replacing any remote.
  func connect(_ target: Host, tmuxSession: String? = nil, preview screen: Data? = nil, command: String? = nil) {
    stopAttachmentObservation()
    connecting = nil
    dropPreview()
    var spec = Self.spec(for: target)
    if let command { spec.command = command }
    guard let session = Session(connect: spec, cols: local.cols, rows: local.rows) else {
      echo("\u{1b}[31mCould not start a connection to \(target.alias).\u{1b}[0m\r\n")
      prompt()
      return
    }
    self.target = target
    self.tmuxSession = tmuxSession ?? Tmux.sessionName(inCommand: target.startupCommand)
    session.diagrams = DiagramSource(host: target, tmuxSession: self.tmuxSession)
    session.rail = self.tmuxSession.map { MessageRail(host: target, tmuxSession: $0) }
    wireRemote(session)
    connecting = session
    DiagnosticLog.record(.connection, "connect", "host=\(DiagnosticLog.name(target.alias)) transport=\(target.transport)"
      + " tmux=\(self.tmuxSession.map(DiagnosticLog.name) ?? "none") replacing=\(remote != nil)")
    if remote == nil {
      let via = target.transport == .mosh ? "mosh" : "ssh"
      echo("Connecting to \(target.alias) (\(target.user)@\(target.hostname)) over \(via)…\r\n")
      if let screen, let shown = Session(localCols: local.cols, rows: local.rows) {
        shown.setTheme(AppSettings.shared.termTheme)
        shown.diagrams = session.diagrams
        shown.feed(screen)
        preview = shown
        view.session = shown
      }
    }
    host?.tabDidChange(self)
  }

  /// Refresh the live client before replacing its transport. A dead SSH
  /// connection retains the last observation; mosh usually still has its client.
  func reconnect() {
    guard let remote, let target, !reconnecting else { return }
    attachmentProbe?.cancel()
    attachmentProbe = nil
    reconnecting = true
    host?.tabDidChange(self)
    reconnectPreparation = Task { [weak self] in
      guard let self else { return }
      await refreshTmuxAttachment()
      guard !Task.isCancelled, self.remote === remote else { return }
      reconnectPreparation = nil
      var spec = Self.spec(for: target)
      spec.command = TmuxAttachment.reconnectCommand(startup: spec.command, session: tmuxSession)
      DiagnosticLog.record(.connection, "reconnect", "host=\(DiagnosticLog.name(target.alias)) transport=\(target.transport)"
        + " tmux=\(tmuxSession.map(DiagnosticLog.name) ?? "none") endOldServer=\(tmuxSession != nil || spec.runsInTmux)")
      remote.reconnect(spec: spec, endOldServer: tmuxSession != nil || spec.runsInTmux)
    }
  }

  /// Abandons a connection attempt; the screen stays as it is.
  func cancelConnecting() {
    connecting = nil
    dropPreview()
    host?.tabDidChange(self)
  }

  private func dropPreview() {
    guard preview != nil else { return }
    preview = nil
    view.session = remote ?? local
  }

  /// Ends the remote session and returns to the prompt.
  func disconnect() {
    connecting = nil
    dropPreview()
    if remote != nil {
      DiagnosticLog.record(.connection, "disconnect", "host=\(DiagnosticLog.name(target?.alias ?? "none"))")
      closeRemote(reason: "")
    }
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
      return tmuxSession != nil || Self.spec(for: target).runsInTmux
    }
    autoReconnect.probe = { [weak self] in
      guard let self, let target else { return false }
      // In Term's own tmux attach the probe also asks whether the session is
      // still there: one closed meanwhile ends the tab, as when tmux exits.
      let session = Tmux.attachedSession(target.startupCommand, session: tmuxSession)
      guard case .success(let out)? = await RemoteExec.run(Self.spec(for: target),
        session.map(Tmux.hasSessionCommand) ?? "true", timeout: .seconds(2))
      else { return false }
      if session != nil, out.status == 1, remote != nil {
        DiagnosticLog.record(.connection, "tmux-session-gone", "tmux=\(DiagnosticLog.name(session ?? ""))")
        closeRemote(reason: "")
        return false
      }
      return true
    }
    autoReconnect.reconnect = { [weak self] in self?.reconnect() }
  }

  /// Initial observation; periodic snapshots are batched by SessionRegistry.
  private func observeTmuxAttachment() {
    attachmentProbe?.cancel()
    guard foreground, !unreachable else { attachmentProbe = nil; return }
    attachmentProbe = Task { [weak self] in await self?.refreshTmuxAttachment() }
  }

  private func stopAttachmentObservation() {
    attachmentProbe?.cancel()
    attachmentProbe = nil
    if reconnectPreparation != nil {
      reconnectPreparation?.cancel()
      reconnectPreparation = nil
      reconnecting = false
      autoReconnect.reconnectFinished(succeeded: false)
    }
  }

  func refreshTmuxAttachment() async {
    await TmuxAttachment.refresh([self])
  }

  func applyTmuxAttachment(_ observation: TmuxAttachment, session: Session, root: UInt32) {
    guard remote === session, connecting == nil, let target, session.processID == root,
          target.transport != .ssh || session.status.kind == TERM_STATUS_CONNECTED.rawValue else { return }
    let name: String?
    switch observation {
    case .unavailable: return
    case .detached:
      // CONNECTED can arrive before the startup command has launched tmux.
      if firstAttachmentObservation { firstAttachmentObservation = false; return }
      name = nil
    case .attached(let session): name = session
    }
    firstAttachmentObservation = false
    guard tmuxSession != name else { return }
    tmuxSession = name
    DiagnosticLog.record(.connection, "tmux-attached", "host=\(DiagnosticLog.name(target.alias)) tmux=\(name.map(DiagnosticLog.name) ?? "none")")
    session.diagrams = DiagramSource(host: target, tmuxSession: name)
    session.rail = name.map { MessageRail(host: target, tmuxSession: $0) }
    if view.session === session { view.railView.bind(session.rail) }
    autoReconnect.statusChanged(unreachable: unreachable)
    host?.tabDidChange(self)
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
      DiagnosticLog.record(.connection, failure == nil ? "reconnected" : "reconnect-failed",
        "tab=\(DiagnosticLog.name(sessionName))" + (failure.map { " failure=\(DiagnosticLog.failure($0))" } ?? ""))
      autoReconnect.reconnectFinished(succeeded: failure == nil)
      if failure == nil { firstAttachmentObservation = true }
      observeTmuxAttachment()
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

  /// Return without modifiers typed into the remote: an answer if the pane
  /// it shows waits on its agent and the next probe sees that stop over.
  private func submitted() {
    guard let remote, view.session === remote else { return }
    answerWatch.submitted()
  }

  /// The attachment probe's view of the pane this tab's tmux client shows.
  func applyShownAgent(_ agent: ShownAgent?, session: Session) {
    guard remote === session, connecting == nil else { return }
    if answerWatch.observe(agent) { UsageCounter.shared.record(.askAnswered) }
  }

  private func statusChanged(_ session: Session, status: TermStatus, message: String) {
    let role = session === connecting ? "connecting" : session === remote ? "remote" : "stale"
    DiagnosticLog.record(.connection, "status", "kind=\(Self.statusName(status.kind)) session=\(role)"
      + " host=\(DiagnosticLog.name(target?.alias ?? "none")) tab=\(DiagnosticLog.name(sessionName))"
      + (message.isEmpty ? "" : " failure=\(DiagnosticLog.failure(message))"))
    switch Int(status.kind) {
    case Int(TERM_STATUS_CONNECTED.rawValue):
      unreachable = false
      if session === connecting || session === remote { UsageCounter.shared.record(.hostOK) }
      if session === connecting {
        connecting = nil
        let old = remote
        remote = session
        if preview == nil {
          view.session = session
        } else {
          // A mosh session connects blank and tmux draws a moment later:
          // the snapshot stays until then, or a second if nothing draws.
          session.onFrame = { [weak self, weak session] in
            guard let self, let session,
                  !session.text(fromCol: 0, row: 0, toCol: session.cols - 1, row: session.rows - 1).allSatisfy(\.isWhitespace)
            else { return }
            reveal(session)
          }
          Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(1))
            if let self, let session { reveal(session) }
          }
        }
        reconnecting = false
        autoReconnect.stop()
        firstAttachmentObservation = true
        observeTmuxAttachment()
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
        dropPreview()
        if remote == nil {
          let why = message.isEmpty ? "Connection closed." : message
          echo("\u{1b}[31m\(why)\u{1b}[0m\r\n")
          prompt()
        }
      } else if session === remote {
        if target?.transport == .ssh, message == "connection lost" {
          unreachable = true
          attachmentProbe?.cancel()
          attachmentProbe = nil
        } else {
          closeRemote(reason: message)
        }
      }
    default:
      break
    }
    host?.tabDidChange(self)
  }

  private static func statusName(_ kind: UInt32) -> String {
    switch Int(kind) {
    case Int(TERM_STATUS_CONNECTING.rawValue): "connecting"
    case Int(TERM_STATUS_CONNECTED.rawValue): "connected"
    case Int(TERM_STATUS_UNREACHABLE.rawValue): "unreachable"
    case Int(TERM_STATUS_CLOSED.rawValue): "closed"
    default: "\(kind)"
    }
  }

  /// The connected session takes over from the preview.
  private func reveal(_ session: Session) {
    guard preview != nil, remote === session else { return }
    preview = nil
    view.session = session
  }

  private func closeRemote(reason: String) {
    stopAttachmentObservation()
    let label = target?.alias ?? "host"
    remote = nil
    unreachable = false
    reconnecting = false
    autoReconnect.stop()
    preview = nil
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
    view.lineSpacing = CGFloat(s.lineSpacing)
    view.cursorOverride = s.cursorOverride
    view.showsSmartKeysWithHardwareKeyboard = s.smartKeysWithHardwareKeyboard
    view.keyClicksEnabled = s.keyClickSound
    view.showsMessageRail = s.messageRail
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
    foreground = false
    autoReconnect.suspended()
    // Cancelling preparation also releases AutoReconnect's in-flight state.
    stopAttachmentObservation()
    remote?.suspend()
    connecting?.suspend()
  }

  func resume() {
    foreground = true
    remote?.resume()
    connecting?.resume()
    autoReconnect.resumed()
    if remote != nil { observeTmuxAttachment() }
  }

  // MARK: - Prompt output

  func echo(_ text: String) {
    local.feed(Data(editor.printAbove(text).utf8))
  }

  /// Shows `line` entered at the prompt, for a connection the menu starts.
  func enter(_ line: String) {
    local.feed(Data(editor.enter(line).utf8))
  }

  func prompt() {
    local.feed(Data(editor.begin().utf8))
  }

  /// Shows `text` in the banner (nil clears it), with an upload's
  /// `progress` (0...1) and Cancel, or as a failure, for `seconds` when given.
  func showNotice(_ text: String?, progress: Double? = nil, failed: Bool = false, cancellable: Bool = false, for seconds: Double? = nil) {
    noticeTimer?.cancel()
    noticeTimer = nil
    let next = text.map { Notice(text: $0, progress: progress, failed: failed, cancellable: cancellable) }
    if next != notice {
      notice = next
      host?.tabDidChange(self)
    }
    guard let seconds, text != nil else { return }
    noticeTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.showNotice(nil)
    }
  }
}

/// What a pane's banner says for its tab besides connection trouble.
struct Notice: Equatable {
  var text: String
  var progress: Double?
  var failed = false
  /// Cancel stops the upload that made it.
  var cancellable = false
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
