/// Tracks diagram bounds in a scrolling screen's row space. tmux redraws its
/// alternate screen rather than moving the terminal's scrollback offset.
struct DiagramScrollState {
  private(set) var rows: [String] = []
  private(set) var origin = 0
  private(set) var epoch = 0
  private var drawings: [DiagramMatcher.Match] = []
  private var topInset = 0
  private var bottomInset = 0

  var visible: [DiagramMatcher.Match] {
    drawings.compactMap { drawing in
      var drawing = drawing
      drawing.top -= origin
      drawing.bottom -= origin
      if topInset > 0, drawing.top < topInset { drawing.clipTop = topInset }
      if bottomInset > 0, drawing.bottom >= rows.count - bottomInset {
        drawing.clipBottom = rows.count - bottomInset - 1
      }
      return drawing.bottom >= 0 && drawing.top < rows.count ? drawing : nil
    }
  }

  mutating func reset() {
    rows = []
    origin = 0
    epoch += 1
    drawings = []
    topInset = 0
    bottomInset = 0
  }

  mutating func update(_ next: [String]) {
    guard next != rows else { return }
    if let shift = Self.shift(from: rows, to: next) {
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
      reset()
    }
    rows = next
    resolveSourceEnds()
  }

  /// Matching can finish after further scrolls. Its original row space is still
  /// valid until a redraw, resize or source change replaces that screen.
  mutating func merge(_ matches: [DiagramMatcher.Match], origin: Int, epoch: Int) {
    guard epoch == self.epoch else { return }
    for var match in matches {
      match.top += origin
      match.bottom += origin
      if let i = drawings.firstIndex(where: {
        $0.top <= match.bottom && $0.bottom >= match.top
      }) {
        let old = drawings[i]
        if old.hash == match.hash, old.isText == match.isText {
          if match.openTop { match.top = min(old.top, match.top); match.openTop = old.openTop }
          if match.openBottom { match.bottom = max(old.bottom, match.bottom); match.openBottom = old.openBottom }
        } else if !old.openTop, !old.openBottom {
          // A complete drawing on unchanged rows outranks a fragment's guess.
          continue
        }
        drawings[i] = match
      } else {
        drawings.append(match)
      }
    }
    // Remember offscreen drawings for reversal, bounded by distance rather than
    // hash: the same source may occur more than once in a conversation.
    if drawings.count > 128 {
      drawings.sort { abs($0.top - self.origin) < abs($1.top - self.origin) }
      drawings.removeLast(drawings.count - 128)
    }
    drawings.sort { $0.top < $1.top }
    resolveSourceEnds()
  }

  /// A long source's closing fence can arrive after its opening has left.
  /// Learn that end without needing both fences on the screen together.
  private mutating func resolveSourceEnds() {
    for i in drawings.indices where drawings[i].isText && drawings[i].openBottom {
      let first = max(topInset, drawings[i].top - origin + 1)
      let end = rows.count - bottomInset
      guard first < end else { continue }
      for row in first..<end {
        let text = rows[row].drop(while: \.isWhitespace)
        if text.hasPrefix("```"), text.dropFirst(3).allSatisfy(\.isWhitespace) {
          drawings[i].bottom = row + origin
          drawings[i].openBottom = false
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
