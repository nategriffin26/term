/// Finds omp's ASCII drawings of Mermaid diagrams in terminal rows and says
/// which published source each one is (local/diagrams/design.md §1).
///
/// A diagram row holds an arrow, box-drawing, block or geometric glyph. A
/// block is a run of diagram rows; up to two non-blank rows without a glyph
/// are bridged, because an edge label can sit on a row of its own. A block is
/// a source's drawing when at least 80% of its words begin a word of the
/// source: omp clips rows at the pane width, so a word may be cut short. Up to
/// two rows at either edge whose words mostly aren't the source's (tmux's
/// status line right above a drawing) are left out, and the drawing is taken
/// to go on behind them.
enum DiagramMatcher {
  struct Block: Equatable {
    var top: Int
    var bottom: Int
    /// Rows in it that hold a glyph (bridged label rows don't count).
    var glyphRows: Int

    /// The rows `drawn` covers of this block. On a screen `rows` tall it may
    /// go on past either edge; on a whole page (`rows` nil) it ends where it ends.
    func match(_ drawn: Drawn, screenRows rows: Int?) -> Match {
      Match(top: top + drawn.trimTop, bottom: bottom - drawn.trimBottom, hash: drawn.hash,
            openTop: rows != nil && (top == 0 || drawn.trimTop > 0),
            openBottom: rows.map { bottom == $0 - 1 || drawn.trimBottom > 0 } ?? false)
    }
  }

  /// A source's drawing on screen, and whether it may go on past either edge
  /// (off screen, or behind a status line).
  struct Match: Equatable {
    var top: Int
    var bottom: Int
    var hash: String
    var openTop = false
    var openBottom = false
  }

  /// The source a block draws, and the rows at its edges that aren't part of it.
  struct Drawn: Equatable {
    var hash: String
    var trimTop = 0
    var trimBottom = 0
  }

  /// A published source, its words ready for matching.
  struct Candidate {
    var hash: String
    var time: Double
    var vocab: Set<String>

    init(hash: String, time: Double, source: String) {
      self.hash = hash
      self.time = time
      vocab = Set(DiagramMatcher.words(source))
    }

    /// At least `minPrecision` of `seen` begin a word of the source (none seen: yes).
    func covers(_ seen: [String]) -> Bool {
      let hits = seen.reduce(0) { n, w in n + (vocab.contains(w) || vocab.contains { $0.hasPrefix(w) } ? 1 : 0) }
      return seen.isEmpty || Double(hits) / Double(seen.count) >= minPrecision
    }
  }

  static let minPrecision = 0.8
  /// Edge rows at most left out of a drawing, at each edge.
  static let maxTrim = 2
  /// Fewest glyph rows in a drawing: omp's composer (two rules around the
  /// prompt) is not one, however its title reads.
  static let minGlyphRows = 3

  /// U+2190–21FF arrows, U+2500–259F box drawing and blocks, U+25A0–25FF geometric shapes.
  static func isGlyph(_ v: UInt32) -> Bool {
    (0x2190...0x21FF).contains(v) || (0x2500...0x25FF).contains(v)
  }

  static func hasGlyph(_ row: String) -> Bool {
    row.unicodeScalars.contains { isGlyph($0.value) }
  }

  static func blocks(_ rows: [String]) -> [Block] {
    var out: [Block] = []
    var start: Int?
    var last = 0, gap = 0, glyphRows = 0
    for i in 0...rows.count {
      let row = i < rows.count ? rows[i] : ""
      if hasGlyph(row) {
        if start == nil { start = i; glyphRows = 0 }
        last = i
        gap = 0
        glyphRows += 1
      } else if let top = start {
        if gap < 2, row.contains(where: { !$0.isWhitespace }) {
          gap += 1
        } else {
          out.append(Block(top: top, bottom: last, glyphRows: glyphRows))
          start = nil
          gap = 0
        }
      }
    }
    return out
  }

  /// Mermaid that omp printed as source, because its ASCII renderer lacks the
  /// type: the rows from a "```mermaid" line through the closing "```", or
  /// through the last row when the close is not in `rows` yet.
  static func sourceBlocks(_ rows: [String]) -> [Block] {
    var out: [Block] = []
    var open: Int?
    for (i, row) in rows.enumerated() {
      let text = row.trimmingCharacters(in: .whitespaces)
      if let top = open {
        if text == "```" {
          out.append(Block(top: top, bottom: i, glyphRows: 0))
          open = nil
        }
      } else if text == "```mermaid" {
        open = i
      }
    }
    if let top = open, top < rows.count - 1 { out.append(Block(top: top, bottom: rows.count - 1, glyphRows: 0)) }
    return out
  }

  /// Lowercased ASCII words of two or more characters: a letter or digit,
  /// then letters, digits and `_-.@`, without trailing `.` or `-`.
  static func words(_ text: some StringProtocol) -> [String] {
    var out: [String] = []
    var word: [UInt8] = []
    func flush() {
      while let c = word.last, c == UInt8(ascii: ".") || c == UInt8(ascii: "-") { word.removeLast() }
      if word.count >= 2 { out.append(String(decoding: word, as: UTF8.self)) }
      word.removeAll(keepingCapacity: true)
    }
    for c in text.utf8 {
      let lower = c | 0x20
      let alnum = (lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
      if alnum {
        word.append(c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") ? lower : c)
      } else if !word.isEmpty, c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: "@") {
        word.append(c)
      } else {
        flush()
      }
    }
    flush()
    return out
  }

  /// The source a block's rows draw, by their words: nil when under two words
  /// or no source reaches the precision bar. Ties go to higher recall, then to
  /// the newer source.
  static func drawn(_ rows: some Collection<String>, in candidates: [Candidate]) -> Drawn? {
    let lines = rows.map { words($0) }
    guard !lines.isEmpty else { return nil }
    var best: (recall: Double, time: Double, drawn: Drawn)?
    for c in candidates {
      var top = 0, bottom = lines.count - 1
      while top < min(maxTrim, bottom), !c.covers(lines[top]) { top += 1 }
      while bottom > max(top, lines.count - 1 - maxTrim), !c.covers(lines[bottom]) { bottom -= 1 }
      let seen = Array(lines[top...bottom].joined())
      guard seen.count >= 2, c.covers(seen) else { continue }
      let recall = Double(c.vocab.intersection(seen).count) / Double(max(1, c.vocab.count))
      if let b = best, (recall, c.time) <= (b.recall, b.time) { continue }
      best = (recall, c.time, Drawn(hash: c.hash, trimTop: top, trimBottom: lines.count - 1 - bottom))
    }
    return best?.drawn
  }

  /// Every drawing and source-text block in `rows` that a candidate draws.
  /// `screen`: the rows are a screen, whose drawings may go on past its edges.
  static func match(_ rows: [String], _ candidates: [Candidate], screen: Bool = true) -> [Match] {
    let edge = screen ? rows.count : nil
    let drawings = blocks(rows).filter { $0.glyphRows >= minGlyphRows }.compactMap { b in
      drawn(rows[b.top...b.bottom], in: candidates).map { b.match($0, screenRows: edge) }
    }
    let sources = sourceBlocks(rows).compactMap { b in
      drawn(rows[b.top + 1...b.bottom], in: candidates).map {
        Match(top: b.top, bottom: b.bottom, hash: $0.hash, openTop: false, openBottom: edge != nil && b.bottom == rows.count - 1)
      }
    }
    return (drawings + sources).sorted { $0.top < $1.top }
  }
}
