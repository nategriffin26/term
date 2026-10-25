import Foundation

/// Emacs-style line editing for the local prompt. Bytes the user typed (as the
/// core encoded them) go in; VT text to feed the local session comes out.
/// Pure state machine: no I/O, so it is tested byte for byte.
struct LineEditor {
  enum Event: Equatable {
    /// Enter: the line, already echoed and followed by CRLF. Editing stops until `begin()`.
    case submit(String)
    /// Ctrl-D on an empty line.
    case eof
    /// Ctrl-C. While editing, the line is abandoned and editing stops until `begin()`.
    case interrupt
  }

  /// Text before the cursor -> (index in that text where the completed word starts, candidates).
  typealias Completer = (String) -> (start: Int, candidates: [String])

  private(set) var line: [Character] = []
  private(set) var cursor = 0
  private(set) var isEditing = false
  private(set) var history: [String]
  private(set) var cols: Int

  private let promptText: String
  private let promptStyled: String
  private let promptWidth: Int
  private let completer: Completer
  private let historyLimit: Int

  private var historyIndex: Int?
  private var stash: [Character] = []
  /// Rows the prompt+line occupied at the last refresh, and the cursor's row among them.
  private var drawnRows = 1
  private var cursorRow = 0
  private var pending: [UInt8] = []
  private var pasting = false
  private var pasted: [UInt8] = []

  init(prompt: String, style: String = "", cols: Int = 80, history: [String] = [],
       historyLimit: Int = 500, completer: @escaping Completer = { _ in (0, []) }) {
    promptText = prompt
    promptStyled = style.isEmpty ? prompt : style + prompt + "\u{1b}[0m"
    promptWidth = Self.width(of: Array(prompt))
    self.cols = max(cols, 1)
    self.history = history
    self.historyLimit = historyLimit
    self.completer = completer
  }

  var text: String { String(line) }

  /// Starts editing a fresh line; returns the prompt to print at the cursor.
  mutating func begin() -> String {
    line = []
    cursor = 0
    historyIndex = nil
    stash = []
    pending = []
    isEditing = true
    drawnRows = 1
    cursorRow = 0
    return promptStyled
  }

  /// New terminal width. The terminal reflows the soft-wrapped prompt line, so
  /// the old layout is recomputed for the new width before redrawing.
  mutating func setColumns(_ newCols: Int) -> String {
    let newCols = max(newCols, 1)
    guard newCols != cols else { return "" }
    cols = newCols
    guard isEditing else { return "" }
    let layout = self.layout()
    drawnRows = layout.rows
    cursorRow = layout.cursorRow
    return refresh()
  }

  /// Prints `text` (lines end with "\r\n") above the prompt and redraws it below.
  mutating func printAbove(_ text: String) -> String {
    guard isEditing else { return text }
    var out = ""
    if cursorRow > 0 { out += "\u{1b}[\(cursorRow)A" }
    out += "\r\u{1b}[J" + text
    drawnRows = 1
    cursorRow = 0
    out += promptStyled
    return out + refresh(clear: false)
  }

  mutating func feed(_ bytes: some Sequence<UInt8>) -> (output: String, events: [Event]) {
    var data = pending
    data.append(contentsOf: bytes)
    pending = []
    var out = ""
    var events: [Event] = []
    var dirty = false
    var i = 0

    func flushRefresh() {
      if dirty { out += refresh(); dirty = false }
    }

    while i < data.count {
      if pasting {
        if data[i...].starts(with: Self.pasteEnd) {
          pasting = false
          i += Self.pasteEnd.count
          dirty = insert(Self.pasteText(pasted)) || dirty
          pasted = []
        } else if data[i] == 0x1B, data.count - i < Self.pasteEnd.count,
                  Self.pasteEnd.starts(with: data[i...]) {
          pending = Array(data[i...])
          break
        } else {
          pasted.append(data[i])
          i += 1
        }
        continue
      }

      let b = data[i]
      if !isEditing {
        if b == 0x03 { events.append(.interrupt) }
        i += 1
        continue
      }

      switch b {
      case 0x1B:
        guard i + 1 < data.count else { i += 1; continue }  // lone Escape key
        let next = data[i + 1]
        if next == UInt8(ascii: "[") {
          var j = i + 2
          while j < data.count, (0x20...0x3F).contains(data[j]) { j += 1 }
          guard j < data.count else { pending = Array(data[i...]); i = data.count; continue }
          let params = String(decoding: data[(i + 2)..<j], as: UTF8.self)
          dirty = csi(params: params, final: data[j]) || dirty
          i = j + 1
        } else if next == UInt8(ascii: "O") {
          guard i + 2 < data.count else { pending = Array(data[i...]); i = data.count; continue }
          dirty = csi(params: "", final: data[i + 2]) || dirty
          i += 3
        } else {
          switch next {
          case 0x7F, 0x08: dirty = deleteWordBack() || dirty
          case UInt8(ascii: "b"): dirty = move(to: wordStart(before: cursor)) || dirty
          case UInt8(ascii: "f"): dirty = move(to: wordEnd(after: cursor)) || dirty
          case UInt8(ascii: "d"): dirty = deleteWordForward() || dirty
          default: break
          }
          // Alt + a multi-byte character: swallow the whole character.
          let width = next >= 0xF0 ? 4 : next >= 0xE0 ? 3 : next >= 0xC0 ? 2 : 1
          i = min(i + 1 + width, data.count)
        }

      case 0x01: dirty = move(to: 0) || dirty; i += 1
      case 0x02: dirty = move(to: cursor - 1) || dirty; i += 1
      case 0x03:
        flushRefresh()
        out += moveToEnd() + "^C\r\n"
        isEditing = false
        events.append(.interrupt)
        i += 1
      case 0x04:
        if line.isEmpty {
          flushRefresh()
          out += "\r\n"
          isEditing = false
          events.append(.eof)
        } else if cursor < line.count {
          line.remove(at: cursor)
          dirty = true
        }
        i += 1
      case 0x05: dirty = move(to: line.count) || dirty; i += 1
      case 0x06: dirty = move(to: cursor + 1) || dirty; i += 1
      case 0x08, 0x7F:
        if cursor > 0 {
          line.remove(at: cursor - 1)
          cursor -= 1
          dirty = true
        }
        i += 1
      case 0x09:
        flushRefresh()
        out += complete()
        i += 1
      case 0x0B:
        if cursor < line.count { line.removeSubrange(cursor...); dirty = true }
        i += 1
      case 0x0C:
        out += "\u{1b}[H\u{1b}[2J" + promptStyled
        drawnRows = 1
        cursorRow = 0
        dirty = true
        i += 1
      case 0x0A, 0x0D:
        flushRefresh()
        let submitted = text
        out += moveToEnd() + "\r\n"
        isEditing = false
        remember(submitted)
        events.append(.submit(submitted))
        // CRLF from a keyboard is one Enter.
        i += (b == 0x0D && i + 1 < data.count && data[i + 1] == 0x0A) ? 2 : 1
      case 0x0E: dirty = historyStep(1) || dirty; i += 1
      case 0x10: dirty = historyStep(-1) || dirty; i += 1
      case 0x15:
        if cursor > 0 { line.removeSubrange(..<cursor); cursor = 0; dirty = true }
        i += 1
      case 0x17: dirty = deleteWordBack() || dirty; i += 1
      case 0x00...0x1F: i += 1
      default:
        let need = Self.utf8Length(lead: b)
        guard i + need <= data.count else { pending = Array(data[i...]); i = data.count; continue }
        // Take the whole run of printable bytes at once so typing fast or an
        // unbracketed paste costs one redraw.
        var j = i + need
        while j < data.count, data[j] >= 0x20, data[j] != 0x7F {
          let n = Self.utf8Length(lead: data[j])
          guard j + n <= data.count else { break }
          j += n
        }
        dirty = insert(String(decoding: data[i..<j], as: UTF8.self)) || dirty
        i = j
      }
    }
    flushRefresh()
    return (out, events)
  }

  // MARK: - Editing

  private static let pasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)

  private static func pasteText(_ bytes: [UInt8]) -> String {
    var s = String(decoding: bytes, as: UTF8.self)
    while let last = s.last, last.isNewline { s.removeLast() }
    return s.replacing(/\r\n|\r|\n|\t/, with: " ")
  }

  private static func utf8Length(lead: UInt8) -> Int {
    switch lead {
    case 0xF0...0xF7: 4
    case 0xE0...0xEF: 3
    case 0xC0...0xDF: 2
    default: 1
    }
  }

  @discardableResult
  private mutating func insert(_ s: String) -> Bool {
    let chars = s.filter { c in !c.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
    guard !chars.isEmpty else { return false }
    line.insert(contentsOf: chars, at: cursor)
    cursor += chars.count
    return true
  }

  private mutating func move(to index: Int) -> Bool {
    let clamped = min(max(index, 0), line.count)
    guard clamped != cursor else { return false }
    cursor = clamped
    return true
  }

  private func wordStart(before index: Int) -> Int {
    var i = index
    while i > 0, line[i - 1].isWhitespace { i -= 1 }
    while i > 0, !line[i - 1].isWhitespace { i -= 1 }
    return i
  }

  private func wordEnd(after index: Int) -> Int {
    var i = index
    while i < line.count, line[i].isWhitespace { i += 1 }
    while i < line.count, !line[i].isWhitespace { i += 1 }
    return i
  }

  private mutating func deleteWordBack() -> Bool {
    let start = wordStart(before: cursor)
    guard start < cursor else { return false }
    line.removeSubrange(start..<cursor)
    cursor = start
    return true
  }

  private mutating func deleteWordForward() -> Bool {
    let end = wordEnd(after: cursor)
    guard end > cursor else { return false }
    line.removeSubrange(cursor..<end)
    return true
  }

  private mutating func csi(params: String, final: UInt8) -> Bool {
    let modified = params.hasSuffix(";5") || params.hasSuffix(";3")
    switch final {
    case UInt8(ascii: "A"): return historyStep(-1)
    case UInt8(ascii: "B"): return historyStep(1)
    case UInt8(ascii: "C"): return move(to: modified ? wordEnd(after: cursor) : cursor + 1)
    case UInt8(ascii: "D"): return move(to: modified ? wordStart(before: cursor) : cursor - 1)
    case UInt8(ascii: "H"): return move(to: 0)
    case UInt8(ascii: "F"): return move(to: line.count)
    case UInt8(ascii: "~"):
      switch params {
      case "1", "7": return move(to: 0)
      case "4", "8": return move(to: line.count)
      case "3":
        guard cursor < line.count else { return false }
        line.remove(at: cursor)
        return true
      case "200":
        pasting = true
        pasted = []
        return false
      default: return false
      }
    default: return false
    }
  }

  private mutating func historyStep(_ delta: Int) -> Bool {
    guard !history.isEmpty else { return false }
    if delta < 0 {
      let current = historyIndex ?? history.count
      guard current > 0 else { return false }
      if historyIndex == nil { stash = line }
      historyIndex = current - 1
      line = Array(history[current - 1])
    } else {
      guard let current = historyIndex else { return false }
      if current + 1 >= history.count {
        historyIndex = nil
        line = stash
      } else {
        historyIndex = current + 1
        line = Array(history[current + 1])
      }
    }
    cursor = line.count
    return true
  }

  private mutating func remember(_ entry: String) {
    historyIndex = nil
    guard !entry.trimmingCharacters(in: .whitespaces).isEmpty, entry != history.last else { return }
    history.append(entry)
    if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
  }

  private mutating func complete() -> String {
    let before = String(line[..<cursor])
    let (start, candidates) = completer(before)
    guard !candidates.isEmpty else { return "" }
    let word = String(before.dropFirst(start))
    if candidates.count == 1 {
      let suffix = String(candidates[0].dropFirst(word.count)) + " "
      insert(suffix)
      return refresh()
    }
    let common = candidates.dropFirst().reduce(candidates[0]) { $0.commonPrefix(with: $1) }
    if common.count > word.count {
      insert(String(common.dropFirst(word.count)))
      return refresh()
    }
    let listing = candidates.joined(separator: "  ") + "\r\n"
    return printAbove(listing)
  }

  // MARK: - Drawing

  /// Where each part of prompt+line lands with the current width. Rows are
  /// relative to the prompt's first row; a full last row leaves the terminal
  /// in pending-wrap state at column `cols`.
  private func layout() -> (rows: Int, cursorRow: Int, cursorCol: Int, endRow: Int, endCol: Int) {
    var row = 0
    var col = 0
    func advance(_ w: Int) {
      if col + w > cols { row += 1; col = 0 }
      col += w
    }
    for c in promptText { advance(Self.width(of: c)) }
    var cursorPos = (row, col)
    for (i, c) in line.enumerated() {
      if i == cursor { cursorPos = (row, col) }
      let w = Self.width(of: c)
      // The cursor sits on the cell where this character is drawn.
      if i == cursor, col + w > cols { cursorPos = (row + 1, 0) }
      advance(w)
    }
    if cursor == line.count { cursorPos = (row, col) }
    var (cr, cc) = cursorPos
    if cc >= cols { cr += 1; cc = 0 }
    let rows = max(row + 1, cr + 1)
    return (rows, cr, cc, row, col)
  }

  /// Redraws prompt and line in place (linenoise's multi-line refresh).
  private mutating func refresh(clear: Bool = true) -> String {
    var out = ""
    if clear {
      if drawnRows - 1 - cursorRow > 0 { out += "\u{1b}[\(drawnRows - 1 - cursorRow)B" }
      for _ in 0..<max(drawnRows - 1, 0) { out += "\r\u{1b}[0K\u{1b}[1A" }
      out += "\r\u{1b}[0K" + promptStyled
    }
    out += String(line)
    let l = layout()
    var row = l.endRow
    if l.endCol >= cols, cursor == line.count {
      // Leave pending-wrap so the cursor shows on the next row.
      out += "\n\r"
      row += 1
    }
    if row - l.cursorRow > 0 { out += "\u{1b}[\(row - l.cursorRow)A" }
    out += l.cursorCol > 0 ? "\r\u{1b}[\(l.cursorCol)C" : "\r"
    drawnRows = max(l.rows, row + 1)
    cursorRow = l.cursorRow
    return out
  }

  /// Moves the terminal cursor below the last row of the line.
  private func moveToEnd() -> String {
    let down = drawnRows - 1 - cursorRow
    return down > 0 ? "\u{1b}[\(down)B" : ""
  }

  // MARK: - Width

  static func width(of chars: [Character]) -> Int {
    chars.reduce(0) { $0 + width(of: $1) }
  }

  /// Terminal cell width: 2 for East Asian wide and emoji presentation, else 1.
  static func width(of c: Character) -> Int {
    guard let s = c.unicodeScalars.first else { return 0 }
    if c.unicodeScalars.contains(where: { $0.value == 0xFE0F }) || s.properties.isEmojiPresentation {
      return 2
    }
    switch s.value {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
      return 2
    default:
      return 1
    }
  }
}
