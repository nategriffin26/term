import SwiftUI
import UIKit

/// The floating menu: a Helm-ink card over the visible terminal (the safe
/// area above the keyboard), on a scrim. It grows out of the dock icon that
/// opened it and collapses back into it; without an icon it scales in.
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
  private let clip = UIView()
  private let ghost = UIImageView()
  private let keyboardSpacer = UIView()
  private lazy var host = UIHostingController(rootView: MenuContent(model: model))
  private var cardAnimator: UIViewPropertyAnimator?
  private var contentAnimator: UIViewPropertyAnimator?
  private var landingAnimator: UIViewPropertyAnimator?
  private var openedFrom: MenuTab?

  static let cornerRadius: CGFloat = 18

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

  /// A layer's CGColor and the system controls' style do not follow the app theme by themselves.
  private func applyAppTheme() {
    card.layer.borderColor = Helm.UI.line2.resolvedColor(with: traitCollection).cgColor
    host.overrideUserInterfaceStyle = traitCollection[AppThemeTrait.self].isDark ? .dark : .light
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    scrim.backgroundColor = Helm.UI.overlay
    scrim.alpha = 0
    scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
    view.addSubview(scrim)

    card.backgroundColor = Helm.UI.raised
    card.layer.cornerCurve = .continuous
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in self.applyAppTheme() }
    applyAppTheme()
    card.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.45
    card.layer.shadowRadius = 25
    card.layer.shadowOffset = CGSize(width: 0, height: 18)
    view.addSubview(card)

    clip.clipsToBounds = true
    clip.layer.cornerCurve = .continuous
    card.addSubview(clip)
    setCorner(nil)

    addChild(host)
    host.safeAreaRegions = []
    host.view.backgroundColor = .clear
    clip.addSubview(host.view)
    host.didMove(toParent: self)

    ghost.tintColor = Helm.UI.accent
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
    card.frame = frame
    clip.frame = card.bounds
    host.view.frame = clip.bounds
    setCorner(nil)
    card.layer.shadowPath = Self.roundedPath(card.bounds, radii: [.topLeft, .topRight, .bottomRight, .bottomLeft].map {
      card.effectiveRadius(corner: $0)
    })
  }

  /// A rectangle with its own radius per corner, clockwise from the top left.
  private static func roundedPath(_ r: CGRect, radii: [CGFloat]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + radii[0], y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radii[1])
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radii[2])
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radii[3])
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radii[0])
    path.closeSubpath()
    return path
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

    card.layer.shadowPath = nil
    host.view.frame = CGRect(origin: .zero, size: target.size)
    host.view.layoutIfNeeded()
    host.view.alpha = 0
    host.view.transform = CGAffineTransform(translationX: 0, y: 10)
    if let source {
      card.transform = .identity
      card.alpha = 1
      card.frame = source
      clip.frame = card.bounds
      setCorner(min(source.width, source.height) / 2)
      showGhost(for: tab, in: source.size)
    } else {
      card.frame = target
      clip.frame = card.bounds
      setCorner(nil)
      card.alpha = 0
      card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
      ghost.alpha = 0
    }

    let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: Helm.springTiming)
    animator.addAnimations { [self] in
      card.transform = .identity
      card.alpha = 1
      card.frame = target
      clip.frame = CGRect(origin: .zero, size: target.size)
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
      UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { self.ghost.alpha = 0 }
    }
    let content = UIViewPropertyAnimator(duration: 0.3, timingParameters: Helm.easeTiming)
    content.addAnimations { [self] in
      host.view.alpha = 1
      host.view.transform = .identity
    }
    contentAnimator = content
    content.startAnimation(afterDelay: source == nil ? 0.04 : 0.14)
  }

  /// Closes into the dock icon it came from when that icon is still on screen.
  func close(completion: (() -> Void)? = nil) {
    guard isOpen else { completion?(); return }
    model.isOpen = false
    willClose?()
    stopAnimations()
    card.layer.shadowPath = nil
    let tab = model.tab
    let end = openedFrom.flatMap { _ in iconFrame?(tab) }

    let content = UIViewPropertyAnimator(duration: 0.14, timingParameters: Helm.easeTiming)
    content.addAnimations { [self] in host.view.alpha = 0 }
    contentAnimator = content
    content.startAnimation()

    ghost.alpha = 0
    let animator = UIViewPropertyAnimator(duration: end == nil ? 0.3 : 0.42, timingParameters: Helm.springTiming)
    animator.addAnimations { [self] in
      scrim.alpha = 0
      if let end {
        card.frame = end
        clip.frame = CGRect(origin: .zero, size: end.size)
        setCorner(min(end.width, end.height) / 2)
      } else {
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
      }
    }
    if end != nil {
      // The dock icon draws above the card: the card thins out as it lands under it.
      let landing = UIViewPropertyAnimator(duration: 0.2, curve: .easeIn) { self.card.alpha = 0 }
      landingAnimator = landing
      landing.startAnimation(afterDelay: 0.18)
    }
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      cardAnimator = nil
      guard position == .end, !isOpen else { return }
      view.isHidden = true
      card.alpha = 1
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
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: Helm.easeTiming)
    animator.addAnimations { [self] in
      scrim.alpha = 0
      card.alpha = 0
    }
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      cardAnimator = nil
      guard position == .end, !isOpen else { return }
      view.isHidden = true
      card.alpha = 1
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
    place(targetFrame)
    host.view.layoutIfNeeded()
    host.view.alpha = 1
    host.view.transform = .identity
    ghost.alpha = 0
    card.transform = .identity
    card.alpha = 0
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: Helm.easeTiming)
    animator.addAnimations { [self] in
      card.alpha = 1
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
  /// with the display's rounded corners where the card nears them, 18 pt elsewhere.
  private func setCorner(_ radius: CGFloat?) {
    let config: UICornerConfiguration = radius.map { .corners(radius: .fixed($0)) }
      ?? .corners(radius: .containerConcentric(minimum: Self.cornerRadius))
    card.cornerConfiguration = config
    clip.cornerConfiguration = config
  }

  private func showGhost(for tab: MenuTab, in size: CGSize) {
    ghost.image = UIImage(systemName: tab.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
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
