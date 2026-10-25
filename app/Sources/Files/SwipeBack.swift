import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The UIKit side of the Files stack (folders, and files pushed over them).
/// Every page hides the navigation bar and draws its own; this sits behind
/// each page and gives the stack what the hidden bar takes away, with the
/// feel of Context's Files:
/// - Back swipes, from the edge or anywhere on the page, rows included, while
///   there is a page beneath and the top page shows a back button (the viewer
///   hides it while edits are unsaved, so only its Back, which asks, leaves),
///   and never over content that can still scroll left (an unwrapped line, a
///   zoomed image, a wide table). The page follows the finger and goes back
///   when let go past half way or flicked. Row swipes go left, so they keep theirs.
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
    /// A release this fast (pt/s) goes the way the finger is moving, wherever the page is.
    static let flick: CGFloat = 300

    nonisolated(unsafe) private static var key = 0
    private weak var nav: UINavigationController?
    private weak var decorated: (any UIViewControllerTransitionCoordinator)?
    private let swipe = BackPan()
    private let relay = Relay()
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
      // UIKit's own back swipes stay off; `swipe` replaces both. The content
      // swipe starts only after 30 pt, by when a row's long press (its menu,
      // or dragging it out) has taken a slow swipe, and it judges the release
      // against the screen rather than this inset page.
      nav.interactivePopGestureRecognizer?.delegate = self
      nav.interactiveContentPopGestureRecognizer?.delegate = self
      swipe.addTarget(self, action: #selector(swiped(_:)))
      swipe.maximumNumberOfTouches = 1
      swipe.delegate = self
      nav.view.addGestureRecognizer(swipe)
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

    // MARK: Back

    @objc private func swiped(_ pan: BackPan) {
      guard let nav else { return }
      if pan.state == .began, nav.viewControllers.count > 1 {
        // In front of SwiftUI's delegate, which keeps every message it handles.
        if nav.delegate !== relay {
          relay.inner = nav.delegate
          nav.delegate = relay
        }
        let pop = UIPercentDrivenInteractiveTransition()
        pop.completionCurve = .easeOut
        relay.pop = pop
        nav.popViewController(animated: true)
      }
      guard let pop = relay.pop else { return give(pan) }
      let width = max(nav.view.bounds.width, 1)
      switch pan.state {
      case .began, .changed:
        pop.update(min(max(pan.travel.x / width, 0), 0.999))
      default:
        let speed = pan.velocity(in: nil).x
        let back = pan.state == .ended && (speed > Self.flick || (speed > -Self.flick && pan.travel.x > width / 2))
        if back { pop.finish() } else { pop.cancel() }
        relay.pop = nil
      }
    }

    // MARK: Give

    private func give(_ pan: BackPan) {
      guard let page = nav?.view else { return }
      switch pan.state {
      case .began:
        // Caught while springing home: carry on from where it is.
        settle?.stopAnimation(true)
        settle = nil
        let x = min(max(page.transform.tx, 0), Self.give - 1)
        giveFrom = 2 * Self.give * x / (Self.give - x)
        Self.shadow(page, on: true)
        fallthrough
      case .changed:
        let pull = max(0, giveFrom + pan.travel.x)
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
      guard gesture === swipe, let nav, nav.transitionCoordinator == nil else { return false }
      let travel = swipe.travel
      guard travel.x > abs(travel.y), !offLeftEdge(swipe) else { return false }
      return nav.viewControllers.count == 1 || nav.topViewController?.navigationItem.hidesBackButton == false
    }

    /// Whether the touch is on something moved left of where it rests, which
    /// a right swipe should bring back instead: content scrolled away from its
    /// left edge, or a row swiped open on its Delete (UIKit lays that row's
    /// actions view over it).
    private func offLeftEdge(_ pan: UIPanGestureRecognizer) -> Bool {
      var view = pan.view?.hitTest(pan.location(in: pan.view), with: nil)
      while let current = view, current !== pan.view {
        if let scroll = current as? UIScrollView, scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5 { return true }
        if NSStringFromClass(type(of: current)).contains("SwipeActionsView") { return true }
        view = current.superview
      }
      return false
    }
  }

  /// A pan that knows within a few points whether the finger is heading right
  /// and then starts at once, before a row's long press can take the touch.
  final class BackPan: UIPanGestureRecognizer {
    /// How far the finger goes before its heading counts (pt): past a still
    /// finger's tremor, about where UIKit's own pans start.
    static let decide: CGFloat = 8
    private var start: CGPoint?

    /// Where the finger is from where it touched down.
    var travel: CGPoint {
      guard let start else { return .zero }
      let now = location(in: nil)
      return CGPoint(x: now.x - start.x, y: now.y - start.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesBegan(touches, with: event)
      if start == nil { start = location(in: nil) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesMoved(touches, with: event)
      guard state == .possible, hypot(travel.x, travel.y) >= Self.decide else { return }
      state = travel.x > abs(travel.y) ? .began : .failed
    }

    override func reset() {
      super.reset()
      start = nil
    }
  }

  /// The stack's delegate while swipes drive its pops: hands UIKit the swipe's
  /// pop and passes everything else to SwiftUI's delegate behind it.
  private final class Relay: NSObject, UINavigationControllerDelegate {
    weak var inner: (any UINavigationControllerDelegate)?
    /// The pop a swipe is driving.
    var pop: UIPercentDrivenInteractiveTransition?

    func navigationController(_ nav: UINavigationController, animationControllerFor operation: UINavigationController.Operation, from: UIViewController, to: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
      if pop != nil, operation == .pop { return PopAnimator() }
      return inner?.navigationController?(nav, animationControllerFor: operation, from: from, to: to)
    }

    func navigationController(_ nav: UINavigationController, interactionControllerFor animator: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)? {
      animator is PopAnimator ? pop : inner?.navigationController?(nav, interactionControllerFor: animator)
    }

    func navigationController(_ nav: UINavigationController, willShow page: UIViewController, animated: Bool) {
      inner?.navigationController?(nav, willShow: page, animated: animated)
    }

    func navigationController(_ nav: UINavigationController, didShow page: UIViewController, animated: Bool) {
      inner?.navigationController?(nav, didShow: page, animated: animated)
    }
  }

  /// UIKit's pop, for a swipe to drive: the page slides off to the right over
  /// the one beneath, which comes in from a little to the left.
  private final class PopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private var running: UIViewPropertyAnimator?

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.35 }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
      interruptibleAnimator(using: context).startAnimation()
    }

    func interruptibleAnimator(using context: any UIViewControllerContextTransitioning) -> any UIViewImplicitlyAnimating {
      if let running { return running }
      // A navigation transition always has both pages.
      let from = context.view(forKey: .from)!
      let to = context.view(forKey: .to)!
      let width = context.containerView.bounds.width
      if let page = context.viewController(forKey: .to) { to.frame = context.finalFrame(for: page) }
      to.transform = CGAffineTransform(translationX: -0.3 * width, y: 0)
      context.containerView.insertSubview(to, belowSubview: from)
      let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .linear) {
        from.transform = CGAffineTransform(translationX: width, y: 0)
        to.transform = .identity
      }
      animator.addCompletion { _ in
        from.transform = .identity
        to.transform = .identity
        context.completeTransition(!context.transitionWasCancelled)
      }
      running = animator
      return animator
    }

    func animationEnded(_ transitionCompleted: Bool) { running = nil }
  }
}
