import Foundation

/// The last lines of a tmux session's screen that say something, for its
/// row in the tmux tab: words read at a glance, in the terminal's colours,
/// where a whole screen shrunk to a row was only a texture.
struct ScreenExcerpt: Equatable {
  /// Part of a line in one style. Colours are 0xAARRGGBB; nil is the
  /// terminal's default, drawn in the row's own ink.
  struct Run: Equatable {
    var text: String
    var fg: UInt32?
    var bg: UInt32?
    var bold = false
    var faint = false
  }

  var lines: [[Run]]

  /// Lines a row shows.
  static let lineCount = 2

  /// `count` lines of what `session` shows now.
  @MainActor init(_ session: Session, count: Int = lineCount) {
    var frame = TermFrame()
    _ = session.frame(after: .max, into: &frame)
    var screen = FrameSnapshot()
    screen.load(frame)
    self.init(screen, count: count)
  }

  /// `count` lines of `screen`, their common indent dropped, trailing blanks trimmed.
  init(_ screen: FrameSnapshot, count: Int = lineCount) {
    let cols = screen.cols
    func cell(_ row: Int, _ col: Int) -> TermCell { screen.cells[row * cols + col] }
    func blank(_ c: TermCell) -> Bool { c.ch <= 32 || c.flags & UInt16(TERM_CELL_INVISIBLE) != 0 }
    func hasWords(_ row: Int) -> Bool {
      (0..<cols).contains { col in
        let c = cell(row, col)
        return !blank(c) && Unicode.Scalar(c.ch)?.properties.isAlphabetic == true
      }
    }
    let picked = Self.rows(withWords: (0..<screen.rows).map(hasWords), cursor: screen.cursorRow, count: count)
    let indent = picked.map { row in (0..<cols).first { !blank(cell(row, $0)) } ?? cols }.min() ?? 0
    lines = picked.map { row in
      let end = ((0..<cols).last { !blank(cell(row, $0)) } ?? -1) + 1
      var runs: [Run] = []
      for col in indent..<max(end, indent) {
        let c = cell(row, col)
        if c.flags & UInt16(TERM_CELL_SPACER) != 0 { continue }
        let text = blank(c) ? " " : String(String.UnicodeScalarView(screen.scalars(at: row * cols + col).compactMap(Unicode.Scalar.init)))
        let style = Run(text: "", fg: c.fg == screen.fg ? nil : c.fg, bg: c.bg == 0 || c.bg == screen.bg ? nil : c.bg,
                        bold: c.flags & UInt16(TERM_CELL_BOLD) != 0, faint: c.flags & UInt16(TERM_CELL_FAINT) != 0)
        if var last = runs.last, last.fg == style.fg, last.bg == style.bg, last.bold == style.bold, last.faint == style.faint {
          last.text += text
          runs[runs.count - 1] = last
        } else {
          var run = style
          run.text = text
          runs.append(run)
        }
      }
      return runs
    }
  }

  /// Which rows show: those with a letter (a rule, a box edge, vim's "~"
  /// or a line number, a bare prompt say nothing), the last `count` up to
  /// the cursor's row (a prompt and the output above it, a program's latest
  /// lines), topped up from below when fewer sit above it (an editor on its
  /// first line). In screen order.
  static func rows(withWords: [Bool], cursor: Int, count: Int) -> [Int] {
    guard !withWords.isEmpty, count > 0 else { return [] }
    let cursor = min(max(cursor, 0), withWords.count - 1)
    var picked = Array((0...cursor).filter { withWords[$0] }.suffix(count))
    if picked.count < count {
      picked += (cursor + 1..<withWords.count).filter { withWords[$0] }.prefix(count - picked.count)
    }
    return picked
  }
}
