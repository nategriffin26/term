/// Tracks diagram bounds in a scrolling screen's row space. tmux redraws its
/// alternate screen rather than moving the terminal's scrollback offset.
struct DiagramScrollState {
  private struct Drawing {
    var bounds: DiagramMatcher.Match
    var space: Int
    /// Exact observed rows, in the same coordinate space as bounds.
    var evidence: [Int: String] = [:]
    var positioned = true
  }

  private(set) var rows: [String] = []
  private(set) var origin = 0
  private(set) var epoch = 0
  private var drawings: [Drawing] = []
  private var topInset = 0
  private var bottomInset = 0

  var visible: [DiagramMatcher.Match] {
    drawings.compactMap { retained in
      guard retained.positioned else { return nil }
      var drawing = retained.bounds
      drawing.top -= origin
      drawing.bottom -= origin
      drawing.clipTop = drawing.clipTop.map { $0 - origin }
      drawing.clipBottom = drawing.clipBottom.map { $0 - origin }
      var first = topInset
      while first > 0, retained.evidence[origin + first - 1] == rows[first - 1] { first -= 1 }
      var last = rows.count - bottomInset - 1
      while last < rows.count - 1, retained.evidence[origin + last + 1] == rows[last + 1] { last += 1 }
      if first > 0, drawing.top < first { drawing.clipTop = max(drawing.clipTop ?? 0, first) }
      if last < rows.count - 1, drawing.bottom > last { drawing.clipBottom = min(drawing.clipBottom ?? rows.count - 1, last) }
      // A colored copy counter may obscure only a suffix of the last row.
      // The overlay applies that cutout after restoring the row beside it.
      return drawing.bottom >= 0 && drawing.top < rows.count ? drawing : nil
    }.sorted { $0.top < $1.top }
  }

  mutating func reset() {
    rows = []
    origin = 0
    epoch += 1
    drawings = []
    topInset = 0
    bottomInset = 0
  }

  mutating func update(_ next: [String], candidates: [DiagramMatcher.Candidate] = []) {
    guard next != rows else { return }
    let shift = Self.shift(from: rows, to: next)
    if let shift {
      if shift != 0 {
        topInset = 0
        bottomInset = 0
        for edge in 0..<DiagramMatcher.maxTrim {
          let oldTop = max(0, -shift) + edge, newTop = oldTop + shift
          let oldBottom = min(rows.count - 1, rows.count - 1 - shift) - edge
          let newBottom = oldBottom + shift
          if rows[oldTop] != next[newTop] { topInset = edge + 1 }
          if rows[oldBottom] != next[newBottom] { bottomInset = edge + 1 }
        }
      }
      origin -= shift
    } else {
      // A rejected global translation invalidates in-flight matches, not the
      // independent evidence of drawings that may reappear after a jump.
      epoch += 1
      origin = 0
      topInset = 0
      bottomInset = 0
      for i in drawings.indices { drawings[i].positioned = false }
    }
    rows = next
    relocateUnpositionedDrawings()
    extendOpenEdges(candidates)
    resolveSourceEnds()
    rememberRows()
  }

  /// Matching can finish after further scrolls. Its original row space is still
  /// valid until a nonuniform redraw, resize or source change replaces it.
  mutating func merge(_ matches: [DiagramMatcher.Match], origin: Int, epoch: Int) {
    guard epoch == self.epoch else { return }
    for var match in matches {
      match.top += origin
      match.bottom += origin
      if let i = drawings.firstIndex(where: {
        $0.positioned && $0.bounds.top <= match.bottom && $0.bounds.bottom >= match.top
      }) {
        let old = drawings[i].bounds
        if old.hash == match.hash, old.isText == match.isText {
          // A vocabulary match cannot erase an exact partial-redraw boundary.
          if !old.openTop, !old.openBottom, old.clipTop != nil || old.clipBottom != nil { continue }
          if match.openTop { match.top = min(old.top, match.top); match.openTop = old.openTop }
          if match.openBottom { match.bottom = max(old.bottom, match.bottom); match.openBottom = old.openBottom }
        } else if !old.openTop, !old.openBottom {
          // A complete drawing on unchanged rows outranks a fragment's guess.
          continue
        } else {
          drawings[i].evidence.removeAll(keepingCapacity: true)
        }
        drawings[i].bounds = match
      } else {
        drawings.append(Drawing(bounds: match, space: epoch))
      }
    }
    if drawings.count > 128 {
      drawings.sort {
        if $0.positioned != $1.positioned { return $0.positioned }
        return abs($0.bounds.top - self.origin) < abs($1.bounds.top - self.origin)
      }
      drawings.removeLast(drawings.count - 128)
    }
    resolveSourceEnds()
    rememberRows()
  }

  /// Once a block is identified, newly adjacent rows use that same source's
  /// vocabulary and glyph rules immediately, rather than waiting for a rematch.
  private mutating func extendOpenEdges(_ candidates: [DiagramMatcher.Candidate]) {
    for i in drawings.indices where drawings[i].positioned {
      let bounds = drawings[i].bounds
      guard !bounds.isText, bounds.clipTop == nil, bounds.clipBottom == nil,
            bounds.openTop || bounds.openBottom,
            let candidate = candidates.first(where: { $0.hash == bounds.hash }) else { continue }
      if bounds.openTop {
        let edge = expandedEdge(from: bounds.top - origin, step: -1, candidate: candidate)
        drawings[i].bounds.top = edge.row + origin
        drawings[i].bounds.openTop = !edge.closed
      }
      if bounds.openBottom {
        let edge = expandedEdge(from: bounds.bottom - origin, step: 1, candidate: candidate)
        drawings[i].bounds.bottom = edge.row + origin
        drawings[i].bounds.openBottom = !edge.closed
      }
    }
  }

  private func expandedEdge(from start: Int, step: Int, candidate: DiagramMatcher.Candidate) -> (row: Int, closed: Bool) {
    guard rows.indices.contains(start) else { return (start, false) }
    var edge = start, row = start + step, labels = 0
    while rows.indices.contains(row) {
      let text = rows[row]
      let glyph = DiagramMatcher.hasGlyph(text)
      let accepts = text.contains(where: { !$0.isWhitespace }) && candidate.covers(DiagramMatcher.words(text))
      if !accepts || (!glyph && labels == 2) {
        let closed = row >= topInset && row < rows.count - bottomInset
        return (closed ? edge - step * labels : edge, closed)
      }
      labels = glyph ? 0 : labels + 1
      edge = row
      row += step
    }
    return (edge, false)
  }

  private mutating func rememberRows() {
    for i in drawings.indices where drawings[i].positioned {
      let match = drawings[i].bounds
      let first = max(topInset, max(match.top, match.clipTop ?? match.top) - origin)
      let last = min(rows.count - bottomInset - 1, min(match.bottom, match.clipBottom ?? match.bottom) - origin)
      guard first <= last else { continue }
      for row in first...last where drawings[i].evidence[row + origin] == nil {
        drawings[i].evidence[row + origin] = rows[row]
      }
    }
  }

  /// Exact block rows establish placement without trusting unrelated prose or
  /// another block's motion. A partially delivered redraw covers only verified
  /// contiguous rows; the image still uses the original full-block geometry.
  private mutating func relocateUnpositionedDrawings() {
    guard drawings.contains(where: { !$0.positioned || $0.bounds.clipTop != nil || $0.bounds.clipBottom != nil }) else { return }
    var positions: [String: [Int]] = [:]
    for row in rows.indices { positions[rows[row], default: []].append(row + origin) }
    var owners: [String: String] = [:]
    var shared: Set<String> = []
    for drawing in drawings {
      for text in drawing.evidence.values {
        if let owner = owners.updateValue(drawing.bounds.hash, forKey: text), owner != drawing.bounds.hash {
          shared.insert(text)
        }
      }
    }
    var recovered: [Drawing] = []
    var translations: [Int: Set<Int>] = [:]
    for drawing in drawings {
      if drawing.positioned, drawing.bounds.clipTop == nil, drawing.bounds.clipBottom == nil {
        recovered.append(drawing)
        continue
      }
      var unique: [String: Int] = [:]
      var repeated: Set<String> = []
      for (row, text) in drawing.evidence {
        if unique.updateValue(row, forKey: text) != nil { repeated.insert(text) }
      }
      var offsets: Set<Int> = []
      if drawing.space == epoch { offsets.insert(0) }
      for (text, row) in unique where !repeated.contains(text) && !shared.contains(text) && Self.isAnchor(text) {
        for position in positions[text] ?? [] { offsets.insert(position - row) }
      }
      var placements: [Drawing] = []
      for offset in offsets.sorted() {
        let first = max(origin, drawing.bounds.top + offset)
        let last = min(origin + rows.count - 1, drawing.bounds.bottom + offset)
        guard first <= last else { continue }
        var start: Int?
        var anchors = 0
        for row in first...last + 1 {
          let text = row <= last ? rows[row - origin] : ""
          if row <= last, drawing.evidence[row - offset] == text {
            if start == nil { start = row }
            if unique[text] == row - offset, !repeated.contains(text), !shared.contains(text), Self.isAnchor(text) {
              anchors += 1
            }
          } else {
            if let start, anchors >= 2 || (drawing.space == epoch && offset == 0) {
              var placed = drawing
              placed.positioned = true
              placed.space = epoch
              if anchors >= 2 { translations[drawing.space, default: []].insert(offset) }
              placed.bounds.top += offset
              placed.bounds.bottom += offset
              placed.bounds.clipTop = start > max(origin, placed.bounds.top) ? start : nil
              placed.bounds.clipBottom = row - 1 < min(origin + rows.count - 1, placed.bounds.bottom) ? row - 1 : nil
              if offset != 0 {
                placed.evidence = Dictionary(uniqueKeysWithValues: drawing.evidence.map { ($0.key + offset, $0.value) })
              }
              placements.append(placed)
            }
            start = nil
            anchors = 0
          }
        }
      }
      if placements.isEmpty {
        var unplaced = drawing
        unplaced.positioned = false
        recovered.append(unplaced)
      } else {
        for placed in placements where !recovered.contains(where: { $0.positioned && $0.bounds == placed.bounds }) {
          recovered.append(placed)
        }
      }
    }
    // A uniquely reanchored block carries its row space, not its visibility.
    // Neighbors still verify their own exact rows before they can be shown;
    // this lets a wordless edge return without waiting for a label.
    var rebased = false
    for i in recovered.indices where !recovered[i].positioned && recovered[i].space != epoch {
      guard let offsets = translations[recovered[i].space], offsets.count == 1, let offset = offsets.first else { continue }
      recovered[i].bounds.top += offset
      recovered[i].bounds.bottom += offset
      recovered[i].bounds.clipTop = nil
      recovered[i].bounds.clipBottom = nil
      if offset != 0 {
        recovered[i].evidence = Dictionary(uniqueKeysWithValues: recovered[i].evidence.map { ($0.key + offset, $0.value) })
      }
      recovered[i].space = epoch
      rebased = true
    }
    drawings = recovered
    if rebased { relocateUnpositionedDrawings() }
  }

  private static func isAnchor(_ row: String) -> Bool {
    !row.drop(while: \.isWhitespace).hasPrefix("```") && row.contains(where: { $0.isLetter || $0.isNumber })
  }

  /// A long source's closing fence can arrive after its opening has left.
  private mutating func resolveSourceEnds() {
    for i in drawings.indices where drawings[i].positioned && drawings[i].bounds.isText && drawings[i].bounds.openBottom {
      let first = max(topInset, drawings[i].bounds.top - origin + 1)
      let end = rows.count - bottomInset
      guard first < end else { continue }
      for row in first..<end {
        let text = rows[row].drop(while: \.isWhitespace)
        if text.hasPrefix("```"), text.dropFirst(3).allSatisfy(\.isWhitespace) {
          drawings[i].bounds.bottom = row + origin
          drawings[i].bounds.openBottom = false
          break
        }
      }
    }
  }

  /// Positive means text moved down. Unique nonblank rows vote for a shift;
  /// the overlap must agree, except for up to two rows at each edge where
  /// tmux draws its status, clock and copy-mode position. Repeated box borders alone
  /// cannot establish motion.
  static func shift(from old: [String], to new: [String]) -> Int? {
    let edge = DiagramMatcher.maxTrim
    guard old.count == new.count, old.count > edge * 2 else { return nil }
    if old == new { return 0 }
    let interior = edge..<(old.count - edge)
    if old[interior] == new[interior] { return 0 }
    var positions: [String: Int] = [:]
    var repeated: Set<String> = []
    for i in interior where old[i].contains(where: { !$0.isWhitespace }) {
      if positions.updateValue(i, forKey: old[i]) != nil { repeated.insert(old[i]) }
    }
    var votes: [Int: Int] = [:]
    for i in interior {
      if let previous = positions[new[i]], !repeated.contains(new[i]) {
        votes[i - previous, default: 0] += 1
      }
    }
    let ranked = votes.sorted { $0.value > $1.value }
    guard let best = ranked.first, best.value >= 3,
          ranked.count == 1 || best.value > ranked[1].value else { return nil }
    let delta = best.key
    let first = max(edge, edge - delta), end = min(old.count - edge, old.count - edge - delta)
    guard first < end else { return nil }
    for i in first..<end where old[i] != new[i + delta] { return nil }
    return delta
  }
}
