import SwiftUI
import UIKit

/// A tmux pane's history as a native, scrollable, selectable terminal:
/// `capture-pane` output fed into a local session the TerminalView renders,
/// under a header with the session's name and a close button.
@MainActor
final class HistoryViewController: UIViewController {
  private let host: Host
  private let tmuxSession: String?
  private var session: Session?
  private let header: UIHostingController<HistoryHeader>
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let message = UILabel()

  init(host: Host, tmuxSession: String?) {
    self.host = host
    self.tmuxSession = tmuxSession
    header = UIHostingController(rootView: HistoryHeader(title: tmuxSession ?? host.alias, close: {}))
    super.init(nibName: nil, bundle: nil)
    header.rootView = HistoryHeader(title: tmuxSession ?? host.alias) { [weak self] in self?.dismiss(animated: true) }
    header.safeAreaRegions = []
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    AppSettings.shared.theme.isDark ? .lightContent : .darkContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = AppSettings.shared.theme.backgroundColor

    addChild(header)
    header.view.backgroundColor = .clear
    header.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header.view)
    header.didMove(toParent: self)

    message.numberOfLines = 0
    message.textAlignment = .center
    message.font = Chrome.uiFont(.body)
    message.textColor = Chrome.UI.fg2
    message.isHidden = true
    spinner.color = Chrome.UI.muted
    spinner.startAnimating()
    for v in [spinner, message] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }
    NSLayoutConstraint.activate([
      header.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      header.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      header.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      header.view.heightAnchor.constraint(equalToConstant: HistoryHeader.height),
      spinner.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      message.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      message.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Chrome.Space.xl),
      message.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Chrome.Space.xl),
    ])

    Task { await load() }
  }

  private func load() async {
    let result = await RemoteExec.run(Tab.spec(for: host), Tmux.historyCommand(tmuxSession))
    spinner.stopAnimating()
    switch result {
    case .failure(let failure):
      show(failure.message)
    case .success(let output) where output.status != 0:
      show("tmux exited with status \(output.status).")
    case .success(let output):
      showHistory(output.stdout)
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
    session.diagrams = DiagramSource(host: host, tmuxSession: tmuxSession)
    let terminal = TerminalView(session: session)
    terminal.fontFamily = settings.fontFamily
    terminal.fontSize = CGFloat(settings.fontSize)
    terminal.lineSpacing = CGFloat(settings.lineSpacing)
    terminal.cursorBlinkEnabled = false
    terminal.isReadOnly = true
    terminal.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(terminal)
    NSLayoutConstraint.activate([
      terminal.topAnchor.constraint(equalTo: header.view.bottomAnchor),
      terminal.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
    ])
    view.layoutIfNeeded()
    session.feed(Self.terminalBytes(captured))
    self.session = session
  }

  /// capture-pane ends lines with LF only; the terminal needs CR LF. The
  /// cursor is hidden: this is a page to read, not a prompt.
  static func terminalBytes(_ captured: Data) -> Data {
    var out = Data(capacity: captured.count + captured.count / 40 + 8)
    for byte in captured {
      if byte == 0x0A { out.append(0x0D) }
      out.append(byte)
    }
    out.append(contentsOf: Array("\u{1b}[?25l".utf8))
    return out
  }
}

/// The viewer's header: the session's name over the terminal's ground and
/// a close button, laid out like a menu page's header.
struct HistoryHeader: View {
  static let height: CGFloat = 52
  let title: String
  let close: () -> Void

  var body: some View {
    ZStack {
      Text(title)
        .font(Chrome.mono(.title, .semibold))
        .foregroundStyle(Chrome.fg)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, Chrome.Size.target + Chrome.Space.m)
      HStack {
        Spacer()
        CircleButton(symbol: "xmark", label: "Close", action: close)
      }
    }
    .padding(.horizontal, Chrome.Space.s)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
