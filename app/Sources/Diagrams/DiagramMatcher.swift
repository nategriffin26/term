/// Finds omp's ASCII drawings of Mermaid diagrams in terminal rows and says
/// which published source each one is (local/diagrams/design.md §1).
///
/// A diagram row holds an arrow, box-drawing, block or geometric glyph. A
/// block is a run of diagram rows; up to two non-blank rows without a glyph
/// are bridged, because an edge label can sit on a row of its own. A block is
/// a source's drawing when at least 80% of its words begin a word of the
/// source: omp clips rows at the pane width, so a word may be cut short.
enum DiagramMatcher {
  struct Block: Equatable {
    var top: Int
    var bottom: Int
    /// Rows in it that hold a glyph (bridged label rows don't count).
    var glyphRows: Int
  }

  struct Match: Equatable {
    var top: Int
    var bottom: Int
    var hash: String
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
  }

  static let minPrecision = 0.8

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

  /// The source drawn in a block, by its words: nil when under two words or
  /// no source reaches the precision bar. Ties go to higher recall, then to
  /// the newer source.
  static func source(of seen: [String], in candidates: [Candidate]) -> String? {
    guard seen.count >= 2 else { return nil }
    let distinct = Set(seen)
    var best: (recall: Double, time: Double, hash: String)?
    for c in candidates {
      let hits = seen.reduce(0) { n, w in n + (c.vocab.contains(w) || c.vocab.contains { $0.hasPrefix(w) } ? 1 : 0) }
      guard Double(hits) / Double(seen.count) >= minPrecision else { continue }
      let recall = Double(c.vocab.intersection(distinct).count) / Double(max(1, c.vocab.count))
      if let b = best, (recall, c.time) <= (b.recall, b.time) { continue }
      best = (recall, c.time, c.hash)
    }
    return best?.hash
  }

  static func match(_ rows: [String], _ candidates: [Candidate]) -> [Match] {
    blocks(rows).compactMap { b in
      let seen = words(rows[b.top...b.bottom].joined(separator: "\n"))
      return source(of: seen, in: candidates).map { Match(top: b.top, bottom: b.bottom, hash: $0) }
    }
  }
}
