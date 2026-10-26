import CoreGraphics

/// Where terminal panes go in a window, from the view's own geometry only:
/// bounds, safe area (which holds the iPhone Duo vertical bar) and the fold.
/// Panes reach the window edges so the terminal background runs under the
/// bars; each terminal keeps its text inside its own safe area.
enum SpaceLayout: Equatable {
  /// One terminal.
  case single(CGRect)
  /// Two terminals side by side: either side of a book fold, or split by choice.
  case sideBySide(CGRect, CGRect)
  /// Tabletop fold: terminal in the top half, the bottom half left to the keyboard.
  case tabletop(CGRect)

  /// Narrowest pane worth splitting for when the device lies flat (about 40 columns).
  static let minimumSplitPaneWidth: CGFloat = 320
  /// Gap between panes split without a fold: a hairline with 6 pt either side
  /// so neither pane's text runs into it.
  static let splitGap: CGFloat = 13

  /// - Parameters:
  ///   - bounds: the view's bounds.
  ///   - safe: the view's safe area as a rect in the same space.
  ///   - division: the active fold region (UIView.reservedRegions(kind: .division)), if any.
  ///   - splitWhenFlat: the user's choice to show two panes without a fold.
  ///   - regularWidth: horizontal size class is regular (inner display).
  static func compute(bounds: CGRect, safe: CGRect, division: CGRect?, splitWhenFlat: Bool, regularWidth: Bool) -> SpaceLayout {
    if let fold = division, fold.intersects(safe) {
      if fold.height >= fold.width {
        // Book: fold runs top to bottom; one session per half.
        let left = CGRect(x: bounds.minX, y: bounds.minY, width: max(fold.minX - bounds.minX, 0), height: bounds.height)
        let right = CGRect(x: fold.maxX, y: bounds.minY, width: max(bounds.maxX - fold.maxX, 0), height: bounds.height)
        return .sideBySide(left, right)
      }
      // Tabletop: fold runs side to side; terminal stays above it.
      return .tabletop(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(fold.minY - bounds.minY, 0)))
    }
    if splitWhenFlat, regularWidth, safe.width >= 2 * minimumSplitPaneWidth + splitGap {
      // Halve the safe area so the vertical bar doesn't make one pane narrower.
      let w = ((safe.width - splitGap) / 2).rounded(.down)
      return .sideBySide(
        CGRect(x: bounds.minX, y: bounds.minY, width: safe.minX + w - bounds.minX, height: bounds.height),
        CGRect(x: safe.maxX - w, y: bounds.minY, width: bounds.maxX - (safe.maxX - w), height: bounds.height))
    }
    return .single(bounds)
  }

  var panes: [CGRect] {
    switch self {
    case .single(let r), .tabletop(let r): [r]
    case .sideBySide(let a, let b): [a, b]
    }
  }
}
