import UIKit

/// The local prompt: what the user types into a tab that has no remote.
extension Tab {
  func typed(_ data: Data) {
    let (output, events) = editor.feed(data)
    if !output.isEmpty { local.feed(Data(output.utf8)) }
    for event in events {
      switch event {
      case .submit(let line):
        PromptHistory.save(editor.history)
        run(line)
      case .eof:
        host?.tabWantsClose(self)
      case .interrupt:
        // Ctrl-C while editing already printed ^C; while connecting it cancels.
        if connecting != nil, remote == nil {
          cancelConnecting()
          echo("^C\r\n")
        }
        prompt()
      }
    }
  }

  func run(_ line: String) {
    switch Command.parse(line) {
    case .failure(.unknown(let name)):
      echo("\(name): command not found. Type help.\r\n")
      prompt()
    case .failure(.usage(let usage)):
      echo(usage + "\r\n")
      prompt()
    case .failure(.unterminatedQuote):
      echo("Unterminated quote.\r\n")
      prompt()
    case .success(let command):
      run(command)
    }
  }

  private func run(_ command: Command) {
    switch command {
    case .empty:
      prompt()
    case .help:
      echo(Self.help)
      prompt()
    case .clear:
      local.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8))
      prompt()
    case .hosts:
      echo(Self.hostList(ConfigStore.shared.hosts))
      prompt()
    case .config:
      host?.tabWantsSettings(self)
      prompt()
    case .exit:
      host?.tabWantsClose(self)
    case .testpage:
      current.feed(Data(TestPage.bytes))
      prompt()
    case .connect(let request):
      switch request.resolve(in: ConfigStore.shared.hosts) {
      case .success(let target):
        connect(target)
      case .failure(.needsUser(let name)):
        echo("No saved host \(name). Use user@\(name), or add it with config.\r\n")
        prompt()
      }
    case .tmux(let name, let session):
      guard let saved = ConfigStore.shared.host(alias: name) else {
        echo("No saved host \(name). Add it with config.\r\n")
        prompt()
        return
      }
      if let session {
        var target = saved
        target.startupCommand = Tmux.attachCommand(session)
        connect(target, tmuxSession: session)
      } else {
        host?.tabWantsTmuxPicker(self, host: saved)
        prompt()
      }
    }
  }

  /// Fits 50 columns: the iPhone's width at the default text size.
  static let help = """
    \u{1b}[1mCommands\u{1b}[0m\r
      mosh [user@]host [-- cmd]  connect with mosh\r
      ssh [user@]host [cmd]      connect with ssh\r
      tmux host [session]        pick a tmux session\r
      hosts                      list saved hosts\r
      config                     settings, hosts, keys\r
      clear                      clear the screen\r
      exit                       close this shell\r
    \r
    \u{1b}[1mGestures\u{1b}[0m\r
      two-finger tap     new shell\r
      swipe left/right   switch shells\r
      three-finger tap   menu\r
      pinch              text size\r

    """

  static func hostList(_ hosts: [Host]) -> String {
    guard !hosts.isEmpty else { return "No saved hosts. Add one with config.\r\n" }
    let width = hosts.map(\.alias.count).max() ?? 0
    return hosts.map { h in
      let pad = String(repeating: " ", count: width - h.alias.count)
      let port = h.port == 22 ? "" : ":\(h.port)"
      return "  \u{1b}[1m\(h.alias)\u{1b}[0m\(pad)  \(h.user)@\(h.hostname)\(port)  \(h.transport.rawValue)\r\n"
    }.joined()
  }
}
