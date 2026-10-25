import Foundation

/// How a file indents, read from its leading whitespace so Tab and new lines
/// continue the file's own style.
enum Indentation: Equatable, Sendable {
  case tabs
  case spaces(Int)

  /// What one level of indentation inserts.
  var unit: String {
    switch self {
    case .tabs: "\t"
    case .spaces(let n): String(repeating: " ", count: n)
    }
  }

  /// The file's style, or nil when no line is indented. Tabs win when more
  /// lines start with a tab than with spaces. A space width is the step by
  /// which indentation most often grows from one line to the next: only
  /// increases count (one block opens at a time, but several can close at
  /// once), and a 1-space step (` * ` comment continuations) is not a level.
  static func detect(_ text: String, maxLines: Int = 5000) -> Indentation? {
    var tabLines = 0
    var spaceLines = 0
    var steps: [Int: Int] = [:]
    var previous = 0
    var scanned = 0
    for line in text.splitLines(omittingEmpty: true) {
      scanned += 1
      if scanned > maxLines { break }
      guard let first = line.first(where: { $0 != " " && $0 != "\t" }), first != "\r" else { continue }
      if line.first == "\t" {
        tabLines += 1
        continue
      }
      let spaces = line.prefix { $0 == " " }.count
      if line.dropFirst(spaces).first == "\t" { continue }
      if spaces > 0 { spaceLines += 1 }
      if spaces > previous + 1 { steps[spaces - previous, default: 0] += 1 }
      previous = spaces
    }
    if tabLines > 0, tabLines >= spaceLines { return .tabs }
    let best = steps.filter { (2...8).contains($0.key) }
      .max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
    return best.map { .spaces($0.key) }
  }
}

/// The line break a file uses, so new lines match it.
enum LineBreak: Equatable, Sendable {
  case lf, crlf

  /// CRLF when more lines end in "\r\n" than in a bare "\n".
  static func detect(_ text: String) -> LineBreak {
    var crlf = 0
    var lf = 0
    var afterCR = false
    for unit in text.utf8 {
      if unit == 0x0A {
        if afterCR { crlf += 1 } else { lf += 1 }
      }
      afterCR = unit == 0x0D
    }
    return crlf > lf ? .crlf : .lf
  }
}

/// What Return and closing brackets insert, so code keeps its shape on
/// every language (most bundled grammars carry no indentation rules).
enum AutoIndent {
  private static let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]

  /// Return with `before`/`after` the current line's text on each side of
  /// the caret: the break, the line's indentation, and one more level after
  /// an opening bracket (or a colon, where `colonOpens`). Between a bracket
  /// and its closer the closer moves to a line of its own. `caret` is where
  /// the caret lands, in UTF-16 units into `text`.
  static func lineBreak(before: String, after: String, unit: String, newline: String, colonOpens: Bool)
    -> (text: String, caret: Int)
  {
    let indent = String(before.prefix { $0 == " " || $0 == "\t" })
    let last = before.last { $0 != " " && $0 != "\t" }
    let opens = last.map { pairs[$0] != nil || (colonOpens && $0 == ":") } ?? false
    guard opens else {
      let text = newline + indent
      return (text, text.utf16.count)
    }
    let first = newline + indent + unit
    if let last, let closer = pairs[last], after.first(where: { $0 != " " && $0 != "\t" }) == closer {
      return (first + newline + indent, first.utf16.count)
    }
    return (first, first.utf16.count)
  }

  /// Typing a closing bracket on a line of only indentation steps back one
  /// level: the replacement for that indentation and the bracket, or nil to
  /// type it as is.
  static func closer(_ typed: String, before: String, unit: String) -> String? {
    guard typed.count == 1, let c = typed.first, pairs.values.contains(c),
          !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }), before.hasSuffix(unit) else { return nil }
    return String(before.dropLast(unit.count)) + typed
  }
}
