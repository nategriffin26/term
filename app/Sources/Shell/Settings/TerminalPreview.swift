import SwiftUI
import UIKit

/// The terminal appearance pages' pinned preview: a live terminal drawn
/// with the current settings, ending on a prompt with the cursor over a glyph.
struct TerminalPreview: UIViewRepresentable {
  func makeUIView(context: Context) -> PreviewView { PreviewView() }
  func updateUIView(_ view: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
  /// Colours, styles, Powerline and Nerd Font glyphs; the cursor ends over the "s".
  static let sample = [
    "\u{1b}[1;34mterm>\u{1b}[0m ls\r\n",
    "\u{1b}[1;34mProjects\u{1b}[0m  \u{1b}[1;32mbuild.sh\u{1b}[0m  notes.md  \u{1b}[35mphoto.png\u{1b}[0m\r\n",
    (0..<8).map { "\u{1b}[4\($0)m  " }.joined() + "\u{1b}[0m\r\n",
    (0..<8).map { "\u{1b}[10\($0)m  " }.joined() + "\u{1b}[0m\r\n",
    "\u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m\r\n",
    "\u{1b}[30;44m \u{e0a0} main \u{1b}[34;49m\u{e0b0}\u{1b}[0m \u{f07c} \u{f0e7} \u{f489}\r\n",
    "\u{1b}[1;34mterm>\u{1b}[0m git status\u{1b}[6D",
  ].joined()

  private let session = Session(localCols: 40, rows: 8)
  private let terminal: TerminalView?
  private var observer: NSObjectProtocol?

  override init(frame: CGRect) {
    terminal = session.map { TerminalView(session: $0) }
    super.init(frame: frame)
    guard let terminal, let session else { return }
    terminal.isUserInteractionEnabled = false
    terminal.isPreview = true
    terminal.frame = bounds
    terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(terminal)
    // A resize (font, size or spacing) reflows the screen; draw it again.
    session.onGridChange = { [weak self] _, _ in self?.redraw() }
    observer = NotificationCenter.default.addObserver(forName: .termSettingsChanged, object: nil, queue: .main) {
      [weak self] _ in MainActor.assumeIsolated { self?.apply() }
    }
    apply()
    redraw()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  isolated deinit { observer.map(NotificationCenter.default.removeObserver) }

  private func apply() {
    let s = AppSettings.shared
    guard let terminal, let session else { return }
    terminal.fontFamily = s.fontFamily
    terminal.fontSize = CGFloat(s.fontSize)
    terminal.lineSpacing = CGFloat(s.lineSpacing)
    terminal.cursorOverride = s.cursorOverride
    backgroundColor = s.theme.backgroundColor
    session.setTheme(s.termTheme)
  }

  private func redraw() {
    session?.feed("\u{1b}[2J\u{1b}[H" + Self.sample)
  }
}
