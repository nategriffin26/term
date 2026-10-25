import UIKit

/// A herdr pane's history as a native, scrollable, selectable terminal:
/// `herdr pane read` output fed into a local session the TerminalView renders.
@MainActor
final class HistoryViewController: UIViewController {
  private let host: Host
  private let pane: Herdr.Pane?
  private var session: Session?
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let message = UILabel()

  init(host: Host, pane: Herdr.Pane?) {
    self.host = host
    self.pane = pane
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    let settings = AppSettings.shared
    title = pane?.sessionName ?? host.alias
    view.backgroundColor = settings.theme.backgroundColor
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })

    message.numberOfLines = 0
    message.textAlignment = .center
    message.textColor = .secondaryLabel
    message.isHidden = true
    spinner.startAnimating()
    for v in [spinner, message] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      message.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      message.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      message.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
    ])

    Task { await load() }
  }

  private func load() async {
    guard let pane else {
      spinner.stopAnimating()
      show("This session is not a herdr pane, so there is no history to read.")
      return
    }
    let result = await Herdr.run(Herdr.historyCommand(pane.id), on: host, Herdr.parseHistory)
    spinner.stopAnimating()
    switch result {
    case .failure(let failure): show(failure.message(host: host.alias))
    case .success(let text): showHistory(text)
    }
  }

  private func show(_ text: String) {
    message.text = text
    message.isHidden = false
  }

  private func showHistory(_ captured: Data) {
    guard let session = Session(localCols: 80, rows: 24) else {
      show("The terminal core did not start.")
      return
    }
    let settings = AppSettings.shared
    session.setTheme(settings.termTheme)
    let terminal = TerminalView(session: session)
    terminal.fontFamily = settings.fontFamily
    terminal.fontSize = CGFloat(settings.fontSize)
    terminal.cursorBlinkEnabled = false
    terminal.isReadOnly = true
    terminal.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(terminal)
    NSLayoutConstraint.activate([
      terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      terminal.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
    ])
    view.layoutIfNeeded()
    session.feed(Self.terminalBytes(captured))
    self.session = session
  }

  /// Lines need CR LF; herdr already sends it, a bare LF gets its CR. The
  /// cursor is hidden: this is a page to read, not a prompt.
  static func terminalBytes(_ captured: Data) -> Data {
    var out = Data(capacity: captured.count + captured.count / 40 + 8)
    var previous: UInt8 = 0
    for byte in captured {
      if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
      out.append(byte)
      previous = byte
    }
    out.append(contentsOf: Array("\u{1b}[?25l".utf8))
    return out
  }
}
