import SwiftUI
import UIKit

/// The UIKit side of the Files stack (folders, and files pushed over them).
/// Every page hides the navigation bar and draws its own; this sits behind
/// each page and gives the stack what the hidden bar takes away, with the
/// feel of Context's Files:
/// - Back swipes. UIKit turns both off while the bar is hidden; this turns
///   them back on, from the edge or anywhere on the page (iOS's content swipe),
///   while there is a page beneath and the top page shows a back button (the
///   viewer hides it while edits are unsaved, so only its Back, which asks,
///   leaves), and never over content that can still scroll left (an unwrapped
///   line, a zoomed image, a wide table). Row swipes go left, so they keep theirs.
/// - Depth. Every push and pop, by button or swipe, casts the top page's
///   shadow over the page beneath, which dims as it is covered and brightens
///   as it is uncovered (UIKit's own are lost on these dark pages).
/// - Give. On the first page there is nothing to go back to: a swipe moves it
///   a little, less the further the finger goes, and it springs home.
struct SwipeBack: UIViewRepresentable {
  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ probe: Probe, context: Context) {}

  /// Finds the page's navigation controller; a page coming on screen while
  /// the stack moves is a push or pop starting.
  final class Probe: UIView {
    override func didMoveToWindow() {
      super.didMoveToWindow()
      isUserInteractionEnabled = false
      guard window != nil else { return }
      var responder = next
      while let current = responder, !(current is UINavigationController) { responder = current.next }
      guard let nav = responder as? UINavigationController else { return }
      Stack.of(nav).pageArrived()
    }
  }

  @MainActor
  final class Stack: NSObject, UIGestureRecognizerDelegate {
    /// How dark the page beneath is while fully covered.
    static let veil: CGFloat = 0.32
    /// How far the first page gives at most (pt).
    static let give: CGFloat = 56

    nonisolated(unsafe) private static var key = 0
    private weak var nav: UINavigationController?
    private weak var decorated: (any UIViewControllerTransitionCoordinator)?
    private let giveSwipe = UIPanGestureRecognizer()
    private var giveFrom: CGFloat = 0
    private var settle: UIViewPropertyAnimator?

    static func of(_ nav: UINavigationController) -> Stack {
      if let stack = objc_getAssociatedObject(nav, &key) as? Stack { return stack }
      let stack = Stack(nav: nav)
      objc_setAssociatedObject(nav, &key, stack, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      return stack
    }

    private init(nav: UINavigationController) {
      self.nav = nav
      super.init()
      // Replaces UIKit's own delegate, which refuses every touch while the bar is hidden.
      nav.interactivePopGestureRecognizer?.delegate = self
      nav.interactiveContentPopGestureRecognizer?.delegate = self
      giveSwipe.addTarget(self, action: #selector(giving(_:)))
      giveSwipe.maximumNumberOfTouches = 1
      giveSwipe.delegate = self
      nav.view.addGestureRecognizer(giveSwipe)
    }

    // MARK: Depth

    /// A page came on screen: when the stack is moving, shade the move.
    func pageArrived() {
      guard let nav, let coordinator = nav.transitionCoordinator, coordinator !== decorated,
            let from = coordinator.viewController(forKey: .from)?.view,
            let to = coordinator.viewController(forKey: .to)?.view,
            let leaving = coordinator.viewController(forKey: .from) else { return }
      decorated = coordinator
      let popping = !nav.viewControllers.contains(leaving)
      let top = popping ? from : to
      let beneath = popping ? to : from
      let veil = UIView(frame: beneath.bounds)
      veil.backgroundColor = .black
      veil.isUserInteractionEnabled = false
      veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      veil.alpha = popping ? Self.veil : 0
      beneath.addSubview(veil)
      Self.shadow(top, on: true)
      coordinator.animate(alongsideTransition: { _ in
        veil.alpha = popping ? 0 : Self.veil
      }, completion: { _ in
        veil.removeFromSuperview()
        Self.shadow(top, on: false)
      })
    }

    private static func shadow(_ view: UIView, on: Bool) {
      view.layer.shadowColor = UIColor.black.cgColor
      view.layer.shadowOffset = .zero
      view.layer.shadowRadius = 11
      view.layer.shadowOpacity = on ? 0.55 : 0
      view.layer.shadowPath = on ? UIBezierPath(rect: view.bounds).cgPath : nil
    }

    // MARK: Give

    @objc private func giving(_ pan: UIPanGestureRecognizer) {
      guard let page = nav?.view else { return }
      switch pan.state {
      case .began:
        // Caught while springing home: carry on from where it is.
        settle?.stopAnimation(true)
        settle = nil
        let x = min(max(page.transform.tx, 0), Self.give - 1)
        giveFrom = 2 * Self.give * x / (Self.give - x)
        Self.shadow(page, on: true)
      case .changed:
        let pull = max(0, giveFrom + pan.translation(in: nil).x)
        page.transform = CGAffineTransform(translationX: Self.give * pull / (pull + 2 * Self.give), y: 0)
      default:
        let spring = UIViewPropertyAnimator(duration: 0.4, dampingRatio: 1) { page.transform = .identity }
        spring.addCompletion { [weak self] position in
          guard position == .end else { return }
          Self.shadow(page, on: false)
          self?.settle = nil
        }
        settle = spring
        spring.startAnimation()
      }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let nav, nav.transitionCoordinator == nil else { return false }
      if gesture === giveSwipe {
        let v = giveSwipe.velocity(in: nil)
        return nav.viewControllers.count == 1 && v.x > abs(v.y) && !overScrolled(giveSwipe)
      }
      guard nav.viewControllers.count > 1, let top = nav.topViewController, !top.navigationItem.hidesBackButton else { return false }
      guard gesture === nav.interactiveContentPopGestureRecognizer, let pan = gesture as? UIPanGestureRecognizer else { return true }
      return pan.velocity(in: pan.view).x > 0 && !overScrolled(pan)
    }

    /// A row left open on its Delete closes under the give, as it does under
    /// a back swipe; the list's scroll stays out of it.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      gesture === giveSwipe && other !== (other.view as? UIScrollView)?.panGestureRecognizer
    }

    /// Whether the touch is on content scrolled away from its left edge.
    private func overScrolled(_ pan: UIPanGestureRecognizer) -> Bool {
      var view = pan.view?.hitTest(pan.location(in: pan.view), with: nil)
      while let current = view, current !== pan.view {
        if let scroll = current as? UIScrollView, scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5 { return true }
        view = current.superview
      }
      return false
    }
  }
}
