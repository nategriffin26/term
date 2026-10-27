import CoreGraphics
import UIKit

/// Where the menu panel goes: over the visible terminal, the safe area above
/// the keyboard, with small margins. Pure, so tests can feed real geometry.
enum MenuLayout {
  /// Space between the panel and the visible area's edges.
  static let margin: CGFloat = 8
  /// Shortest useful panel; when the keyboard leaves less, it goes away.
  static let minimumHeight: CGFloat = 280

  /// The part of the window the terminal shows: the safe area, cut at the
  /// keyboard's top edge when the keyboard reaches into it. `keyboardTop` is
  /// in the same space as `bounds`; nil or at/below the bottom = no keyboard.
  static func visibleArea(bounds: CGRect, safe: UIEdgeInsets, keyboardTop: CGFloat?) -> CGRect {
    var area = bounds.inset(by: safe)
    if let top = keyboardTop, top < area.maxY {
      area.size.height = max(0, top - area.minY)
    }
    return area
  }

  /// Whether the panel fits above the keyboard; when not, it opens over the
  /// whole safe area and the keyboard is dismissed while it is open.
  static func fitsAboveKeyboard(bounds: CGRect, safe: UIEdgeInsets, keyboardTop: CGFloat?) -> Bool {
    visibleArea(bounds: bounds, safe: safe, keyboardTop: keyboardTop).height - 2 * margin >= minimumHeight
  }

  static func panelFrame(bounds: CGRect, safe: UIEdgeInsets, keyboardTop: CGFloat?) -> CGRect {
    let area = fitsAboveKeyboard(bounds: bounds, safe: safe, keyboardTop: keyboardTop)
      ? visibleArea(bounds: bounds, safe: safe, keyboardTop: keyboardTop)
      : visibleArea(bounds: bounds, safe: safe, keyboardTop: nil)
    return area.insetBy(dx: margin, dy: margin)
  }

  /// The first grid row (or column) a thumbnail `visible` cells tall (or
  /// wide) shows: the cursor's row stays in view with as much above it as
  /// fits. A session taller than its tile (sized while hidden, without the
  /// keyboard) shows its top when the cursor is there, its bottom when the
  /// prompt has scrolled down; a session wider than its legible tile shows
  /// its left edge unless the cursor is past it.
  static func thumbnailFirst(count: Int, cursor: Int, visible: Int) -> Int {
    let shown = max(visible, 1)
    let last = min(count, max(cursor + 1, shown))
    return max(0, last - shown)
  }
}

/// The session HUD's row of dots. Up to `maxVisible` dots show at once; with
/// more sessions the row is a window around the current one, and a dot at a
/// window edge with sessions beyond it is drawn small (like UIPageControl).
struct DotStrip: Equatable {
  struct Dot: Equatable {
    var index: Int
    var scale: CGFloat
  }

  /// Dots shown, left to right.
  var dots: [Dot]
  /// The highlight's place in the row, in dot slots (0 = first shown dot);
  /// fractional mid-swipe.
  var highlight: CGFloat

  static let maxVisible = 7
  static let edgeScale: CGFloat = 0.5

  /// - Parameters:
  ///   - count: sessions in the window.
  ///   - position: the current session's index; fractional while a swipe is between two.
  static func layout(count: Int, position: CGFloat, maxVisible: Int = DotStrip.maxVisible) -> DotStrip {
    guard count > 0 else { return DotStrip(dots: [], highlight: 0) }
    let p = min(max(position, 0), CGFloat(count - 1))
    let shown = min(count, maxVisible)
    let first = min(max(Int(p.rounded()) - shown / 2, 0), count - shown)
    let last = first + shown - 1
    let dots = (first...last).map { i in
      let clipped = (i == first && first > 0) || (i == last && last < count - 1)
      return Dot(index: i, scale: clipped ? edgeScale : 1)
    }
    return DotStrip(dots: dots, highlight: p - CGFloat(first))
  }
}
