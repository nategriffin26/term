import SwiftUI
import UIKit

/// The floating menu: a glass card over the visible terminal (the safe
/// area above the keyboard), on a scrim. It grows out of the dock icon that
/// opened it and collapses back into it; without an icon it scales in.
/// Glass fades by materializing (its effect set in an animation), never by
/// alpha, which breaks the effect.
@MainActor
final class MenuPanel: UIViewController {
  let model: MenuModel
  /// Frame (in this view's space) of the dock icon for a tab, if one is on screen.
  var iconFrame: ((MenuTab) -> CGRect?)?
  /// Runs as the panel starts closing.
  var willClose: (() -> Void)?
  /// Runs when the window changes under the open panel (a fold, a rotation)
  /// and the keyboard leaves it too little room.
  var keyboardCrowds: (() -> Void)?

  private let scrim = UIView()
  private let card = UIView()
  private let glass = GlassView()
  private let clip = UIView()
  private let ghost = UIImageView()
  private let keyboardSpacer = UIView()
  private lazy var host = UIHostingController(rootView: MenuContent(model: model))
  private var cardAnimator: UIViewPropertyAnimator?
  private var contentAnimator: UIViewPropertyAnimator?
  private var landingAnimator: UIViewPropertyAnimator?
  private var openedFrom: MenuTab?

  init(model: MenuModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var isOpen: Bool { model.isOpen }

  override func loadView() {
    let root = PanelView()
    root.restingCard = { [weak self] in
      guard let self, isOpen, cardAnimator == nil else { return nil }
      return card.frame
    }
    view = root
    view.isHidden = true
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    scrim.backgroundColor = Chrome.UI.overlay
    scrim.alpha = 0
    scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
    view.addSubview(scrim)

    view.addSubview(card)
    card.addSubview(glass)

    clip.clipsToBounds = true
    card.addSubview(clip)
    setCorner(nil)

    addChild(host)
    host.safeAreaRegions = []
    host.view.backgroundColor = .clear
    clip.addSubview(host.view)
    host.didMove(toParent: self)

    ghost.tintColor = Chrome.UI.accent
    ghost.contentMode = .center
    ghost.alpha = 0
    card.addSubview(ghost)

    keyboardSpacer.isHidden = true
    keyboardSpacer.isUserInteractionEnabled = false
    keyboardSpacer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(keyboardSpacer)
    view.keyboardLayoutGuide.followsUndockedKeyboard = true
    NSLayoutConstraint.activate([
      keyboardSpacer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyboardSpacer.widthAnchor.constraint(equalToConstant: 1),
      keyboardSpacer.topAnchor.constraint(equalTo: view.topAnchor),
      keyboardSpacer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])
  }

  /// Top of the keyboard in this view's space (the safe area's bottom when it is down).
  private var keyboardTop: CGFloat { keyboardSpacer.frame.maxY }

  /// Whether the keyboard leaves the panel enough room.
  var fitsAboveKeyboard: Bool {
    view.layoutIfNeeded()
    return MenuLayout.fitsAboveKeyboard(bounds: view.bounds, safe: view.safeAreaInsets, keyboardTop: keyboardTop)
  }

  private var targetFrame: CGRect {
    MenuLayout.panelFrame(bounds: view.bounds, safe: view.safeAreaInsets, keyboardTop: keyboardTop)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrim.frame = view.bounds
    guard isOpen, cardAnimator == nil else { return }
    if !MenuLayout.fitsAboveKeyboard(bounds: view.bounds, safe: view.safeAreaInsets, keyboardTop: keyboardTop) {
      keyboardCrowds?()
    }
    place(targetFrame)
  }

  private func place(_ frame: CGRect) {
    setCardFrame(frame)
    host.view.frame = clip.bounds
    setCorner(nil)
  }

  /// The card and the glass and clip that fill it.
  private func setCardFrame(_ frame: CGRect) {
    card.frame = frame
    glass.frame = card.bounds
    clip.frame = card.bounds
  }

  // MARK: - Open and close

  /// Shows `tab`; when closed, opens out of that tab's dock icon if one is on screen.
  func open(_ tab: MenuTab, fromIcon: Bool) {
    model.tab = tab
    guard !isOpen else { return }
    model.isOpen = true
    view.isHidden = false
    view.layoutIfNeeded()

    let target = targetFrame
    let source = fromIcon ? iconFrame?(tab) : nil
    openedFrom = source == nil ? nil : tab
    stopAnimations()

    host.view.frame = CGRect(origin: .zero, size: target.size)
    host.view.layoutIfNeeded()
    host.view.alpha = 0
    host.view.transform = CGAffineTransform(translationX: 0, y: 10)
    card.transform = .identity
    if let source {
      setCardFrame(source)
      setCorner(min(source.width, source.height) / 2)
      UIView.performWithoutAnimation { glass.isGlassShown = true }
      showGhost(for: tab, in: source.size)
    } else {
      setCardFrame(target)
      setCorner(nil)
      glass.isGlassShown = false
      card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
      ghost.alpha = 0
    }

    let animator = UIViewPropertyAnimator(duration: Chrome.Panel.open, timingParameters: Chrome.Panel.spring(Chrome.Panel.open))
    animator.addAnimations { [self] in
      card.transform = .identity
      glass.isGlassShown = true
      setCardFrame(target)
      ghost.center = CGPoint(x: target.width / 2, y: target.height / 2)
      setCorner(nil)
      scrim.alpha = 1
    }
    animator.addCompletion { [weak self] _ in
      guard let self else { return }
      cardAnimator = nil
      place(targetFrame)
    }
    cardAnimator = animator
    animator.startAnimation()

    if source != nil {
      UIView.animate(withDuration: Chrome.Panel.contentIn, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { self.ghost.alpha = 0 }
    }
    let content = UIViewPropertyAnimator(duration: Chrome.Panel.contentIn, timingParameters: Chrome.fadeTiming)
    content.addAnimations { [self] in
      host.view.alpha = 1
      host.view.transform = .identity
    }
    contentAnimator = content
    content.startAnimation()
  }

  /// Closes into the dock icon it came from when that icon is still on screen.
  func close(completion: (() -> Void)? = nil) {
    guard isOpen else { completion?(); return }
    model.isOpen = false
    willClose?()
    stopAnimations()
    let tab = model.tab
    let end = openedFrom.flatMap { _ in iconFrame?(tab) }

    let content = UIViewPropertyAnimator(duration: Chrome.Panel.contentOut, timingParameters: Chrome.fadeTiming)
    content.addAnimations { [self] in host.view.alpha = 0 }
    contentAnimator = content
    content.startAnimation()

    ghost.alpha = 0
    let animator = UIViewPropertyAnimator(duration: Chrome.Panel.close, timingParameters: Chrome.Panel.spring(Chrome.Panel.close))
    animator.addAnimations { [self] in
      scrim.alpha = 0
      if let end {
        setCardFrame(end)
        setCorner(min(end.width, end.height) / 2)
      } else {
        glass.isGlassShown = false
        card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
      }
    }
    if end != nil {
      // The dock icon draws above the card: the card dissolves as it lands under it.
      let landing = UIViewPropertyAnimator(duration: Chrome.Panel.landing, curve: .easeIn) { self.glass.isGlassShown = false }
      landingAnimator = landing
      landing.startAnimation(afterDelay: Chrome.Panel.landingDelay)
    }
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      cardAnimator = nil
      guard position == .end, !isOpen else { return }
      view.isHidden = true
      card.transform = .identity
      ghost.alpha = 0
      host.view.transform = .identity
      completion?()
    }
    cardAnimator = animator
    animator.startAnimation()
  }

  /// Fades the panel out while something else (a tile zooming into the
  /// terminal) takes over the screen.
  func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) {
    guard isOpen else { completion(); return }
    model.isOpen = false
    willClose?()
    stopAnimations()
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: Chrome.fadeTiming)
    animator.addAnimations { [self] in
      scrim.alpha = 0
      glass.isGlassShown = false
      host.view.alpha = 0
    }
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      cardAnimator = nil
      guard position == .end, !isOpen else { return }
      view.isHidden = true
      completion()
    }
    cardAnimator = animator
    animator.startAnimation()
  }

  /// Cross-fade under a terminal shrinking into its tile: the card fades in
  /// in place instead of growing.
  func fadeIn(_ tab: MenuTab, duration: TimeInterval) {
    model.tab = tab
    guard !isOpen else { return }
    model.isOpen = true
    view.isHidden = false
    view.layoutIfNeeded()
    stopAnimations()
    openedFrom = nil
    card.transform = .identity
    place(targetFrame)
    host.view.layoutIfNeeded()
    host.view.alpha = 0
    host.view.transform = .identity
    ghost.alpha = 0
    glass.isGlassShown = false
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: Chrome.fadeTiming)
    animator.addAnimations { [self] in
      glass.isGlassShown = true
      host.view.alpha = 1
      scrim.alpha = 1
    }
    animator.addCompletion { [weak self] _ in
      guard let self else { return }
      cardAnimator = nil
      place(targetFrame)
    }
    cardAnimator = animator
    animator.startAnimation()
  }

  private func stopAnimations() {
    for animator in [cardAnimator, contentAnimator, landingAnimator].compactMap({ $0 }) where animator.state == .active {
      animator.stopAnimation(true)
    }
    cardAnimator = nil
    contentAnimator = nil
    landingAnimator = nil
  }

  /// `radius` while growing out of or into an icon; nil at rest: concentric
  /// with the display's rounded corners where the card nears them, the panel's radius elsewhere.
  private func setCorner(_ radius: CGFloat?) {
    let config: UICornerConfiguration = radius.map { .corners(radius: .fixed($0)) }
      ?? .corners(radius: .containerConcentric(minimum: Chrome.Radius.panel))
    glass.cornerConfiguration = config
    clip.cornerConfiguration = config
  }

  private func showGhost(for tab: MenuTab, in size: CGSize) {
    ghost.image = UIImage(systemName: tab.selectedSymbol, withConfiguration: Chrome.uiSymbol(.dock))
    ghost.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
    ghost.center = CGPoint(x: size.width / 2, y: size.height / 2)
    ghost.alpha = 1
    card.bringSubviewToFront(ghost)
  }

  @objc private func scrimTapped() { close() }
}

/// A back swipe from the screen's edge starts in the margin left of the
/// card, over the scrim: touches there go to the card's edge instead.
private final class PanelView: UIView {
  var restingCard: (() -> CGRect?)?
  /// UIKit hit-tests a touch twice, and SwiftUI answers a point outside the
  /// touch with its container the second time: both get the first answer.
  private struct Hit {
    let time: TimeInterval
    weak var view: UIView?
  }
  private var gutterHit: Hit?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let card = restingCard?(), point.x < card.minX, point.y > card.minY, point.y < card.maxY else {
      return super.hitTest(point, with: event)
    }
    if let event, let hit = gutterHit, hit.time == event.timestamp { return hit.view }
    let view = super.hitTest(CGPoint(x: card.minX + 1, y: point.y), with: event)
    gutterHit = event.map { Hit(time: $0.timestamp, view: view) }
    return view
  }
}
