import CoreGraphics

/// The Sessions overview's tiling, after Tern's split tree: a window's
/// sessions as windows that share the panel along nested splits, in swipe
/// order (the tree's reading order). Until the user shapes it the tiling is
/// even: the app picks the rows that fit the panel best and every window in
/// a row gets the same share. Dragging a border resizes the two windows (or
/// groups) beside it, double-tapping one evens every split out again, and
/// dropping a window on another's edge puts it on that side (on its
/// middle, the two swap; on the shelf, it parks). Windows that cannot keep
/// `minTile`, and sessions parked with no share, are name chips on a shelf
/// under the tiling. Pure, so tests can feed real panel sizes.
enum Tiling {
  static let gap: CGFloat = 8
  static let minTile = CGSize(width: 112, height: 78)
  /// A shelf row: one chip high.
  static let shelfHeight: CGFloat = 36
  /// Windows closest to this width-to-height ratio show a terminal best.
  static let target: CGFloat = 1.35
  /// How much unequal window sizes count against an even grid, next to how
  /// far its windows are from `target`: a 3×3 grid beats 3+2+2+2 rows.
  static let evenness: CGFloat = 10
  /// A drop within this fraction of a window's middle (each way) swaps the two.
  static let swapZone: CGFloat = 0.25
  /// How far a border's touch zone reaches into the windows on either side of its gap.
  static let borderReach: CGFloat = 10

  enum Axis: String, Codable, Equatable {
    /// Side by side: the borders between the parts are vertical.
    case across
    /// Stacked: the borders are horizontal.
    case down

    var other: Axis { self == .across ? .down : .across }
  }

  enum Edge: Equatable {
    case left, right, top, bottom

    /// The axis of the split a drop on this edge makes.
    var axis: Axis { self == .left || self == .right ? .across : .down }
    /// The dropped window goes first (left or above).
    var leads: Bool { self == .left || self == .top }
  }

  /// What letting a lifted window go over another does.
  enum Drop<ID: Hashable>: Equatable {
    /// Splits the target, the lifted window on this edge's half.
    case split(ID, Edge)
    case swap(ID)

    var target: ID {
      switch self {
      case .split(let id, _), .swap(let id): id
      }
    }
  }

  /// A border between two neighbouring parts of a split, which a drag moves.
  struct Border: Equatable {
    /// The split's place in the tree: part indices from the root.
    let path: [Int]
    /// The parts on either side (neighbours among those shown).
    let before: Int
    let after: Int
    let axis: Axis
    /// The gap between them.
    let rect: CGRect
    /// Where the part before starts and the part after ends, along the axis.
    let start: CGFloat
    let end: CGFloat
    /// The range the part before may end in so that every window on both
    /// sides keeps `minTile`.
    let lower: CGFloat
    let upper: CGFloat
  }

  struct Layout<ID: Hashable>: Equatable {
    var frames: [ID: CGRect] = [:]
    /// Sessions without a window, in swipe order.
    var shelf: [ID] = []
    /// Where each shelved session's chip sits.
    var chips: [ID: CGRect] = [:]
    var borders: [Border] = []

    /// Where `id` shows: its window, else its chip.
    func place(of id: ID) -> CGRect? { frames[id] ?? chips[id] }
  }

  // MARK: Layout

  /// Where `tree`'s windows go in `area`, with `others` (sessions of other
  /// windows) as chips after its shelf. Windows parked with no share start on
  /// the shelf; then, while any window is smaller than `minTile`, the last
  /// such window in reading order joins them and the rest re-share its room.
  /// The shelf takes its rows of chips (each `chipWidth` wide) and a gap off
  /// the bottom.
  static func layout<ID: Hashable & Codable>(_ tree: SplitTree<ID>?, others: [ID] = [], in area: CGRect,
                                   chipWidth: (ID) -> CGFloat) -> Layout<ID> {
    let order = tree?.windows ?? []
    var hidden = tree?.parked ?? []
    while true {
      let shelf = order.filter(hidden.contains) + others
      let chips = self.chips(shelf, in: area, chipWidth: chipWidth)
      guard let tree, hidden.count < order.count else {
        return Layout(shelf: shelf, chips: chips.frames)
      }
      let rect = shelf.isEmpty ? area
        : CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, chips.top - area.minY - gap))
      var frames: [ID: CGRect] = [:]
      var borders: [Border] = []
      place(tree, in: rect, path: [], hidden: hidden, frames: &frames, borders: &borders)
      guard let small = order.last(where: { frames[$0].map(isTooSmall) ?? false }) else {
        return Layout(frames: frames, shelf: shelf, chips: chips.frames, borders: borders)
      }
      hidden.insert(small)
    }
  }

  private static func isTooSmall(_ frame: CGRect) -> Bool {
    // Half a point for rounding.
    frame.width < minTile.width - 0.5 || frame.height < minTile.height - 0.5
  }

  private static func place<ID: Hashable & Codable>(_ node: SplitTree<ID>, in r: CGRect, path: [Int], hidden: Set<ID>,
                                          frames: inout [ID: CGRect], borders: inout [Border]) {
    switch node {
    case .window(let id):
      if !hidden.contains(id) { frames[id] = r }
    case .split(let axis, let parts):
      let shown = parts.indices.filter { parts[$0].node.windows.contains { !hidden.contains($0) } }
      guard !shown.isEmpty else { return }
      let total = shown.reduce(0) { $0 + parts[$1].share }
      let across = axis == .across
      let start = across ? r.minX : r.minY
      let end = across ? r.maxX : r.maxY
      let available = end - start - gap * CGFloat(shown.count - 1)
      var offset = start
      var previous: (index: Int, start: CGFloat)?
      for (k, i) in shown.enumerated() {
        let share = total > 0 ? parts[i].share / total : 1 / CGFloat(shown.count)
        let extent = k == shown.count - 1 ? end - offset : max(0, (available * share).rounded())
        if let previous {
          let partEnd = k == shown.count - 1 ? end : offset + extent
          let gapRect = across ? CGRect(x: offset - gap, y: r.minY, width: gap, height: r.height)
            : CGRect(x: r.minX, y: offset - gap, width: r.width, height: gap)
          borders.append(Border(
            path: path, before: previous.index, after: i, axis: axis, rect: gapRect, start: previous.start, end: partEnd,
            lower: previous.start + minExtent(parts[previous.index].node, along: axis, hidden: hidden),
            upper: partEnd - gap - minExtent(parts[i].node, along: axis, hidden: hidden)))
        }
        let sub = across ? CGRect(x: offset, y: r.minY, width: extent, height: r.height)
          : CGRect(x: r.minX, y: offset, width: r.width, height: extent)
        place(parts[i].node, in: sub, path: path + [i], hidden: hidden, frames: &frames, borders: &borders)
        previous = (i, offset)
        offset += extent + gap
      }
    }
  }

  /// The least room `node`'s shown windows need along `axis`.
  private static func minExtent<ID: Hashable & Codable>(_ node: SplitTree<ID>, along axis: Axis, hidden: Set<ID>) -> CGFloat {
    switch node {
    case .window(let id):
      return hidden.contains(id) ? 0 : axis == .across ? minTile.width : minTile.height
    case .split(let splitAxis, let parts):
      let shown = parts.filter { $0.node.windows.contains { !hidden.contains($0) } }
      let extents = shown.map { minExtent($0.node, along: axis, hidden: hidden) }
      return splitAxis == axis ? extents.reduce(0, +) + gap * CGFloat(max(0, shown.count - 1)) : extents.max() ?? 0
    }
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

  // MARK: The even tiling

  /// The tiling while the user has not shaped one: as many of `order` as fit
  /// in an even grid (`evenRows`), the rest parked on the shelf. Parked
  /// sessions sit at the end of the last row with no share, so the tree
  /// shows exactly this when the user starts shaping it.
  static func evenTree<ID: Hashable & Codable>(_ order: [ID], others: [ID] = [], in area: CGRect,
                                     chipWidth: (ID) -> CGFloat) -> SplitTree<ID>? {
    guard !order.isEmpty else { return nil }
    for count in stride(from: order.count, through: 1, by: -1) {
      let parked = Array(order[count...])
      let shelf = parked + others
      let top = shelf.isEmpty ? area.maxY + gap : chips(shelf, in: area, chipWidth: chipWidth).top
      let rect = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, top - area.minY - gap))
      if let rows = evenRows(count: count, in: rect) {
        return grid(Array(order[..<count]), rows: rows, parked: parked)
      }
    }
    // Not even one window fits: the layout shelves this one too.
    return grid([order[0]], rows: [1], parked: Array(order.dropFirst()))
  }

  /// How many windows each row of an even grid of `count` holds in `rect`:
  /// rows of equal height, windows in a row of equal width, row lengths at
  /// most one apart (longer rows first). Of the grids whose windows all keep
  /// `minTile`, the one with the most equal windows nearest `target`; nil
  /// when none fits.
  static func evenRows(count: Int, in rect: CGRect) -> [Int]? {
    guard count > 0 else { return [] }
    var best: (cost: CGFloat, rows: [Int])?
    for rowCount in 1...count {
      let (base, extra) = count.quotientAndRemainder(dividingBy: rowCount)
      let rows = Array(repeating: base + 1, count: extra) + Array(repeating: base, count: rowCount - extra)
      let height = (rect.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)
      guard height >= minTile.height - 0.5 else { continue }
      let sizes = rows.flatMap { columns in
        Array(repeating: CGSize(width: (rect.width - gap * CGFloat(columns - 1)) / CGFloat(columns), height: height),
              count: columns)
      }
      guard sizes.allSatisfy({ $0.width >= minTile.width - 0.5 }) else { continue }
      let mean = sizes.reduce(0) { $0 + $1.width * $1.height } / CGFloat(sizes.count)
      let cost = sizes.reduce(0) { cost, size in
        let shape = log(size.width / size.height / target)
        let spread = log(size.width * size.height / mean)
        return cost + shape * shape + evenness * spread * spread
      }
      if cost < (best?.cost ?? .infinity) - 1e-9 { best = (cost, rows) }
    }
    return best?.rows
  }

  /// `ids` in rows of `rows` windows, each row and window an equal share;
  /// `parked` end the last row with none.
  private static func grid<ID: Hashable & Codable>(_ ids: [ID], rows: [Int], parked: [ID]) -> SplitTree<ID> {
    var nodes: [SplitTree<ID>] = []
    var start = 0
    for (r, columns) in rows.enumerated() {
      var parts = ids[start..<start + columns].map { SplitTree<ID>.Part(share: 1 / CGFloat(columns), node: .window($0)) }
      if r == rows.count - 1 { parts += parked.map { SplitTree<ID>.Part(share: 0, node: .window($0)) } }
      nodes.append(parts.count == 1 ? parts[0].node : .split(.across, parts))
      start += columns
    }
    return nodes.count == 1 ? nodes[0]
      : .split(.down, nodes.map { SplitTree<ID>.Part(share: 1 / CGFloat(nodes.count), node: $0) })
  }

  // MARK: Keeping the user's tiling in step with the sessions

  /// The user's `tree` brought up to date with `order` (the window's sessions
  /// in swipe order): closed sessions leave (their split's other parts keep
  /// their proportions), new ones arrive by `inserting`, and the windows take
  /// `order`'s sessions in reading order. nil, meaning even, when there is no
  /// tree, it is damaged, or one session or none of it is left.
  static func reconciled<ID: Hashable & Codable>(_ tree: SplitTree<ID>?, order: [ID], others: [ID] = [], in area: CGRect,
                                       chipWidth: (ID) -> CGFloat) -> SplitTree<ID>? {
    guard var tree, Set(tree.windows).count == tree.windows.count else { return nil }
    let live = Set(order)
    for id in tree.windows where !live.contains(id) {
      guard let rest = tree.removing(id) else { return nil }
      tree = rest
    }
    guard tree.windows.count > 1 else { return nil }
    for (i, id) in order.enumerated() where !tree.windows.contains(id) {
      let previous = order[..<i].last { tree.windows.contains($0) }
      tree = inserting(id, after: previous, into: tree, others: others, in: area, chipWidth: chipWidth)
    }
    return tree.relabeled(order)
  }

  /// Where a new session goes in the user's tiling: beside the session before
  /// it in swipe order (the first window when none is), sharing that split
  /// evenly with the others there, which keep their proportions; when that
  /// leaves a window under `minTile`, that session's window is split in half
  /// across the split's direction instead; when neither fits, it is parked.
  static func inserting<ID: Hashable & Codable>(_ id: ID, after previous: ID?, into tree: SplitTree<ID>, others: [ID] = [],
                                      in area: CGRect, chipWidth: (ID) -> CGFloat) -> SplitTree<ID> {
    let anchor = previous ?? tree.windows[0]
    let after = previous != nil
    let long: Axis = area.width >= area.height ? .across : .down
    let across = (tree.axis(around: anchor) ?? long).other
    let edge: Edge = across == .across ? (after ? .right : .left) : (after ? .bottom : .top)
    let shelved = Set(layout(tree, others: others, in: area, chipWidth: chipWidth).shelf)
    let candidates = [
      tree.joining(id, beside: anchor, after: after, axis: long),
      tree.placing(id, beside: anchor, on: edge),
    ]
    let fits = candidates.first { candidate in
      Set(layout(candidate, others: others, in: area, chipWidth: chipWidth).shelf).isSubset(of: shelved)
    }
    return fits ?? tree.joining(id, beside: anchor, after: after, axis: long, parked: true)
  }

  // MARK: Gestures

  /// The border whose touch zone holds `point`: its gap and `borderReach`
  /// either side across it. Where zones cross, the nearest gap's middle wins.
  static func border(at point: CGPoint, in borders: [Border]) -> Border? {
    func distance(_ border: Border) -> CGFloat {
      border.axis == .across ? abs(point.x - border.rect.midX) : abs(point.y - border.rect.midY)
    }
    return borders
      .filter { border in
        border.rect.insetBy(dx: border.axis == .across ? -borderReach : 0, dy: border.axis == .down ? -borderReach : 0)
          .contains(point)
      }
      .min { distance($0) < distance($1) }
  }

  /// The drop a lifted window held at `point` makes: over another window's
  /// middle a swap, else a split on its nearest edge; nil over no window.
  static func drop<ID: Hashable>(at point: CGPoint, lifted: ID, frames: [ID: CGRect]) -> Drop<ID>? {
    guard let (target, f) = frames.first(where: { $0.key != lifted && $0.value.contains(point) }),
          f.width > 0, f.height > 0 else { return nil }
    let x = (point.x - f.minX) / f.width
    let y = (point.y - f.minY) / f.height
    if abs(x - 0.5) <= swapZone, abs(y - 0.5) <= swapZone { return .swap(target) }
    let edges: [(Edge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
    return .split(target, edges.min { $0.1 < $1.1 }!.0)
  }

  /// `tree` with `id` dropped as `drop` says. On an edge along the target's
  /// split, `id` joins that split with an equal share (the others keep their
  /// proportions), as a new session does; on an edge across it, `id` and the
  /// target halve the target's room.
  static func dropping<ID: Hashable & Codable>(_ id: ID, _ drop: Drop<ID>, in tree: SplitTree<ID>) -> SplitTree<ID> {
    guard id != drop.target else { return tree }
    switch drop {
    case .swap(let target):
      return tree.swapping(id, target)
    case let .split(target, edge):
      guard let rest = tree.removing(id), rest.windows.contains(target) else { return tree }
      if rest.axis(around: target) == edge.axis {
        return rest.joining(id, beside: target, after: !edge.leads, axis: edge.axis)
      }
      return rest.placing(id, beside: target, on: edge)
    }
  }

  /// `dropping` on this panel. A drop never sends another shown window to the
  /// shelf (a swap's target excepted: it trades places with the lifted one):
  /// when an equal share along the target's split would, the lifted window
  /// halves the target's room instead, as a new session does; nil when that
  /// does not fit either.
  static func dropping<ID: Hashable & Codable>(_ id: ID, _ drop: Drop<ID>, in tree: SplitTree<ID>, others: [ID] = [],
                                               area: CGRect, chipWidth: (ID) -> CGFloat) -> SplitTree<ID>? {
    var allowed = Set(layout(tree, others: others, in: area, chipWidth: chipWidth).shelf)
    var candidates = [dropping(id, drop, in: tree)]
    switch drop {
    case .swap(let target):
      allowed.insert(target)
    case let .split(target, edge):
      if let rest = tree.removing(id), rest.axis(around: target) == edge.axis {
        candidates.append(rest.placing(id, beside: target, on: edge))
      }
    }
    return candidates.first { candidate in
      Set(layout(candidate, others: others, in: area, chipWidth: chipWidth).shelf).isSubset(of: allowed)
    }
  }

  /// `tree` with `id` parked on the shelf after its last session (the end of
  /// the swipe order); its split's others share its room in proportion. nil
  /// when it is the only session.
  static func parking<ID: Hashable & Codable>(_ id: ID, in tree: SplitTree<ID>) -> SplitTree<ID>? {
    guard let rest = tree.removing(id), let last = rest.windows.last else { return nil }
    return rest.joining(id, beside: last, after: true, axis: .across, parked: true)
  }

  /// `tree` evened out (every split's parts equal, Tern's even out); nil,
  /// meaning even, when that is just the even tiling of its sessions, which
  /// then adapts to the panel again.
  static func evenedOut<ID: Hashable & Codable>(_ tree: SplitTree<ID>, others: [ID] = [], in area: CGRect,
                                      chipWidth: (ID) -> CGFloat) -> SplitTree<ID>? {
    let even = tree.equalized()
    return even == evenTree(tree.windows, others: others, in: area, chipWidth: chipWidth) ? nil : even
  }

  /// `tree` with `border`'s part before ending at `position` (kept within the
  /// border's range): the two parts beside it trade room, every other share
  /// stays.
  static func resizing<ID: Hashable & Codable>(_ tree: SplitTree<ID>, at border: Border, to position: CGFloat) -> SplitTree<ID> {
    guard border.lower <= border.upper else { return tree }
    let end = min(max(position, border.lower), border.upper)
    let before = end - border.start
    let after = border.end - end - gap
    guard before + after > 0 else { return tree }
    return tree.updatingShares(at: border.path) { shares in
      let pair = shares[border.before] + shares[border.after]
      shares[border.before] = pair * before / (before + after)
      shares[border.after] = pair - shares[border.before]
    }
  }
}

/// A tiling's tree: a session's window, or a split of parts side by side or
/// stacked, each with its share of the split's length (shares add up to 1;
/// a part with none is parked on the shelf). Splits never hold a part split
/// the same way, so evening out shares a row among all of its windows, as
/// Tern does.
indirect enum SplitTree<ID: Hashable & Codable>: Equatable, Codable {
  case window(ID)
  case split(Tiling.Axis, [Part])

  struct Part: Equatable, Codable {
    var share: CGFloat
    var node: SplitTree
  }

  /// Its sessions in reading order (depth first): the swipe order.
  var windows: [ID] {
    switch self {
    case .window(let id): [id]
    case .split(_, let parts): parts.flatMap(\.node.windows)
    }
  }

  /// Sessions parked with no share: they show as chips.
  var parked: Set<ID> {
    switch self {
    case .window: []
    case .split(_, let parts):
      parts.reduce(into: Set<ID>()) { parked, part in
        parked.formUnion(part.share > 0 ? part.node.parked : Set(part.node.windows))
      }
    }
  }

  /// The direction of the split holding `id`'s window; nil when it is the whole tree or absent.
  func axis(around id: ID) -> Tiling.Axis? {
    guard case .split(let axis, let parts) = self else { return nil }
    if parts.contains(where: { $0.node == .window(id) }) { return axis }
    return parts.lazy.compactMap { $0.node.axis(around: id) }.first
  }

  /// Without `id`: the other parts of its split keep their proportions, a
  /// split left with one part becomes that part. nil when nothing is left.
  func removing(_ id: ID) -> SplitTree? {
    switch self {
    case .window(let window):
      return window == id ? nil : self
    case .split(let axis, let parts):
      let kept = parts.compactMap { part in part.node.removing(id).map { Part(share: part.share, node: $0) } }
      return kept.isEmpty ? nil : SplitTree.split(axis, kept).normalized()
    }
  }

  func swapping(_ a: ID, _ b: ID) -> SplitTree {
    switch self {
    case .window(let id): .window(id == a ? b : id == b ? a : id)
    case .split(let axis, let parts):
      .split(axis, parts.map { Part(share: $0.share, node: $0.node.swapping(a, b)) })
    }
  }

  /// The same splits and shares, with `order` filling the windows in reading
  /// order; `order` holds as many sessions as the tree.
  func relabeled(_ order: [ID]) -> SplitTree {
    var next = order.makeIterator()
    func fill(_ node: SplitTree) -> SplitTree {
      switch node {
      case .window(let id): .window(next.next() ?? id)
      case .split(let axis, let parts): .split(axis, parts.map { Part(share: $0.share, node: fill($0.node)) })
      }
    }
    return fill(self)
  }

  /// Every split's parts with equal shares, parked ones included.
  func equalized() -> SplitTree {
    switch self {
    case .window: self
    case .split(let axis, let parts):
      .split(axis, parts.map { Part(share: 1 / CGFloat(parts.count), node: $0.node.equalized()) })
    }
  }

  /// `id` on `edge`'s side of `target`, the two halving target's room.
  func placing(_ id: ID, beside target: ID, on edge: Tiling.Edge) -> SplitTree {
    switch self {
    case .window(let window):
      guard window == target else { return self }
      let pair = [Part(share: 0.5, node: .window(id)), Part(share: 0.5, node: self)]
      return .split(edge.axis, edge.leads ? pair : pair.reversed())
    case .split(let axis, let parts):
      var out: [Part] = []
      for part in parts {
        if axis == edge.axis, part.node == .window(target) {
          let half = [Part(share: part.share / 2, node: .window(id)), Part(share: part.share / 2, node: part.node)]
          out += edge.leads ? half : half.reversed()
        } else {
          out.append(Part(share: part.share, node: part.node.placing(id, beside: target, on: edge)))
        }
      }
      return SplitTree.split(axis, out).normalized()
    }
  }

  /// `id` beside `anchor` in anchor's split (after it, or before), with an
  /// equal share among the parts that have one, which keep their proportions;
  /// `parked`, with none. A lone window becomes a split along `axis`.
  func joining(_ id: ID, beside anchor: ID, after: Bool, axis: Tiling.Axis, parked: Bool = false) -> SplitTree {
    switch self {
    case .window(let window):
      guard window == anchor else { return self }
      let pair = [Part(share: parked ? 1 : 0.5, node: self), Part(share: parked ? 0 : 0.5, node: .window(id))]
      return .split(axis, after ? pair : pair.reversed())
    case .split(let splitAxis, var parts):
      guard let i = parts.firstIndex(where: { $0.node == .window(anchor) }) else {
        return .split(splitAxis, parts.map {
          Part(share: $0.share, node: $0.node.joining(id, beside: anchor, after: after, axis: axis, parked: parked))
        })
      }
      let sharing = CGFloat(parts.filter { $0.share > 0 }.count)
      if !parked {
        for p in parts.indices { parts[p].share *= sharing / (sharing + 1) }
      }
      parts.insert(Part(share: parked ? 0 : 1 / (sharing + 1), node: .window(id)), at: after ? i + 1 : i)
      return .split(splitAxis, parts)
    }
  }

  /// The split at `path` with its shares changed by `update`.
  func updatingShares(at path: [Int], _ update: (inout [CGFloat]) -> Void) -> SplitTree {
    guard case .split(let axis, var parts) = self else { return self }
    guard let first = path.first else {
      var shares = parts.map(\.share)
      update(&shares)
      return .split(axis, zip(parts, shares).map { Part(share: $1, node: $0.node) })
    }
    guard parts.indices.contains(first) else { return self }
    parts[first].node = parts[first].node.updatingShares(at: Array(path.dropFirst()), update)
    return .split(axis, parts)
  }

  /// Parts split the same way as their split merge into it, a split of one
  /// part becomes that part, and shares add up to 1 (equal when none is
  /// positive and finite, as from a damaged file).
  func normalized() -> SplitTree {
    guard case .split(let axis, let parts) = self else { return self }
    var flat: [Part] = []
    for part in parts {
      let node = part.node.normalized()
      if case .split(axis, let inner) = node {
        flat += inner.map { Part(share: part.share * $0.share, node: $0.node) }
      } else {
        flat.append(Part(share: part.share, node: node))
      }
    }
    guard flat.count > 1 else { return flat.first?.node ?? self }
    let shares = flat.map { $0.share.isFinite ? max(0, $0.share) : 0 }
    let total = shares.reduce(0, +)
    return .split(axis, zip(flat, shares).map { part, share in
      Part(share: total > 0 ? share / total : 1 / CGFloat(flat.count), node: part.node)
    })
  }
}
