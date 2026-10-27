import UIKit

/// The system text loupe over a selection being dragged, as iOS text views
/// show it: it follows the finger, sits above the line being aimed at and
/// goes when the finger lifts. A long press that has only selected a word
/// arms it; it appears once the finger starts extending the selection.
/// The system lens stands about 120 pt above the line it magnifies and has no
/// screen-edge clamp, in a UITextView as here: aimed at the first rows it sits
/// above the screen. Offsetting the caret to keep it on screen shifts what it
/// magnifies too, so the lens is left to the system.
@MainActor
final class SelectionLoupe {
    /// How far a long press must move before it is extending a selection.
    static let slop: CGFloat = 6

    private var session: UITextLoupeSession?
    private var armedAt: CGPoint?
    /// The point the loupe last looked at.
    private(set) var lookingAt: CGPoint?

    var isShowing: Bool { session != nil }

    static func hasLeft(_ origin: CGPoint, for point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) >= slop
    }

    /// A long press began at `point`; the loupe waits for the finger to move.
    func arm(at point: CGPoint) {
        end()
        armedAt = point
    }

    /// Shows the loupe at `point` or moves it there. `caret` is the selection
    /// edge being placed, which the loupe follows from cell to cell; `widget`
    /// is the handle being dragged, which the loupe rises from.
    func move(to point: CGPoint, caret: CGRect, widget: UIView? = nil, in view: UIView) {
        if let session {
            lookingAt = point
            session.move(to: point, withCaretRect: caret, trackingCaret: true)
            return
        }
        if let origin = armedAt {
            guard Self.hasLeft(origin, for: point) else { return }
            armedAt = nil
        }
        lookingAt = point
        session = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: widget, in: view)
    }

    func end() {
        armedAt = nil
        lookingAt = nil
        session?.invalidate()
        session = nil
    }
}
