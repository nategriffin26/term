import SwiftUI
import UIKit

/// The terminal appearance pages' pinned preview: a live terminal drawn
/// with the current settings, ending on a prompt with the cursor.
struct TerminalPreview: UIViewRepresentable {
  func makeUIView(context: Context) -> PreviewView { PreviewView() }
  func updateUIView(_ view: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
  /// A prompt with a Nerd Font glyph, a coloured listing, the styles, the cursor.
  static let sample = [
    prompt + "ls\r\n",
    "\u{1b}[1;34msrc/\u{1b}[0m  \u{1b}[1;34mtests/\u{1b}[0m  \u{1b}[32mbuild.rs\u{1b}[0m  \u{1b}[33mREADME.md\u{1b}[0m\r\n",
    "\u{1b}[1mbold\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m\r\n",
    prompt,
  ].joined()
  /// The sample's lines, which the preview is sized to show.
  static let lines = 4

  private static let prompt = "\u{1b}[34m~/api\u{1b}[0m \u{1b}[35m\u{e0a0} main\u{1b}[0m \u{1b}[32m❯\u{1b}[0m "

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
