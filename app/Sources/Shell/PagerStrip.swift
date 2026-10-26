import CoreGraphics

/// Where the three pages of a session swipe sit: a strip of previous, current
/// and next, one pane width apart. The finger shifts the whole strip and a
/// release settles it with one page at rest, so no page ever crosses another.
struct PagerStrip: Equatable {
  var previous: CGFloat
  var current: CGFloat
  var next: CGFloat

  enum Page { case previous, current, next }

  /// The strip `x` points from where it rests on the current page.
  static func dragged(by x: CGFloat, width: CGFloat) -> PagerStrip {
    PagerStrip(previous: x - width, current: x, next: x + width)
  }

  /// The strip at rest on `page`.
  static func resting(on page: Page, width: CGFloat) -> PagerStrip {
    switch page {
    case .previous: dragged(by: width, width: width)
    case .current: dragged(by: 0, width: width)
    case .next: dragged(by: -width, width: width)
    }
  }
}
