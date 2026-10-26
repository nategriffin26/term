import UIKit

/// Where a diagram goes over its ASCII block, in points from the grid's top
/// left. The tile covers exactly the block's visible rows, so it never hides
/// real text. The image is centered and starts at the block's first row; a
/// block that runs off the top keeps it pinned at the top until the block's
/// remaining rows are shorter than it, then it leaves with the last row.
struct DiagramPlacement: Equatable {
  /// The block's visible rows, full width.
  var tile: CGRect
  /// The image, relative to the tile (it may extend past it and is clipped).
  var image: CGRect

  /// Smallest height scale used to fit a diagram within its block.
  static let minScale: CGFloat = 0.75

  /// `top`/`bottom`: the block's rows on screen (`top` 0 when it may continue
  /// above). `cell`: one cell in points. `size`: the image in points.
  static func place(top: Int, bottom: Int, rows: Int, cols: Int, cell: CGSize, size: CGSize) -> DiagramPlacement? {
    let first = max(top, 0), last = min(bottom, rows - 1)
    guard last >= first, size.width > 0, size.height > 0 else { return nil }
    let width = CGFloat(cols) * cell.width
    let tile = CGRect(x: 0, y: CGFloat(first) * cell.height, width: width, height: CGFloat(last - first + 1) * cell.height)
    var scale = min(1, CGFloat(max(cols - 2, 1)) * cell.width / size.width)
    // Both edges on screen: the whole block is known, so fit it, within reason.
    if top > 0, bottom < rows - 1, size.height * scale > tile.height {
      scale = min(scale, max(tile.height / size.height, minScale))
    }
    let shown = CGSize(width: size.width * scale, height: size.height * scale)
    let y = top > 0 ? 0 : min(0, tile.height - shown.height)
    let pinned = bottom < rows - 1 ? y : 0
    return DiagramPlacement(tile: tile, image: CGRect(x: (width - shown.width) / 2, y: pinned, width: shown.width, height: shown.height))
  }
}

/// Real diagrams over omp's ASCII drawings in a terminal's grid: matches the
/// screen's drawings to the session's published sources and lays an image
/// over each matched block on the terminal background. Anything missing (no
/// source, a render failure, a render still running) leaves the ASCII.
@MainActor
final class DiagramOverlay: UIView {
  private unowned let terminal: TerminalView
  private var source: DiagramSource?
  /// The screen's rows as text, from the last frame that had a drawing.
  private var rows: [String] = []
  private var matches: [DiagramMatcher.Match] = []
  /// Drawings by their text: the source each is, or nil. Cleared when sources change.
  private var known: [String: String?] = [:]
  private var tiles: [UIView] = []

  init(terminal: TerminalView) {
    self.terminal = terminal
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// A new frame: read the screen and match its drawings.
  func frameChanged() {
    let session = terminal.session.diagrams
    if session !== source {
      source = session
      known = [:]
      source?.onChange = { [weak self] in self?.sourcesChanged() }
    }
    rows = source.map { _ in Self.screenRows(terminal.snapshot) } ?? []
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
    var found: [DiagramMatcher.Match] = []
    var unmatched: Set<String> = []
    for block in DiagramMatcher.blocks(rows) {
      let text = rows[block.top...block.bottom].joined(separator: "\n")
      let hash: String?
      if let memo = known[text] {
        hash = memo
      } else {
        hash = DiagramMatcher.source(of: DiagramMatcher.words(text), in: source.candidates)
        known[text] = hash
      }
      if let hash {
        found.append(.init(top: block.top, bottom: block.bottom, hash: hash))
      } else if block.glyphRows >= 3 {
        // Two rules (omp's composer) are not a drawing worth a fetch.
        let words = Set(DiagramMatcher.words(text))
        if words.count >= 2 { unmatched.insert(words.sorted().joined(separator: " ")) }
      }
    }
    matches = found
    layoutTiles()
    if !unmatched.isEmpty { source.unmatched(unmatched) }
  }

  /// Places one tile per matched block whose image is ready.
  func layoutTiles() {
    let t = terminal
    let cell = t.cellSizePoints
    let snapshot = t.snapshot
    var used = 0
    for m in matches {
      guard let src = source?.source(m.hash) else { continue }
      let request = DiagramEngine.Request(
        hash: m.hash, maxWidth: Int(CGFloat(max(snapshot.cols - 2, 1)) * cell.width), style: style(snapshot))
      guard let image = DiagramEngine.shared.image(request, source: src, ready: { [weak self] in self?.layoutTiles() }),
            let place = DiagramPlacement.place(top: m.top, bottom: m.bottom, rows: snapshot.rows, cols: snapshot.cols,
                                               cell: cell, size: image.size)
      else { continue }
      let tile = used < tiles.count ? tiles[used] : makeTile()
      used += 1
      tile.frame = place.tile.offsetBy(dx: t.gridOrigin.x / t.scale, dy: t.gridOrigin.y / t.scale)
      tile.backgroundColor = UIColor(argb: snapshot.bg)
      let view = tile.subviews[0] as! UIImageView
      view.image = image
      view.frame = place.image
    }
    while tiles.count > used { tiles.removeLast().removeFromSuperview() }
  }

  private func makeTile() -> UIView {
    let tile = UIView()
    tile.clipsToBounds = true
    let image = UIImageView()
    image.contentMode = .scaleToFill
    tile.addSubview(image)
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
    guard s.cols > 0, s.cells.contains(where: { DiagramMatcher.isGlyph($0.ch) }) else { return [] }
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
}
