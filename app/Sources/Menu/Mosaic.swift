import CoreGraphics

/// The Sessions overview's layout: every open session tiles the panel in
/// swipe order (rows read left to right, top to bottom), each tile's area in
/// proportion to its weight. Tiles keep at least `minTile`; those that cannot
/// fit go to a shelf of name chips under the mosaic, least important first,
/// wrapping into as many rows as they need. Pure, so tests can feed real
/// panel sizes.
enum Mosaic {
  static let gap: CGFloat = 8
  static let minTile = CGSize(width: 112, height: 78)
  /// A shelf row: one chip high.
  static let shelfHeight: CGFloat = 36
  /// Tiles closest to this width-to-height ratio show a terminal best.
  static let target: CGFloat = 1.35

  /// How much a session matters on the overview, least first: the order the
  /// shelf takes tiles in, and their weight.
  enum Importance: Int, Comparable {
    case idle, stopped, working, needsYou, current

    /// The session the user came from is the largest; one waiting on the user the next.
    var weight: CGFloat {
      switch self {
      case .current: 2.2
      case .needsYou: 1.6
      case .idle, .stopped, .working: 1
      }
    }

    /// `agent` is the session's omp agent, if one runs there.
    init(agent: AgentInfo?, isCurrent: Bool) {
      if isCurrent {
        self = .current
        return
      }
      switch agent?.state {
      case .ask, .approval: self = .needsYou
      case .working: self = .working
      case .done, .error, .aborted, .exited: self = agent?.unread == true ? .stopped : .idle
      case .idle, nil: self = .idle
      }
    }

    static func < (a: Importance, b: Importance) -> Bool { a.rawValue < b.rawValue }
  }

  struct Tile<ID: Hashable>: Equatable {
    let id: ID
    let importance: Importance
  }

  struct Layout<ID: Hashable>: Equatable {
    var frames: [ID: CGRect] = [:]
    /// Sessions without a tile, in swipe order.
    var shelf: [ID] = []
    /// Where each shelved session's chip sits.
    var chips: [ID: CGRect] = [:]

    /// Where `id` shows: its tile, else its chip.
    func place(of id: ID) -> CGRect? { frames[id] ?? chips[id] }
  }

  /// Tiles for `tiles` (in order) in `area`. The shelf, when there is one,
  /// takes its rows of chips (each `chipWidth` wide) and a gap off the bottom.
  static func layout<ID: Hashable>(_ tiles: [Tile<ID>], in area: CGRect, chipWidth: (ID) -> CGFloat) -> Layout<ID> {
    var shown = tiles
    var shelved = Set<ID>()
    while !shown.isEmpty {
      let shelf = tiles.map(\.id).filter(shelved.contains)
      let chips = self.chips(shelf, in: area, chipWidth: chipWidth)
      let rect = shelf.isEmpty ? area
        : CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, chips.top - area.minY - gap))
      if let frames = rows(shown.map { ($0.id, $0.importance.weight) }, in: rect) {
        return Layout(frames: frames, shelf: shelf, chips: chips.frames)
      }
      // The least important goes first; of equals, the last in order.
      let worst = shown.indices.min { a, b in
        shown[a].importance != shown[b].importance ? shown[a].importance < shown[b].importance : a > b
      }!
      shelved.insert(shown.remove(at: worst).id)
    }
    let shelf = tiles.map(\.id)
    return Layout(frames: [:], shelf: shelf, chips: chips(shelf, in: area, chipWidth: chipWidth).frames)
  }

  /// `ids`' chips left to right, wrapping into rows that sit at the bottom of
  /// `area` (from its top when they need more than its height); `top` is the
  /// first row's top.
  static func chips<ID: Hashable>(_ ids: [ID], in area: CGRect, chipWidth: (ID) -> CGFloat)
    -> (frames: [ID: CGRect], top: CGFloat) {
    guard !ids.isEmpty else { return ([:], area.maxY) }
    var rows: [[(id: ID, width: CGFloat)]] = [[]]
    var used: CGFloat = 0
    for id in ids {
      let width = min(chipWidth(id), area.width)
      if !rows[rows.count - 1].isEmpty, used + gap + width > area.width {
        rows.append([])
        used = 0
      }
      used += (rows[rows.count - 1].isEmpty ? 0 : gap) + width
      rows[rows.count - 1].append((id, width))
    }
    let height = CGFloat(rows.count) * shelfHeight + CGFloat(rows.count - 1) * gap
    let top = max(area.minY, area.maxY - height)
    var frames: [ID: CGRect] = [:]
    for (r, row) in rows.enumerated() {
      var x = area.minX
      let y = top + CGFloat(r) * (shelfHeight + gap)
      for chip in row {
        frames[chip.id] = CGRect(x: x, y: y, width: chip.width, height: shelfHeight)
        x += chip.width + gap
      }
    }
    return (frames, top)
  }

  /// Splits `items` into consecutive rows: row heights share the height by
  /// weight and tiles share their row by weight, so every tile's area is its
  /// share. Of the splits that keep every tile at least `minTile`, the one
  /// whose tiles are closest to `target`; nil when none does.
  static func rows<ID: Hashable>(_ items: [(id: ID, weight: CGFloat)], in r: CGRect) -> [ID: CGRect]? {
    let n = items.count
    guard n > 0 else { return [:] }
    var prefix = [CGFloat](repeating: 0, count: n + 1)
    for (i, item) in items.enumerated() { prefix[i + 1] = prefix[i] + item.weight }
    let total = prefix[n]
    // No split has more rows or columns than minimum tiles fit.
    let maxRows = min(n, Int((r.height + gap) / (minTile.height + gap)))
    let maxColumns = Int((r.width + gap) / (minTile.width + gap))
    guard maxRows >= 1, maxColumns >= 1, total > 0 else { return nil }

    func rowCost(_ i: Int, _ j: Int, height: CGFloat) -> CGFloat {
      let rowWeight = prefix[j] - prefix[i]
      let h = height * rowWeight / total
      let available = r.width - gap * CGFloat(j - i - 1)
      guard h >= minTile.height else { return .infinity }
      var cost: CGFloat = 0
      for item in items[i..<j] {
        let w = available * item.weight / rowWeight
        if w < minTile.width { return .infinity }
        let l = log(w / h / target)
        cost += item.weight * l * l
      }
      return cost
    }

    var best: (cost: CGFloat, cuts: [Int])?
    for rowCount in 1...maxRows {
      let height = r.height - gap * CGFloat(rowCount - 1)
      // cost[k][j]: the first j items in k rows; from[k][j]: where the k-th row starts.
      var cost = [[CGFloat]](repeating: [CGFloat](repeating: .infinity, count: n + 1), count: rowCount + 1)
      var from = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: rowCount + 1)
      cost[0][0] = 0
      for k in 1...rowCount {
        for j in k...n {
          for i in max(k - 1, j - maxColumns)..<j where cost[k - 1][i] < .infinity {
            let c = cost[k - 1][i] + rowCost(i, j, height: height)
            if c < cost[k][j] {
              cost[k][j] = c
              from[k][j] = i
            }
          }
        }
      }
      if cost[rowCount][n] < (best?.cost ?? .infinity) {
        var cuts: [Int] = []
        var j = n
        for k in stride(from: rowCount, to: 0, by: -1) {
          cuts.insert(j, at: 0)
          j = from[k][j]
        }
        best = (cost[rowCount][n], cuts)
      }
    }
    guard let best else { return nil }

    var frames: [ID: CGRect] = [:]
    let height = r.height - gap * CGFloat(best.cuts.count - 1)
    var y = r.minY
    var start = 0
    for (k, end) in best.cuts.enumerated() {
      let rowWeight = prefix[end] - prefix[start]
      let h = k == best.cuts.count - 1 ? r.maxY - y : (height * rowWeight / total).rounded()
      let available = r.width - gap * CGFloat(end - start - 1)
      var x = r.minX
      for index in start..<end {
        let w = index == end - 1 ? r.maxX - x : (available * items[index].weight / rowWeight).rounded()
        frames[items[index].id] = CGRect(x: x, y: y, width: w, height: h)
        x += w + gap
      }
      y += h + gap
      start = end
    }
    return frames
  }

  /// A lifted session's place in the order, held by identity so that sessions
  /// opening or closing during the drag leave it where the preview shows it.
  struct Placement<ID: Hashable>: Equatable {
    let id: ID
    /// The session of its run it follows; nil: first of the run.
    var after: ID?

    /// Where `id` sits in `order`; nil when it is not there.
    init?(of id: ID, in order: [ID], run: Set<ID>) {
      guard let index = order.firstIndex(of: id) else { return nil }
      self.id = id
      after = order[..<index].last(where: run.contains)
    }

    init(id: ID, after: ID?) {
      self.id = id
      self.after = after
    }

    /// `items` with `id`'s item put in this place among `run` (the lifted
    /// session's window's sessions); nil when `id` is gone. When `after` has
    /// gone, the item stays where it is.
    func apply<T>(to items: [T], id key: (T) -> ID, run: Set<ID>) -> [T]? {
      guard let from = items.firstIndex(where: { key($0) == id }) else { return nil }
      var rest = items
      let item = rest.remove(at: from)
      let to: Int
      if let after {
        guard run.contains(after), let i = rest.firstIndex(where: { key($0) == after }) else { return items }
        to = i + 1
      } else {
        to = rest.firstIndex { run.contains(key($0)) } ?? from
      }
      rest.insert(item, at: to)
      return rest
    }

    /// `id`'s index among `run` once placed: where the drop moves its tab in its window.
    func index(in order: [ID], run: Set<ID>) -> Int? {
      apply(to: order, id: { $0 }, run: run)?.filter(run.contains).firstIndex(of: id)
    }
  }

  /// Where a lifted session lands: of the places in its `run`, the one whose
  /// layout puts its tile or chip nearest the lifted session's centre.
  /// `current`, the place it holds now, wins near-ties so it does not flicker
  /// between two.
  static func landing<ID: Hashable>(_ current: Placement<ID>, in tiles: [Tile<ID>], run: Set<ID>, near center: CGPoint,
                                    area: CGRect, chipWidth: (ID) -> CGFloat) -> Placement<ID> {
    let places = [nil] + tiles.map(\.id).filter { run.contains($0) && $0 != current.id }
    var best = (place: current, distance: CGFloat.infinity)
    for after in places {
      let place = Placement(id: current.id, after: after)
      guard let order = place.apply(to: tiles, id: \.id, run: run),
            let frame = layout(order, in: area, chipWidth: chipWidth).place(of: current.id) else { continue }
      let distance = hypot(frame.midX - center.x, frame.midY - center.y) - (place == current ? 24 : 0)
      if distance < best.distance { best = (place, distance) }
    }
    return best.place
  }
}
