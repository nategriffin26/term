import Metal
import QuartzCore
import UIKit

/// Draws overview thumbnails with the terminal's own Renderer, glyphs
/// rasterized at the size they show at instead of a scaled-down screen.
/// Thumbnails of one size share a font and its Renderer.
@MainActor
final class ThumbnailRenderer {
  private var renderers: [RendererKey: Renderer] = [:]
  private var views: [ObjectIdentifier: Weak] = [:]
  private var link: CADisplayLink?
  private var fontCache: [FontKey: FontSet] = [:]

  private struct Weak { weak var view: SessionThumbnailView? }
  private struct FontKey: Hashable {
    var family: String
    var cellWidth: Int
    var scale: CGFloat
    var minimum: CGFloat
  }
  private struct RendererKey: Hashable {
    var family: String
    var pointSize: CGFloat
    var scale: CGFloat

    init(_ fonts: FontSet) {
      family = fonts.family
      pointSize = fonts.pointSize
      scale = fonts.scale
    }
  }

  /// Thumbnails refresh only while the overview is on screen.
  var isActive = false {
    didSet { if isActive != oldValue { updateLink() } }
  }

  func add(_ view: SessionThumbnailView) {
    views[ObjectIdentifier(view)] = Weak(view: view)
    updateLink()
  }

  func remove(_ view: SessionThumbnailView) {
    views[ObjectIdentifier(view)] = nil
    updateLink()
  }

  /// The smallest text a thumbnail draws: below it a tile is texture, not
  /// words. A session too wide for its tile at this size shows the columns
  /// around its cursor instead of shrinking further.
  static let legiblePointSize: CGFloat = 6

  /// The font whose cell is `cellWidth` device pixels wide (or the nearest
  /// below), in the terminal's family, never under `minimum` points.
  func fonts(cellWidth: Int, scale: CGFloat, family: String, minimum: CGFloat = legiblePointSize) -> FontSet {
    let key = FontKey(family: family, cellWidth: max(cellWidth, 1), scale: scale, minimum: minimum)
    if let cached = fontCache[key] { return cached }
    let reference = FontSet(family: family, pointSize: 10, scale: scale)
    var size = max(10 * CGFloat(key.cellWidth) / CGFloat(reference.metrics.width), minimum)
    var fonts = FontSet(family: family, pointSize: size, scale: scale)
    // Cell widths are rounded to whole pixels; step down until it fits.
    while fonts.metrics.width > key.cellWidth, size > minimum {
      size = max(size - 0.1, minimum)
      fonts = FontSet(family: family, pointSize: size, scale: scale)
    }
    fontCache[key] = fonts
    return fonts
  }

  /// The thumbnail on screen drawing `session`, if any.
  func view(showing session: Session) -> SessionThumbnailView? {
    views.values.lazy.compactMap(\.view).first { $0.window != nil && $0.source() === session }
  }

  fileprivate func renderer(for fonts: FontSet) -> Renderer? {
    let key = RendererKey(fonts)
    if let renderer = renderers[key] { return renderer }
    let renderer = Renderer(fonts: fonts)
    renderers[key] = renderer
    return renderer
  }

  private func updateLink() {
    let wants = isActive && !views.isEmpty
    if wants, link == nil {
      let link = CADisplayLink(target: ThumbnailTick(self), selector: #selector(ThumbnailTick.tick))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
      link.add(to: .main, forMode: .common)
      self.link = link
    } else if !wants, let link {
      link.invalidate()
      self.link = nil
    }
  }

  fileprivate func tick() {
    views = views.filter { $0.value.view != nil }
    for entry in views.values { entry.view?.refresh(with: self) }
    // Sizes no thumbnail shows any more give back their glyph atlases.
    let shown = Set(views.values.compactMap { $0.view?.fonts.map(RendererKey.init) })
    if renderers.count > shown.count { renderers = renderers.filter { shown.contains($0.key) } }
  }
}

/// Breaks the CADisplayLink → target retain cycle.
private final class ThumbnailTick: NSObject {
  weak var owner: ThumbnailRenderer?
  init(_ owner: ThumbnailRenderer) { self.owner = owner }
  @MainActor @objc func tick() { owner?.tick() }
}

/// A live miniature of a terminal screen. A session taller or wider than the
/// thumbnail shows the rows and columns around its cursor (where the prompt is).
@MainActor
final class SessionThumbnailView: UIView {
  /// The screen to draw: a tab's session, or a tmux session's snapshot
  /// (nil until its first capture).
  let source: @MainActor () -> Session?
  /// Default margin around the miniature, so a tile's rounded corners clip no text.
  static let inset: CGFloat = 5
  let inset: CGFloat
  /// Set by the thumbnail's tile, from its size.
  var fonts: FontSet? {
    didSet { if fonts !== oldValue { needsDraw = true; refreshSoon() } }
  }
  /// Where the last drawing put the grid.
  private(set) var grid: ThumbnailGrid?

  private var snapshot = FrameSnapshot()
  private var generation: UInt64 = .max
  private weak var session: Session?
  private var needsDraw = true
  private weak var owner: ThumbnailRenderer?

  override class var layerClass: AnyClass { CAMetalLayer.self }
  private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

  init(source: @escaping @MainActor () -> Session?, inset: CGFloat = SessionThumbnailView.inset) {
    self.source = source
    self.inset = inset
    super.init(frame: .zero)
    isOpaque = true
    isUserInteractionEnabled = false
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.isOpaque = true
    metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metalLayer.maximumDrawableCount = 2
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  func attach(to owner: ThumbnailRenderer) {
    self.owner = owner
    owner.add(self)
  }

  func detach() {
    owner?.remove(self)
    owner = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = traitCollection.displayScale
    metalLayer.contentsScale = scale
    let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    if metalLayer.drawableSize != size {
      metalLayer.drawableSize = size
      needsDraw = true
      refreshSoon()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    refreshSoon()
  }

  /// Draws right away instead of waiting for the next tick, so a thumbnail
  /// never shows an empty first frame.
  private func refreshSoon() {
    guard let owner, window != nil else { return }
    refresh(with: owner)
  }

  /// Where the grid is drawn now, after any pending redraw: the terminal
  /// zooming into this thumbnail lands its cells on these.
  func currentGrid() -> ThumbnailGrid? {
    refreshSoon()
    return grid
  }

  fileprivate func refresh(with owner: ThumbnailRenderer) {
    guard let current = source() else { return }
    if current !== session {
      session = current
      generation = .max
    }
    var frame = TermFrame()
    if current.frame(after: generation, into: &frame) {
      generation = frame.generation
      snapshot.load(frame)
      needsDraw = true
    }
    let size = metalLayer.drawableSize
    guard needsDraw, window != nil, size.width > 0, size.height > 0,
          let fonts, let renderer = owner.renderer(for: fonts) else { return }
    needsDraw = false
    var overlay = Renderer.Overlay()
    overlay.focused = false
    renderer.build(snapshot, overlay: overlay)
    let cell = fonts.metrics
    let pad = Int((inset * metalLayer.contentsScale).rounded())
    let firstRow = MenuLayout.thumbnailFirst(count: snapshot.rows, cursor: snapshot.cursorRow,
                                             visible: (Int(size.height) - pad) / max(cell.height, 1))
    let firstCol = MenuLayout.thumbnailFirst(count: snapshot.cols, cursor: snapshot.cursorCol,
                                             visible: (Int(size.width) - 2 * pad) / max(cell.width, 1))
    let placement = Renderer.Placement(
      viewport: SIMD2(Float(size.width), Float(size.height)),
      origin: SIMD2(Float(pad - firstCol * cell.width), Float(pad - firstRow * cell.height)))
    let scale = metalLayer.contentsScale
    grid = ThumbnailGrid(origin: CGPoint(x: CGFloat(pad - firstCol * cell.width) / scale, y: CGFloat(pad - firstRow * cell.height) / scale),
                         cell: CGSize(width: CGFloat(cell.width) / scale, height: CGFloat(cell.height) / scale))
    guard let drawable = metalLayer.nextDrawable(),
          let cb = renderer.encode(into: drawable.texture, placement: placement) else { return }
    cb.present(drawable)
    cb.commit()
  }
}

/// Where a thumbnail draws its session's grid, in the thumbnail's points:
/// the top-left corner of cell (0, 0), which may lie outside the thumbnail
/// when it shows the rows and columns around the cursor, and one cell's size.
struct ThumbnailGrid {
  var origin: CGPoint
  var cell: CGSize
}
