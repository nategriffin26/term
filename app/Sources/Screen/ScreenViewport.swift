import CoreGraphics

/// Where the Mac's picture sits on the Screen's stage. The Mac's space is
/// macOS global display coordinates in points (the main display's top-left
/// is the origin, y grows down); `region` is the part of it shown. Pure, so
/// tests feed it real arrangements.
struct ScreenViewport: Equatable {
  /// The part of the Mac's space shown: the union of the watched displays' frames.
  private(set) var region: CGRect
  /// Stage rectangle the region fits into at zoom 1: the stage less the toolbar.
  private(set) var fit: CGRect
  /// Stage rectangle nothing covers: `fit` less the keyboard and an open toolbar row.
  private(set) var visible: CGRect
  /// Most stage points per Mac point: two per pixel of the densest shown display.
  private(set) var maxScale: CGFloat
  /// 1 is Fit.
  private(set) var zoom: CGFloat = 1
  /// Stage position of the region's top-left corner.
  private(set) var origin: CGPoint = .zero

  /// Zoom a pinch may reach below Fit before it lets go and springs back.
  static let rubberZoom: CGFloat = 0.8

  init(region: CGRect, fit: CGRect, visible: CGRect, maxScale: CGFloat) {
    self.region = region
    self.fit = fit
    self.visible = visible
    self.maxScale = maxScale
    origin = clamped(.zero)
  }

  /// `displays` are the shown displays' frames in Mac points with their pixel widths.
  init(displays: [(frame: CGRect, pixelWidth: Int)], fit: CGRect, visible: CGRect) {
    let region = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    let density = displays.map { CGFloat($0.pixelWidth) / max($0.frame.width, 1) }.max() ?? 1
    self.init(region: region.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : region,
              fit: fit, visible: visible, maxScale: 2 * density)
  }

  var fitScale: CGFloat {
    guard region.width > 0, region.height > 0, fit.width > 0, fit.height > 0 else { return 1 }
    return min(fit.width / region.width, fit.height / region.height)
  }

  /// Stage points per Mac point.
  var scale: CGFloat { fitScale * zoom }

  var maxZoom: CGFloat { max(1, maxScale / fitScale) }

  // MARK: Mapping

  func stage(_ mac: CGPoint) -> CGPoint {
    CGPoint(x: origin.x + (mac.x - region.minX) * scale, y: origin.y + (mac.y - region.minY) * scale)
  }

  func stage(_ mac: CGRect) -> CGRect {
    let o = stage(mac.origin)
    return CGRect(x: o.x, y: o.y, width: mac.width * scale, height: mac.height * scale)
  }

  func mac(_ stage: CGPoint) -> CGPoint {
    CGPoint(x: region.minX + (stage.x - origin.x) / scale, y: region.minY + (stage.y - origin.y) / scale)
  }

  /// How far the Mac's pointer goes for a finger's travel on the glass in
  /// Trackpad Mode: the distance as drawn at this zoom, times the tracking speed.
  func pointerTravel(_ finger: CGVector, speed: CGFloat) -> CGVector {
    CGVector(dx: finger.dx * speed / scale, dy: finger.dy * speed / scale)
  }

  // MARK: Changes

  /// The stage, the toolbar, the keyboard or the shown displays changed.
  /// Fit stays Fit and a zoomed view keeps its place; covering part of the
  /// stage never moves the picture, uncovering brings it back.
  mutating func layout(fit: CGRect, visible: CGRect) {
    self.fit = fit
    self.visible = visible
    zoom = min(max(zoom, 1), maxZoom)
    origin = clamped(origin)
  }

  /// Fit, centred.
  mutating func fitNow() {
    zoom = 1
    origin = clamped(.zero)
  }

  /// A pinch step: zoom by `factor`, the Mac point that was under `anchor`
  /// lands under `location` (pinching zooms around the fingers, moving them pans).
  mutating func pinch(by factor: CGFloat, anchor: CGPoint, to location: CGPoint) {
    let held = mac(anchor)
    zoom = min(max(zoom * factor, Self.rubberZoom), maxZoom)
    origin = CGPoint(x: location.x - (held.x - region.minX) * scale, y: location.y - (held.y - region.minY) * scale)
    origin = clamped(origin)
  }

  /// Touch Mode's one-finger pan of a zoomed view.
  mutating func pan(by delta: CGVector) {
    origin = clamped(CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy))
  }

  /// Moves the picture with the pointer when its drawn position comes
  /// closer than `margin` to an edge of the visible area: by exactly the
  /// overshoot, as far as the region reaches.
  mutating func follow(_ pointer: CGPoint, margin: CGFloat = 32) {
    let p = stage(pointer)
    let m = min(margin, visible.width / 3, visible.height / 3)
    let inner = visible.insetBy(dx: m, dy: m)
    var shift = CGVector.zero
    if p.x < inner.minX { shift.dx = inner.minX - p.x } else if p.x > inner.maxX { shift.dx = inner.maxX - p.x }
    if p.y < inner.minY { shift.dy = inner.minY - p.y } else if p.y > inner.maxY { shift.dy = inner.maxY - p.y }
    guard shift != .zero else { return }
    pan(by: shift)
  }

  /// Where the picture may sit, per axis. Narrower than `fit`: centred in it,
  /// free only to move up from under the keyboard (or right from an open
  /// side row). Wider: its edges stop at the visible area's edges.
  private func clamped(_ value: CGPoint) -> CGPoint {
    func axis(_ value: CGFloat, size: CGFloat, fit: (CGFloat, CGFloat), visible: (CGFloat, CGFloat)) -> CGFloat {
      let centred = fit.0 + (fit.1 - fit.0 - size) / 2
      let low: CGFloat, high: CGFloat
      if size <= fit.1 - fit.0 + 0.5 {
        low = min(centred, visible.1 - size)
        high = max(centred, visible.0)
      } else {
        low = visible.1 - size
        high = visible.0
      }
      return min(max(value, low), max(low, high))
    }
    let s = scale
    return CGPoint(
      x: axis(value.x, size: region.width * s, fit: (fit.minX, fit.maxX), visible: (visible.minX, visible.maxX)),
      y: axis(value.y, size: region.height * s, fit: (fit.minY, fit.maxY), visible: (visible.minY, visible.maxY)))
  }
}

/// The Mac's displays as the pointer meets them.
enum ScreenArrangement {
  /// `point` kept on a display: unchanged on one, else the nearest point of
  /// the nearest display. The last row and column are a display's edge (the
  /// pointer stops at x = width - 1).
  static func clamp(_ point: CGPoint, to frames: [CGRect]) -> CGPoint {
    var best = point
    var bestDistance = CGFloat.infinity
    for f in frames where f.width > 0 && f.height > 0 {
      let p = CGPoint(x: min(max(point.x, f.minX), f.maxX - 1), y: min(max(point.y, f.minY), f.maxY - 1))
      let d = hypot(p.x - point.x, p.y - point.y)
      if d == 0 { return p }
      if d < bestDistance { best = p; bestDistance = d }
    }
    return best
  }

  /// The middle of an edge, or a corner, of the display the pointer is on:
  /// where an edge swipe sends it (the Dock, a full-screen app's menu bar, a Hot Corner).
  static func edgePoint(_ edges: Edges, on frame: CGRect) -> CGPoint {
    let x = edges.contains(.left) ? frame.minX : edges.contains(.right) ? frame.maxX - 1 : frame.midX
    let y = edges.contains(.top) ? frame.minY : edges.contains(.bottom) ? frame.maxY - 1 : frame.midY
    return CGPoint(x: x, y: y)
  }

  struct Edges: OptionSet, Hashable {
    let rawValue: Int
    static let top = Edges(rawValue: 1)
    static let left = Edges(rawValue: 2)
    static let bottom = Edges(rawValue: 4)
    static let right = Edges(rawValue: 8)
  }
}
