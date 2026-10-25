import SwiftUI
import UIKit

/// Every page here hides the navigation bar and draws its own, and UIKit turns
/// both back swipes off when the bar is hidden. This turns them back on for the
/// stack it sits in: a swipe right pops while there is a page beneath and the top
/// page shows a back button (the viewer hides it while edits are unsaved, so only
/// its Back, which asks, leaves). The swipe works from anywhere on the page, since
/// the panel sits inset from the screen edge, except over content that can still
/// scroll left (an unwrapped line, a zoomed image, a wide table).
struct SwipeBack: UIViewRepresentable {
  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ probe: Probe, context: Context) {}

  final class Probe: UIView {
    override func didMoveToWindow() {
      super.didMoveToWindow()
      isUserInteractionEnabled = false
      var responder = next
      while let current = responder, !(current is UINavigationController) { responder = current.next }
      guard let nav = responder as? UINavigationController, objc_getAssociatedObject(nav, &Gate.key) == nil else { return }
      let gate = Gate(nav: nav)
      objc_setAssociatedObject(nav, &Gate.key, gate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      nav.interactivePopGestureRecognizer?.delegate = gate
      nav.interactiveContentPopGestureRecognizer?.delegate = gate
    }
  }

  /// Replaces UIKit's own delegate, which refuses every touch while the bar is
  /// hidden.
  final class Gate: NSObject, UIGestureRecognizerDelegate {
    nonisolated(unsafe) static var key = 0
    weak var nav: UINavigationController?

    init(nav: UINavigationController) { self.nav = nav }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let nav, nav.viewControllers.count > 1, let top = nav.topViewController,
            !top.navigationItem.hidesBackButton, nav.transitionCoordinator == nil else { return false }
      guard gesture === nav.interactiveContentPopGestureRecognizer, let pan = gesture as? UIPanGestureRecognizer else { return true }
      guard pan.velocity(in: pan.view).x > 0 else { return false }
      var view = pan.view?.hitTest(pan.location(in: pan.view), with: nil)
      while let current = view, current !== pan.view {
        if let scroll = current as? UIScrollView, scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5 { return false }
        view = current.superview
      }
      return true
    }
  }
}
