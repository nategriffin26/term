import UIKit

/// Where a diagram goes over its ASCII drawing, in points from the grid's top
/// left. The tile covers exactly the drawing's visible rows, so it never hides
/// real text. The image is centered and starts at the drawing's first row; a
/// drawing that goes on above the screen keeps it pinned at the top until its
/// remaining rows are shorter than it, then it leaves with the last row.
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
    let first = max(drawing.top, 0), last = min(drawing.bottom, rows - 1)
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
      ? min(0, tile.height - shown.height)
      : CGFloat(drawing.top - first) * cell.height
    let image = CGRect(x: (width - shown.width) / 2, y: y, width: shown.width, height: shown.height)
    return DiagramPlacement(tile: tile, image: image, clipsBottom: !drawing.openBottom && drawing.bottom <= rows - 1 && image.maxY > tile.height + 0.5)
  }
}

/// What a selection copies where it crosses drawn diagrams: each diagram's
/// Mermaid source, fenced, once, in place of its drawing's rows.
enum DiagramCopy {
  static func fenced(_ source: String) -> String { "```mermaid\n\(source)\n```" }

  /// `drawings`: rows from the top of scrollback, like the selection's.
  /// `text` reads the grid between two cells, inclusive.
  static func text(from start: GridPoint, to end: GridPoint, cols: Int,
                   drawings: [DiagramOverlay.Drawing], text: (GridPoint, GridPoint) -> String) -> String {
    var parts: [String] = []
    var from = start
    for d in drawings.sorted(by: { $0.top < $1.top }) where d.bottom >= from.row && d.top <= end.row {
      if from.row < d.top { parts.append(text(from, GridPoint(row: d.top - 1, col: max(cols - 1, 0)))) }
      parts.append(fenced(d.source))
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
  }

  /// A diagram on screen, for taps and the long-press menu.
  struct Shown {
    var drawing: Drawing
    var image: UIImage
    var style: DiagramEngine.Style
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
  /// Blocks by their text: what each draws, or nil. Cleared when sources change.
  private var known: [String: DiagramMatcher.Drawn?] = [:]
  private var tiles: [UIView] = []
  private(set) var shown: [Shown] = []
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
      source?.source(m.hash).map { Drawing(top: m.top + rowsTop, bottom: m.bottom + rowsTop, hash: m.hash, source: $0) }
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

  /// A new frame: read the screen (or a page's buffer) and match its drawings.
  func frameChanged() {
    let session = terminal.session.diagrams
    if session !== source {
      source = session
      known = [:]
      pageKey = []
      source?.onChange = { [weak self] in self?.sourcesChanged() }
    }
    let s = terminal.snapshot
    guard source != nil else {
      rows = []
      rematch()
      return
    }
    if terminal.isReadOnly {
      let key = [s.cols, s.rows, s.historyRows]
      guard key != pageKey else {
        layoutTiles()
        return
      }
      pageKey = key
      rows = Self.pageRows(terminal.session, cols: s.cols, rows: s.historyRows + s.rows)
      rowsTop = 0
    } else {
      rows = Self.screenRows(s)
      rowsTop = s.historyRows - s.viewportOffset
    }
    rematch()
  }

  private func sourcesChanged() {
    known = [:]
    rematch()
  }

  private func rematch() {
    guard let source, !rows.isEmpty else {
      matches = []
      layoutTiles()
      return
    }
    if known.count > 256 { known = [:] }
    let screen = terminal.isReadOnly ? nil : rows.count
    var found: [DiagramMatcher.Match] = []
    var unmatched: Set<String> = []
    func memo(_ lines: ArraySlice<String>) -> DiagramMatcher.Drawn? {
      let text = lines.joined(separator: "\n")
      if let drawn = known[text] { return drawn }
      let drawn = DiagramMatcher.drawn(lines, in: source.candidates)
      known[text] = drawn
      return drawn
    }
    func miss(_ block: DiagramMatcher.Block) {
      // Named without the screen's first and last rows: a status line's
      // clock there would make it a new drawing every minute.
      let inner = rows[max(block.top, 1)...max(min(block.bottom, rows.count - 2), 1)]
      let words = Set(DiagramMatcher.words(inner.joined(separator: "\n")))
      if words.count >= 2 { unmatched.insert(words.sorted().joined(separator: " ")) }
    }
    for block in DiagramMatcher.blocks(rows) where block.glyphRows >= DiagramMatcher.minGlyphRows {
      if let drawn = memo(rows[block.top...block.bottom]) {
        found.append(block.match(drawn, screenRows: screen))
      } else {
        miss(block)
      }
    }
    for block in DiagramMatcher.sourceBlocks(rows) {
      if let drawn = memo(rows[block.top + 1...block.bottom]) {
        found.append(block.sourceMatch(drawn.hash, screenRows: screen))
      } else {
        miss(block)
      }
    }
    matches = found
    layoutTiles()
    if !unmatched.isEmpty { source.unmatched(unmatched) }
  }

  /// Places one tile per matched block on screen whose image is ready.
  func layoutTiles() {
    let t = terminal
    let cell = t.cellSizePoints
    let snapshot = t.snapshot
    let viewTop = snapshot.historyRows - snapshot.viewportOffset
    let style = style(snapshot)
    var used = 0
    var shown: [Shown] = []
    for m in matches {
      guard let src = source?.source(m.hash) else { continue }
      let drawing = Drawing(top: m.top + rowsTop, bottom: m.bottom + rowsTop, hash: m.hash, source: src)
      // In grid rows: on a page, a drawing scrolled part way out lies past the grid.
      var onGrid = m
      onGrid.top = drawing.top - viewTop
      onGrid.bottom = drawing.bottom - viewTop
      let request = DiagramEngine.Request(
        hash: m.hash, maxWidth: Int(CGFloat(max(snapshot.cols - 2, 1)) * cell.width), style: style)
      guard let image = DiagramEngine.shared.image(request, source: src, ready: { [weak self] in self?.layoutTiles() }),
            let place = DiagramPlacement.place(onGrid, cols: snapshot.cols, rows: snapshot.rows, cell: cell, size: image.size)
      else { continue }
      let tile = used < tiles.count ? tiles[used] : makeTile()
      used += 1
      tile.frame = place.tile.offsetBy(dx: t.gridOrigin.x / t.scale, dy: t.gridOrigin.y / t.scale)
      tile.backgroundColor = UIColor(argb: snapshot.bg)
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
      shown.append(Shown(drawing: drawing, image: image, style: style, frame: tile.frame, tile: tile))
    }
    while tiles.count > used { tiles.removeLast().removeFromSuperview() }
    self.shown = shown
  }

  private func makeTile() -> UIView {
    let tile = UIView()
    tile.clipsToBounds = true
    let image = UIImageView()
    image.contentMode = .scaleToFill
    tile.addSubview(image)
    tile.addSubview(ClipFade())
    addSubview(tile)
    tiles.append(tile)
    return tile
  }

  private func style(_ s: FrameSnapshot) -> DiagramEngine.Style {
    let theme = AppSettings.shared.termTheme
    let palette = withUnsafeBytes(of: theme.palette) { Array($0.bindMemory(to: UInt32.self)).map { $0 & 0xFF_FFFF } }
    return .init(family: terminal.fontFamily, fontSize: Double(terminal.fontSize),
                 foreground: s.fg & 0xFF_FFFF, background: s.bg & 0xFF_FFFF, cursor: s.cursorColor & 0xFF_FFFF,
                 palette: palette, scale: Double(terminal.scale))
  }

  /// Each row of the frame as text; empty when nothing on screen is a drawing.
  static func screenRows(_ s: FrameSnapshot) -> [String] {
    guard s.cols > 0, s.cells.contains(where: { DiagramMatcher.isGlyph($0.ch) || $0.ch == 0x60 }) else { return [] }
    return (0..<s.rows).map { r in
      var row = String.UnicodeScalarView()
      for i in r * s.cols..<(r + 1) * s.cols {
        let scalars = s.scalars(at: i)
        if scalars.isEmpty { row.append(" ") }
        for v in scalars { if let u = Unicode.Scalar(v) { row.append(u) } }
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
