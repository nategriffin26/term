import Foundation
@testable import Term

/// A real terminal (the core's VT, not a model of one) that tests feed bytes
/// and read the screen back from, so redraw output is judged by what the
/// user would see.
@MainActor
final class VTScreen {
  let session: Session
  private(set) var cols: Int
  let rows: Int

  init(cols: Int, rows: Int = 12) {
    session = Session(localCols: cols, rows: rows)!
    self.cols = cols
    self.rows = rows
  }

  func feed(_ text: String) { session.feed(text) }

  func resize(cols: Int) {
    self.cols = cols
    session.resize(cols: cols, rows: rows, cellWidth: 8, cellHeight: 16)
  }

  /// Screen rows as the grid holds them (a wide character that wrapped stays
  /// on the row it landed on), trailing blanks and blank rows dropped.
  var lines: [String] {
    var f = TermFrame()
    _ = session.frame(after: .max, into: &f)
    var snap = FrameSnapshot()
    snap.load(f)
    var out: [String] = (0..<snap.rows).map { r in
      var row = ""
      for c in 0..<snap.cols {
        let i = r * snap.cols + c
        if snap.cells[i].flags & UInt16(TERM_CELL_SPACER) != 0 { continue }
        let scalars = snap.scalars(at: i)
        row += scalars.isEmpty ? " " : String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
      }
      return row.replacing(/\s+$/, with: "")
    }
    while out.last == "" { out.removeLast() }
    return out
  }

  var cursor: (col: Int, row: Int) {
    var f = TermFrame()
    _ = session.frame(after: .max, into: &f)
    return (Int(f.cursor_col), Int(f.cursor_row))
  }
}

/// A `LineEditor` wired to a `VTScreen` the way `Tab` wires it to its local session.
@MainActor
struct PromptHarness {
  var editor: LineEditor
  let screen: VTScreen
  private(set) var events: [LineEditor.Event] = []

  static let prompt = "term> "

  init(cols: Int = 40, history: [String] = [], historyLimit: Int = 500,
       completer: @escaping LineEditor.Completer = { _ in (0, []) }) {
    screen = VTScreen(cols: cols)
    editor = LineEditor(prompt: Self.prompt, style: "\u{1b}[1;34m", cols: cols, history: history,
                        historyLimit: historyLimit, completer: completer)
    screen.feed(editor.begin())
  }

  mutating func begin() { screen.feed(editor.begin()) }

  mutating func send(_ bytes: [UInt8]) {
    let (output, new) = editor.feed(bytes)
    screen.feed(output)
    events += new
  }

  mutating func type(_ text: String) { send(Array(text.utf8)) }

  mutating func resize(cols: Int) {
    screen.resize(cols: cols)
    screen.feed(editor.setColumns(cols))
  }

  mutating func takeEvents() -> [LineEditor.Event] {
    defer { events = [] }
    return events
  }

  var line: String { editor.text }
  var cursor: Int { editor.cursor }
}

enum Key {
  static let left = "\u{1b}[D", right = "\u{1b}[C", up = "\u{1b}[A", down = "\u{1b}[B"
  static let home = "\u{1b}[H", end = "\u{1b}[F", delete = "\u{1b}[3~"
  static let ctrlLeft = "\u{1b}[1;5D", ctrlRight = "\u{1b}[1;5C"
  static let altBackspace = "\u{1b}\u{7f}"
  static let enter = "\r", backspace = "\u{7f}", tab = "\t"
  static let ctrlA = "\u{01}", ctrlB = "\u{02}", ctrlC = "\u{03}", ctrlD = "\u{04}", ctrlE = "\u{05}"
  static let ctrlF = "\u{06}", ctrlK = "\u{0b}", ctrlL = "\u{0c}", ctrlN = "\u{0e}", ctrlP = "\u{10}"
  static let ctrlU = "\u{15}", ctrlW = "\u{17}"
  static func paste(_ text: String) -> String { "\u{1b}[200~" + text + "\u{1b}[201~" }
}
