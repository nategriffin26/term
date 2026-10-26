/// Vocabulary matching belongs off the display thread. Each overlay submits at
/// most one screen at a time and replaces pending work with its latest screen.
actor DiagramMatching {
  struct Result: Sendable {
    var matches: [DiagramMatcher.Match]
    var unmatched: Set<String>
  }

  func scan(_ rows: [String], candidates: [DiagramMatcher.Candidate], screen: Bool) -> Result {
    var matches: [DiagramMatcher.Match] = []
    var unmatched: Set<String> = []
    let edge = screen ? rows.count : nil
    func miss(_ block: DiagramMatcher.Block) {
      let first = max(block.top, 1), last = min(block.bottom, rows.count - 2)
      guard first <= last else { return }
      let words = Set(DiagramMatcher.words(rows[first...last].joined(separator: "\n")))
      if words.count >= 2 { unmatched.insert(words.sorted().joined(separator: " ")) }
    }
    for block in DiagramMatcher.blocks(rows) where block.glyphRows >= DiagramMatcher.minGlyphRows {
      if let drawn = DiagramMatcher.drawn(rows[block.top...block.bottom], in: candidates) {
        matches.append(block.match(drawn, screenRows: edge))
      } else {
        miss(block)
      }
    }
    for block in DiagramMatcher.sourceBlocks(rows) {
      if let drawn = DiagramMatcher.drawn(rows[block.top + 1...block.bottom], in: candidates) {
        matches.append(block.sourceMatch(drawn.hash, screenRows: edge))
      } else {
        miss(block)
      }
    }
    return Result(matches: matches.sorted { $0.top < $1.top }, unmatched: unmatched)
  }
}
