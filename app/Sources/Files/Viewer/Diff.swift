import Foundation

/// One row of a unified diff as the viewer draws it.
struct DiffLine: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// `@@ -a,b +c,d @@`
    case hunk
    case context, added, removed
    /// "\ No newline at end of file", "Binary files differ", "new file mode".
    case note
  }

  var kind: Kind
  var text: String
  /// 1-based line numbers in the old and new file.
  var old: Int?
  var new: Int?
}

/// `git diff` output for one file, as rows. The file header (diff --git,
/// index, ---, +++) is dropped; inside a hunk every line is content, so a
/// removed "-- x" (printed "--- x") stays a removed line.
enum UnifiedDiff {
  static func parse(_ text: String) -> [DiffLine] {
    var rows: [DiffLine] = []
    var old = 0, new = 0, oldLeft = 0, newLeft = 0
    for line in text.splitLines(omittingEmpty: false) {
      if oldLeft > 0 || newLeft > 0 {
        switch line.first {
        case " ", nil:
          rows.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: old, new: new))
          old += 1; new += 1; oldLeft -= 1; newLeft -= 1
          continue
        case "-":
          rows.append(DiffLine(kind: .removed, text: String(line.dropFirst()), old: old, new: nil))
          old += 1; oldLeft -= 1
          continue
        case "+":
          rows.append(DiffLine(kind: .added, text: String(line.dropFirst()), old: nil, new: new))
          new += 1; newLeft -= 1
          continue
        case "\\":
          rows.append(DiffLine(kind: .note, text: String(line.dropFirst().drop { $0 == " " })))
          continue
        default:
          oldLeft = 0; newLeft = 0
        }
      }
      if let hunk = Hunk(line) {
        (old, oldLeft, new, newLeft) = (hunk.old, hunk.oldCount, hunk.new, hunk.newCount)
        rows.append(DiffLine(kind: .hunk, text: String(line)))
      } else if line.hasPrefix("\\") {
        rows.append(DiffLine(kind: .note, text: String(line.dropFirst().drop { $0 == " " })))
      } else if line.hasPrefix("Binary files") || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") {
        rows.append(DiffLine(kind: .note, text: String(line)))
      }
    }
    return rows
  }

  /// `@@ -old[,count] +new[,count] @@ heading`
  private struct Hunk {
    var old, oldCount, new, newCount: Int

    init?(_ line: Substring) {
      guard line.hasPrefix("@@ -") else { return nil }
      let fields = line.dropFirst(3).split(separator: " ", maxSplits: 2)
      guard fields.count >= 2, fields[0].first == "-", fields[1].first == "+",
            let (old, oldCount) = Self.range(fields[0].dropFirst()),
            let (new, newCount) = Self.range(fields[1].dropFirst()) else { return nil }
      (self.old, self.oldCount, self.new, self.newCount) = (old, oldCount, new, newCount)
    }

    private static func range(_ s: Substring) -> (Int, Int)? {
      let parts = s.split(separator: ",", omittingEmptySubsequences: false)
      guard let start = Int(parts[0]) else { return nil }
      if parts.count == 1 { return (start, 1) }
      guard parts.count == 2, let count = Int(parts[1]) else { return nil }
      return (start, count)
    }
  }
}

/// A unified diff computed here, for two texts that are not both on disk
/// (the host's copy of a file against the unsaved one in the editor).
enum LineDiff {
  /// Hunks turning `old` into `new` with `context` unchanged lines around each
  /// change, numbered and headed as `diff -u` does.
  static func unified(old: String, new: String, context: Int = 3) -> [DiffLine] {
    let a = lines(old), b = lines(new)
    let difference = b.difference(from: a)
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    // Walk both sides: unchanged lines pair up in order between the changes.
    var ops: [DiffLine] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
      if i < a.count, removed.contains(i) {
        ops.append(DiffLine(kind: .removed, text: a[i], old: i + 1, new: nil)); i += 1
      } else if j < b.count, inserted.contains(j) {
        ops.append(DiffLine(kind: .added, text: b[j], old: nil, new: j + 1)); j += 1
      } else {
        ops.append(DiffLine(kind: .context, text: a[i], old: i + 1, new: j + 1)); i += 1; j += 1
      }
    }
    let changes = ops.indices.filter { ops[$0].kind != .context }
    guard var start = changes.first else { return [] }
    var rows: [DiffLine] = []
    var end = start
    func flush() {
      let lo = max(0, start - context), hi = min(ops.count - 1, end + context)
      let slice = ops[lo...hi]
      let oldCount = slice.filter { $0.kind != .added }.count
      let newCount = slice.filter { $0.kind != .removed }.count
      // diff -u numbers an empty side by the line before it.
      let oldStart = (slice.first { $0.old != nil }?.old ?? ops[..<lo].compactMap(\.old).last.map { $0 + 1 } ?? 1)
      let newStart = (slice.first { $0.new != nil }?.new ?? ops[..<lo].compactMap(\.new).last.map { $0 + 1 } ?? 1)
      rows.append(DiffLine(kind: .hunk, text: "@@ -\(Self.range(oldStart, oldCount)) +\(Self.range(newStart, newCount)) @@"))
      rows.append(contentsOf: slice)
    }
    for index in changes.dropFirst() {
      // diff -u joins two changes whose unchanged lines between fit both contexts.
      if index - end - 1 > 2 * context {
        flush()
        start = index
      }
      end = index
    }
    flush()
    return rows
  }

  private static func range(_ start: Int, _ count: Int) -> String {
    switch count {
    case 0: "\(start - 1),0"
    case 1: "\(start)"
    default: "\(start),\(count)"
    }
  }

  /// Lines without their breaks; a final line break does not start another line.
  static func lines(_ text: String) -> [String] {
    var lines = text.splitLines(omittingEmpty: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }
}

/// Rows of `xxd`-style hex: offset, bytes in groups of eight, then the bytes
/// as ASCII ("." for anything unprintable). A short last row is padded so its
/// ASCII column lines up.
enum HexDump {
  static func rows(_ data: Data, width: Int) -> [String] {
    let bytes = [UInt8](data)
    let digits = Array("0123456789abcdef")
    return stride(from: 0, to: bytes.count, by: width).map { start in
      let row = bytes[start..<min(start + width, bytes.count)]
      var line = String(String(start, radix: 16).leftPadded(to: 8))
      line += " "
      for column in 0..<width {
        if column % 8 == 0 { line += " " }
        if column < row.count {
          let byte = row[row.startIndex + column]
          line.append(digits[Int(byte >> 4)])
          line.append(digits[Int(byte & 0xF)])
          line += " "
        } else {
          line += "   "
        }
      }
      line += " "
      line += String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
      return line
    }
  }
}

private extension String {
  func leftPadded(to width: Int) -> String {
    count >= width ? self : String(repeating: "0", count: width - count) + self
  }
}

extension String {
  /// Lines split at "\n" and "\r\n". Swift reads "\r\n" as one Character, so
  /// splitting at "\n" alone would leave CRLF text in one piece.
  func splitLines(omittingEmpty: Bool) -> [Substring] {
    split(omittingEmptySubsequences: omittingEmpty) { $0 == "\n" || $0 == "\r\n" }
  }
}
