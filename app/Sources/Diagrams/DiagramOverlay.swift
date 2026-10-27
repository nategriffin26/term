import UIKit

/// The visible slice of a diagram, in points from the grid's top left.
/// Image geometry uses the retained block bounds, never its visible height.
struct DiagramPlacement: Equatable {
  /// The drawing's visible rows, full width.
  var tile: CGRect
  /// The image, relative to the tile (it may extend past it and is clipped).
  var image: CGRect
  /// The drawing's last row is on screen and the image runs past it: the
  /// tile fades out there to say there is more.
  var clipsBottom: Bool

  /// Smallest height scale used to fit a diagram within an ASCII drawing.
  static let minScale: CGFloat = 0.75

  /// `drawing`: its rows on a grid `rows` tall, which may lie past the grid
  /// (a page scrolled part way through it). `cell`: one cell in points.
  /// `size`: the image in points.
  static func place(_ drawing: DiagramMatcher.Match, cols: Int, rows: Int, cell: CGSize, size: CGSize) -> DiagramPlacement? {
    let first = max(drawing.top, drawing.clipTop ?? 0), last = min(drawing.bottom, drawing.clipBottom ?? rows - 1)
    guard last >= first, size.width > 0, size.height > 0 else { return nil }
    let width = CGFloat(cols) * cell.width
    let block = CGFloat(drawing.bottom - drawing.top + 1) * cell.height
    let tile = CGRect(x: 0, y: CGFloat(first) * cell.height, width: width, height: CGFloat(last - first + 1) * cell.height)
    var scale = min(1, CGFloat(max(cols - 2, 1)) * cell.width / size.width)
    // Both edges known: the whole drawing is known, so fit it, within reason.
    if !drawing.openTop, !drawing.openBottom, size.height * scale > block {
      scale = min(scale, max(block / size.height, drawing.isText ? 0 : minScale))
    }
    let shown = CGSize(width: size.width * scale, height: size.height * scale)
    let y = drawing.openTop && !drawing.openBottom
      ? CGFloat(drawing.bottom - first + 1) * cell.height - shown.height
      : CGFloat(drawing.top - first) * cell.height
    let image = CGRect(x: (width - shown.width) / 2, y: y, width: shown.width, height: shown.height)
    return DiagramPlacement(tile: tile, image: image, clipsBottom: !drawing.openBottom && drawing.bottom <= rows - 1 && image.maxY > tile.height + 0.5)
  }
}

/// What a selection copies where it crosses drawn diagrams: each diagram's
/// Mermaid source, fenced, once, in place of its drawing's rows.
enum DiagramCopy {
  private struct Location: Hashable {
    var top: Int
    var hash: String
  }

  static func fenced(_ source: String) -> String { "```mermaid\n\(source)\n```" }

  /// `drawings`: rows from the top of scrollback, like the selection's.
  /// `text` reads the grid between two cells, inclusive.
  static func text(from start: GridPoint, to end: GridPoint, cols: Int,
                   drawings: [DiagramOverlay.Drawing], text: (GridPoint, GridPoint) -> String) -> String {
    var parts: [String] = []
    var copied: Set<Location> = []
    var from = start
    for d in drawings.sorted(by: { $0.top < $1.top }) where d.bottom >= from.row && d.top <= end.row {
      if from.row < d.top { parts.append(text(from, GridPoint(row: d.top - 1, col: max(cols - 1, 0)))) }
      if copied.insert(Location(top: d.blockTop ?? d.top, hash: d.hash)).inserted {
        parts.append(fenced(d.source))
      }
      from = GridPoint(row: d.bottom + 1, col: 0)
    }
    if from <= end { parts.append(text(from, end)) }
    return parts.joined(separator: "\n")
  }
}

/// Real diagrams over omp's ASCII drawings in a terminal's grid: matches the
/// screen's drawings to the session's published sources and lays an image
/// over each matched block on the terminal background. Anything missing (no
/// source, a render failure, a render still running) leaves the ASCII. On a
/// page to read (tmux history) the whole buffer is matched, so every drawing
/// is known whole and moves with its text.
@MainActor
final class DiagramOverlay: UIView {
  /// A matched drawing: its rows from the top of scrollback and its source.
  struct Drawing: Equatable {
    var top: Int
    var bottom: Int
    var hash: String
    var source: String
    /// Shared by verified fragments of one block; nil when the drawing is whole.
    var blockTop: Int? = nil
  }

  /// A diagram on screen, for taps and the long-press menu.
  struct Shown {
    var drawing: Drawing
    var image: UIImage
    var style: DiagramEngine.Style
    var openTop: Bool
    var openBottom: Bool
    /// The tile, in the terminal view's coordinates.
    var frame: CGRect
    let tile: UIView
  }

  static let menuID = "diagram" as NSString

  private unowned let terminal: TerminalView
  private var source: DiagramSource?
  /// The rows matched: the screen's, or on a page the whole buffer.
  private var rows: [String] = []
  /// Row of `rows[0]`, counted from the top of scrollback.
  private var rowsTop = 0
  /// The page's size when `rows` was read from it: cols, rows, scrollback rows.
  private var pageKey: [Int] = []
  private var matches: [DiagramMatcher.Match] = []
  private var scroll = DiagramScrollState()
  private let matcher = DiagramMatching()
  private var revision = 0
  private var matching = false
  private var gridColumns = 0
  private var pendingImages: Set<DiagramEngine.CacheKey> = []
  private var tiles: [DiagramTile] = []
  private(set) var shown: [Shown] = []
  var isUpdating: Bool { matching || !pendingImages.isEmpty }
  /// The diagram the long-press menu is for.
  var menuTarget: Shown?

  init(terminal: TerminalView) {
    self.terminal = terminal
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// Matched drawings with their sources, rows from the top of scrollback.
  var drawings: [Drawing] {
    matches.compactMap { m in
      let (m, _) = clipping(m)
      return source?.source(m.hash).map {
        Drawing(top: max(m.top, m.clipTop ?? m.top) + rowsTop,
                bottom: min(m.bottom, m.clipBottom ?? m.bottom) + rowsTop, hash: m.hash, source: $0, blockTop: m.top + rowsTop)
      }
    }
  }

  /// The diagram drawn under a point in the terminal view, if it shows.
  func diagram(at point: CGPoint) -> Shown? {
    isHidden ? nil : shown.first { $0.frame.contains(point) }
  }

  /// The tile now showing a diagram, for the full-screen viewer's zoom back.
  func tile(for hash: String) -> UIView? {
    shown.first { $0.drawing.hash == hash }?.tile
  }

  /// Move known drawings in the same frame as the text. Vocabulary matching
  /// runs separately; a new drawing alone stays ASCII until it is ready.
  func frameChanged() {
    let session = terminal.session.diagrams
    if session !== source {
      source?.onChange = nil
      source = session
      scroll.reset()
      matches = []
      pageKey = []
      source?.onChange = { [weak self] in self?.sourcesChanged() }
    }
    let s = terminal.snapshot
    guard source != nil else {
      rows = []
      matches = []
      revision += 1
      layoutTiles()
      return
    }
    if terminal.isReadOnly {
      let key = [s.cols, s.rows, s.historyRows]
      guard key != pageKey else {
        layoutTiles()
        return
      }
      pageKey = key
      scroll.reset()
      matches = []
      rows = Self.pageRows(terminal.session, cols: s.cols, rows: s.historyRows + s.rows)
      rowsTop = 0
    } else {
      if gridColumns != s.cols {
        scroll.reset()
        gridColumns = s.cols
      }
      rows = Self.screenRows(s)
      for row in rows.indices where row <= DiagramMatcher.maxTrim || row >= s.rows - DiagramMatcher.maxTrim - 1 {
        if let columns = copyCounterColumns(row) {
          rows[row] = String(rows[row].prefix(columns.lowerBound)) + String(repeating: " ", count: columns.count)
        }
      }
      rowsTop = s.historyRows - s.viewportOffset
      scroll.update(rows, candidates: source?.candidates ?? [])
      matches = scroll.visible
    }
    revision += 1
    layoutTiles()
    rematch()
  }

  private func sourcesChanged() {
    revision += 1
    rematch()
  }

  private func rematch() {
    guard !matching, let source, !rows.isEmpty else { return }
    matching = true
    let revision = revision, rows = rows, origin = scroll.origin, epoch = scroll.epoch
    let page = terminal.isReadOnly
    let candidates = source.candidates
    Task { [weak self, matcher] in
      let result = await matcher.scan(rows, candidates: candidates, screen: !page)
      guard let self else { return }
      matching = false
      if source === self.source, epoch == scroll.epoch {
        if page {
          matches = result.matches
        } else {
          scroll.merge(result.matches, origin: origin, epoch: epoch)
          matches = scroll.visible
        }
        layoutTiles()
        if !result.unmatched.isEmpty { source.unmatched(result.unmatched) }
      }
      if revision != self.revision { rematch() }
    }
  }

  /// Places one tile per matched block on screen whose image is ready.
  func layoutTiles() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let t = terminal
    let cell = t.cellSizePoints
    let snapshot = t.snapshot
    let viewTop = snapshot.historyRows - snapshot.viewportOffset
    let style = style(snapshot)
    var used = 0
    var shown: [Shown] = []
    for original in matches {
      let (m, cutouts) = clipping(original)
      guard let src = source?.source(m.hash) else { continue }
      let drawing = Drawing(top: m.top + rowsTop, bottom: m.bottom + rowsTop, hash: m.hash, source: src)
      // In grid rows: on a page, a drawing scrolled part way out lies past the grid.
      var onGrid = m
      onGrid.top = drawing.top - viewTop
      onGrid.bottom = drawing.bottom - viewTop
      let request = DiagramEngine.Request(
        hash: m.hash, maxWidth: Int(CGFloat(max(snapshot.cols - 2, 1)) * cell.width), style: style)
      let key = DiagramEngine.CacheKey(request: request, source: src)
      guard !pendingImages.contains(key) else { continue }
      pendingImages.insert(key)
      let image = DiagramEngine.shared.image(request, source: src, ready: { [weak self] in
        guard let self else { return }
        pendingImages.remove(key)
        layoutTiles()
      })
      if image != nil { pendingImages.remove(key) }
      guard let image,
            (!m.isText || (!m.openTop && !m.openBottom)),
            let place = DiagramPlacement.place(onGrid, cols: snapshot.cols, rows: snapshot.rows, cell: cell, size: image.size)
      else { continue }
      let tile = used < tiles.count ? tiles[used] : makeTile()
      used += 1
      tile.frame = place.tile.offsetBy(dx: t.gridOrigin.x / t.scale, dy: t.gridOrigin.y / t.scale)
      tile.backgroundColor = UIColor(argb: snapshot.bg)
      tile.setCutouts(cutouts.map { $0.offsetBy(dx: -place.tile.minX, dy: -place.tile.minY) })
      let view = tile.subviews[0] as! UIImageView
      view.image = image
      view.frame = place.image
      let fade = tile.subviews[1] as! ClipFade
      fade.isHidden = !place.clipsBottom
      if place.clipsBottom {
        let h = min(place.tile.height, cell.height * 2)
        fade.frame = CGRect(x: 0, y: place.tile.height - h, width: place.tile.width, height: h)
        fade.update(background: UIColor(argb: snapshot.bg), foreground: UIColor(argb: snapshot.fg))
      }
      shown.append(Shown(drawing: drawing, image: image, style: style,
                         openTop: m.openTop, openBottom: m.openBottom, frame: tile.frame, tile: tile))
    }
    while tiles.count > used { tiles.removeLast().removeFromSuperview() }
    self.shown = shown
  }

  private func makeTile() -> DiagramTile {
    let tile = DiagramTile()
    tile.clipsToBounds = true
    let image = UIImageView()
    image.contentMode = .scaleToFill
    tile.addSubview(image)
    tile.addSubview(ClipFade())
    addSubview(tile)
    tiles.append(tile)
    return tile
  }

  private func copyCounterColumns(_ row: Int) -> Range<Int>? {
    let s = terminal.snapshot
    guard row >= 0, row < s.rows, s.cols > 0 else { return nil }
    let start = row * s.cols
    var last = s.cols - 1
    while last > 0, s.cells[start + last].ch <= 32 { last -= 1 }
    let background = s.cells[start + last].bg
    guard background != s.bg else { return nil }
    var first = last
    while first > 0, s.cells[start + first - 1].bg == background { first -= 1 }
    return first > 0 ? first..<s.cols : nil
  }

  /// A copy-mode position is a colored suffix, not a whole status row.
  /// Preserve its actual cells without exposing the source beside it.
  private func clipping(_ original: DiagramMatcher.Match) -> (DiagramMatcher.Match, [CGRect]) {
    let s = terminal.snapshot, cell = terminal.cellSizePoints
    var match = original
    var cutouts: [CGRect] = []
    func suffix(_ row: Int) -> CGRect? {
      guard let columns = copyCounterColumns(row) else { return nil }
      return CGRect(x: CGFloat(columns.lowerBound) * cell.width, y: CGFloat(row) * cell.height,
                    width: CGFloat(columns.count) * cell.width, height: cell.height)
    }
    if let top = match.clipTop, let rect = suffix(top - 1) {
      match.clipTop = top - 1
      cutouts.append(rect)
    }
    if let bottom = match.clipBottom, let rect = suffix(bottom + 1) {
      match.clipBottom = bottom + 1
      cutouts.append(rect)
    }
    // During a partial tmux redraw the counter can sit one row inside the
    // verified block rather than immediately outside its clipped edge.
    func preserveCounter(at row: Int) {
      guard row >= max(match.top, match.clipTop ?? 0),
            row <= min(match.bottom, match.clipBottom ?? s.rows - 1),
            let rect = suffix(row), !cutouts.contains(rect) else { return }
      cutouts.append(rect)
    }
    for edge in 0...DiagramMatcher.maxTrim {
      preserveCounter(at: edge)
      preserveCounter(at: s.rows - edge - 1)
    }
    return (match, cutouts)
  }

  private func style(_ s: FrameSnapshot) -> DiagramEngine.Style {
    let theme = AppSettings.shared.termTheme
    let palette = withUnsafeBytes(of: theme.palette) { Array($0.bindMemory(to: UInt32.self)).map { $0 & 0xFF_FFFF } }
    return .init(family: terminal.fontFamily, fontSize: Double(terminal.fontSize),
                 foreground: s.fg & 0xFF_FFFF, background: s.bg & 0xFF_FFFF, cursor: s.cursorColor & 0xFF_FFFF,
                 palette: palette, scale: Double(terminal.scale))
  }

  /// Keep plain rows too: a source fragment can have neither a fence nor a glyph.
  static func screenRows(_ s: FrameSnapshot) -> [String] {
    guard s.cols > 0, s.rows > 0 else { return [] }
    return (0..<s.rows).map { r in
      var row = String.UnicodeScalarView()
      for i in r * s.cols..<(r + 1) * s.cols {
        let cell = s.cells[i]
        if cell.grapheme == 0 {
          row.append(Unicode.Scalar(cell.ch == 0 ? 32 : cell.ch) ?? " ")
        } else {
          let g = s.graphemes[Int(cell.grapheme) - 1]
          for value in s.codepoints[Int(g.offset)..<Int(g.offset + g.len)] {
            if let scalar = Unicode.Scalar(value) { row.append(scalar) }
          }
        }
      }
      return String(row)
    }
  }

  /// Every row of a page, scrollback first, one row each (soft wraps kept apart).
  static func pageRows(_ session: Session, cols: Int, rows: Int) -> [String] {
    guard cols > 0 else { return [] }
    return (0..<rows).map { session.text(fromCol: 0, row: $0, toCol: cols - 1, row: $0) }
  }
}

private final class DiagramTile: UIView {
  private let cutoutMask = CAShapeLayer()
  private var maskedBounds = CGRect.null
  private var cutouts: [CGRect] = []

  func setCutouts(_ rectangles: [CGRect]) {
    guard rectangles != cutouts || bounds != maskedBounds else { return }
    cutouts = rectangles
    maskedBounds = bounds
    guard !rectangles.isEmpty else { layer.mask = nil; return }
    let path = UIBezierPath(rect: bounds)
    for rect in rectangles {
      let clipped = rect.intersection(bounds)
      if !clipped.isNull { path.append(UIBezierPath(rect: clipped)) }
    }
    cutoutMask.fillRule = .evenOdd
    cutoutMask.path = path.cgPath
    layer.mask = cutoutMask
  }
}

/// The bottom edge of a tile whose diagram runs past its rows: fades to the
/// terminal background with a small expand glyph, a tap away from the whole.
private final class ClipFade: UIView {
  private let gradient = CAGradientLayer()
  private let glyph = UIImageView(image: UIImage(
    systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)))

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    layer.addSublayer(gradient)
    addSubview(glyph)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func update(background: UIColor, foreground: UIColor) {
    gradient.colors = [background.withAlphaComponent(0).cgColor, background.cgColor]
    glyph.tintColor = foreground.withAlphaComponent(0.6)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = bounds
    glyph.sizeToFit()
    glyph.frame.origin = CGPoint(x: bounds.maxX - glyph.bounds.width - 6, y: bounds.maxY - glyph.bounds.height - 4)
  }
}
