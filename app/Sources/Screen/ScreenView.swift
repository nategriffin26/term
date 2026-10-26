import GameController
import SwiftUI
import UIKit

/// The Screen's surface: the Mac's displays where the viewport puts them,
/// the pointer, the held-button indicator, every gesture of Screens'
/// interaction model (spec §2–§3), the hidden key input and the toolbar.
@MainActor
final class ScreenView: UIView, UIGestureRecognizerDelegate, ScreenSurface {
  /// The spec's [inferred] values.
  private enum Tune {
    static let holdDelay: TimeInterval = 0.30
    static let holdSlop: CGFloat = 10
    static let followMargin: CGFloat = 32
    static let clickInterval: TimeInterval = 0.5
    static let clickDistance: CGFloat = 24
    static let pinchStart: CGFloat = 0.04
    static let scrollStart: CGFloat = 10
    static let swipeDistance: CGFloat = 60
    static let edgeBand: CGFloat = 20
    static let corner: CGFloat = 32
    static let autoScrollSpeed: CGFloat = 900
    static let indicatorSize: CGFloat = 44
    /// The toolbar's distance from the stage's edges.
    static let barInset: CGFloat = 8
    /// Taller than a hardware keyboard's shortcut bar, shorter than any software keyboard.
    static let softKeyboardHeight: CGFloat = 120
  }

  let session: ScreenSession
  let input = ScreenKeyInput()
  private lazy var toolbar = ScreenToolbar(session: session, input: input)
  private let stage = CALayer()
  private var placeholders: [UInt32: CALayer] = [:]
  private var videos: [UInt32: CALayer] = [:]
  private let cursorLayer = CALayer()
  private let indicator = CAShapeLayer()
  private let keyboardSpacer = UIView()
  /// The stage's size while no keyboard shows: the picture keeps its place when one comes up.
  private var restingSize = CGSize.zero
  private var shownIDs: [UInt32] = []

  private var lastTap: (time: CFTimeInterval, stage: CGPoint, mac: CGPoint, count: Int) = (0, .zero, .zero, 0)
  private enum TwoFinger { case undecided, scroll, pinch }
  private var twoFinger = TwoFinger.undecided
  private var pinchAnchor = CGPoint.zero
  /// Where the last one-finger touch went down.
  private var touchDown = CGPoint.zero
  private var phaser = ScrollPhaser()
  private var momentum: CADisplayLink?
  private var autoScroll: CADisplayLink?
  private var dragFinger = CGPoint.zero
  private var swipeSent = false

  private let tap = UITapGestureRecognizer()
  private let secondary = UITapGestureRecognizer()
  private let fullscreen = UITapGestureRecognizer()
  private let middle = UITapGestureRecognizer()
  private let pointerPan = UIPanGestureRecognizer()
  private let scrollPan = UIPanGestureRecognizer()
  private let pinch = UIPinchGestureRecognizer()
  private let swipe = UIPanGestureRecognizer()
  private let edgePan = UIPanGestureRecognizer()
  private let holds = (1...3).map { _ in UILongPressGestureRecognizer() }

  init(session: ScreenSession) {
    self.session = session
    super.init(frame: .zero)
    clipsToBounds = true
    isMultipleTouchEnabled = true
    backgroundColor = Chrome.UI.bg
    layer.addSublayer(stage)
    cursorLayer.isHidden = true
    cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
    layer.addSublayer(cursorLayer)
    indicator.opacity = 0
    layer.addSublayer(indicator)

    input.session = session
    input.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    addSubview(input)
    addSubview(toolbar)
    toolbar.onEdgeSwipe = { [weak self] edges in self?.jump(to: edges) }

    keyboardSpacer.isHidden = true
    keyboardSpacer.isUserInteractionEnabled = false
    keyboardSpacer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(keyboardSpacer)
    keyboardLayoutGuide.followsUndockedKeyboard = true
    NSLayoutConstraint.activate([
      keyboardSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
      keyboardSpacer.widthAnchor.constraint(equalToConstant: 1),
      keyboardSpacer.topAnchor.constraint(equalTo: topAnchor),
      keyboardSpacer.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
    ])

    installGestures()
    session.surface = self
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in
      self.backgroundColor = Chrome.UI.bg
      self.stylePlaceholders()
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  // MARK: - Gestures

  private func installGestures() {
    tap.addTarget(self, action: #selector(tapped(_:)))
    secondary.addTarget(self, action: #selector(secondaryClick(_:)))
    secondary.numberOfTouchesRequired = 2
    fullscreen.addTarget(self, action: #selector(toggleFullscreen(_:)))
    fullscreen.numberOfTouchesRequired = 2
    fullscreen.numberOfTapsRequired = 2
    secondary.require(toFail: fullscreen)
    middle.addTarget(self, action: #selector(middleClick(_:)))
    middle.numberOfTouchesRequired = 3
    pointerPan.addTarget(self, action: #selector(pointerPanned(_:)))
    pointerPan.maximumNumberOfTouches = 1
    scrollPan.addTarget(self, action: #selector(scrolled(_:)))
    scrollPan.minimumNumberOfTouches = 2
    scrollPan.maximumNumberOfTouches = 2
    pinch.addTarget(self, action: #selector(pinched(_:)))
    swipe.addTarget(self, action: #selector(swiped(_:)))
    swipe.minimumNumberOfTouches = 3
    swipe.maximumNumberOfTouches = 3
    edgePan.addTarget(self, action: #selector(edgeSwiped(_:)))
    edgePan.maximumNumberOfTouches = 1
    pointerPan.require(toFail: edgePan)
    for (i, hold) in holds.enumerated() {
      hold.addTarget(self, action: #selector(held(_:)))
      hold.numberOfTouchesRequired = i + 1
      hold.minimumPressDuration = Tune.holdDelay
      hold.allowableMovement = Tune.holdSlop
    }
    for g in [tap, secondary, fullscreen, middle, pointerPan, scrollPan, pinch, swipe, edgePan] + holds {
      g.delegate = self
      addGestureRecognizer(g)
    }
  }

  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    // Two fingers both scroll and pinch until one wins (§3.3).
    (g === scrollPan && other === pinch) || (g === pinch && other === scrollPan)
  }

  override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    guard session.drivable, !isOnToolbar(g) else { return false }
    if g === edgePan { return edges(for: edgePan) != nil }
    return true
  }

  private func isOnToolbar(_ g: UIGestureRecognizer) -> Bool {
    !toolbar.isHidden && toolbar.frame.contains(g.location(in: self))
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    stopMomentum()
    if let touch = touches.first, event?.allTouches?.count == 1 { touchDown = touch.location(in: self) }
    super.touchesBegan(touches, with: event)
  }

  private var trackpad: Bool { session.settings.cursorMode == .trackpad }

  @objc private func tapped(_ g: UITapGestureRecognizer) {
    stopMomentum()
    let location = g.location(in: self), now = CACurrentMediaTime()
    let again = now - lastTap.time < Tune.clickInterval
      && (trackpad || hypot(location.x - lastTap.stage.x, location.y - lastTap.stage.y) < Tune.clickDistance)
    let count = again ? min(lastTap.count + 1, 3) : 1
    // A second tap lands where the first did, so finger jitter cannot split a double-click (§3.1).
    let point = trackpad ? session.pointer : again ? lastTap.mac : macPoint(location)
    lastTap = (now, location, point, count)
    session.click(.left, at: point, clicks: count)
    pointerChanged(follow: false)
    Haptics.keyDown()
  }

  @objc private func secondaryClick(_ g: UITapGestureRecognizer) {
    session.click(.right, at: trackpad ? session.pointer : macPoint(g.location(in: self)))
    pointerChanged(follow: false)
    Haptics.keyDown()
  }

  @objc private func middleClick(_ g: UITapGestureRecognizer) {
    session.click(.middle, at: trackpad ? session.pointer : macPoint(g.location(in: self)))
    pointerChanged(follow: false)
    Haptics.keyDown()
  }

  @objc private func toggleFullscreen(_ g: UITapGestureRecognizer) {
    withAnimation(Chrome.spring) { session.fullscreen.toggle() }
    session.openRow = nil
  }

  @objc private func pointerPanned(_ g: UIPanGestureRecognizer) {
    // The finger's whole travel counts, the distance the pan waited for included.
    let location = g.location(in: self)
    let t = g.state == .began ? CGPoint(x: location.x - touchDown.x, y: location.y - touchDown.y) : g.translation(in: self)
    g.setTranslation(.zero, in: self)
    guard var viewport = session.viewport else { return }
    if trackpad {
      let travel = viewport.pointerTravel(CGVector(dx: t.x, dy: t.y), speed: session.settings.trackingSpeed)
      movePointer(to: CGPoint(x: session.pointer.x + travel.dx, y: session.pointer.y + travel.dy))
    } else {
      viewport.pan(by: CGVector(dx: t.x, dy: t.y))
      session.viewport = viewport
      placeLayers()
    }
  }

  @objc private func scrolled(_ g: UIPanGestureRecognizer) {
    switch g.state {
    case .began:
      if !isLive(pinch) { twoFinger = .undecided }
    case .changed:
      if twoFinger == .undecided {
        let travel = g.translation(in: self)
        guard hypot(travel.x, travel.y) > Tune.scrollStart else { return }
        twoFinger = .scroll
        // Touch Mode scrolls what is under the fingers.
        if !trackpad { movePointer(to: macPoint(g.location(in: self)), follow: false) }
      }
      guard twoFinger == .scroll, let scale = session.viewport?.scale else { return }
      let t = g.translation(in: self)
      g.setTranslation(.zero, in: self)
      session.scroll(phaser.move(CGVector(dx: t.x / scale, dy: t.y / scale)))
    case .ended:
      guard twoFinger == .scroll, let scale = session.viewport?.scale else { return }
      let v = g.velocity(in: self)
      session.scroll(phaser.lift(velocity: CGVector(dx: v.x / scale, dy: v.y / scale)))
      startMomentum()
    default:
      if twoFinger == .scroll { session.scroll(phaser.cancel()) }
    }
  }

  @objc private func pinched(_ g: UIPinchGestureRecognizer) {
    let location = g.location(in: self)
    switch g.state {
    case .began:
      if !isLive(scrollPan) { twoFinger = .undecided }
      pinchAnchor = location
    case .changed:
      if twoFinger == .undecided {
        let travel = scrollPan.translation(in: self)
        guard abs(g.scale - 1) > Tune.pinchStart, hypot(travel.x, travel.y) <= Tune.scrollStart else { return }
        twoFinger = .pinch
      }
      guard twoFinger == .pinch, g.numberOfTouches >= 2, var viewport = session.viewport else {
        pinchAnchor = location
        return
      }
      viewport.pinch(by: g.scale, anchor: pinchAnchor, to: location)
      g.scale = 1
      pinchAnchor = location
      session.viewport = viewport
      placeLayers()
    default:
      guard twoFinger == .pinch, var viewport = session.viewport else { return }
      // Below Fit springs back to Fit.
      viewport.layout(fit: viewport.fit, visible: viewport.visible)
      session.viewport = viewport
      placeLayers(animated: true)
    }
  }

  @objc private func held(_ g: UILongPressGestureRecognizer) {
    let location = g.location(in: self)
    let fingers = g.numberOfTouchesRequired
    switch g.state {
    case .began:
      stopMomentum()
      let button: ScreenWire.MouseButton = [.left, .right, .middle][fingers - 1]
      dragFinger = location
      let point = trackpad ? session.pointer : clampToDisplays(macPoint(location))
      session.pressButton(button, at: point)
      pointerChanged(follow: true)
      showIndicator(at: location, color: [Chrome.UI.folder, Chrome.UI.bad, Chrome.UI.ok][fingers - 1])
      Haptics.firm()
    case .changed:
      guard session.heldButton != nil else { return }
      moveIndicator(to: location)
      if trackpad, let viewport = session.viewport {
        let travel = viewport.pointerTravel(CGVector(dx: location.x - dragFinger.x, dy: location.y - dragFinger.y),
                                            speed: session.settings.trackingSpeed)
        dragFinger = location
        movePointer(to: CGPoint(x: session.pointer.x + travel.dx, y: session.pointer.y + travel.dy))
      } else {
        dragFinger = location
        // Under the finger; near an edge the view scrolls itself (`autoScroll`) instead of following.
        movePointer(to: macPoint(location), follow: false)
        updateAutoScroll()
      }
    default:
      stopAutoScroll()
      session.releaseHeldButton()
      hideIndicator()
    }
  }

  @objc private func swiped(_ g: UIPanGestureRecognizer) {
    if g.state == .began { swipeSent = false }
    guard g.state == .changed, !swipeSent else { return }
    let t = g.translation(in: self)
    guard max(abs(t.x), abs(t.y)) > Tune.swipeDistance else { return }
    swipeSent = true
    // Mission Control, App Windows and the spaces; a swipe right moves a space left, as on a trackpad (§3.6).
    let code = abs(t.y) >= abs(t.x) ? (t.y < 0 ? MacKey.upArrow : MacKey.downArrow)
      : (t.x > 0 ? MacKey.leftArrow : MacKey.rightArrow)
    session.press(code, with: .control, consume: false)
    Haptics.keyDown()
  }

  @objc private func edgeSwiped(_ g: UIPanGestureRecognizer) {
    guard g.state == .began, let edges = edges(for: g) else { return }
    jump(to: edges)
  }

  /// The edges a pan started at, moving inward: one for an edge, two for a corner.
  private func edges(for g: UIPanGestureRecognizer) -> ScreenArrangement.Edges? {
    let t = g.translation(in: self), now = g.location(in: self)
    let start = CGPoint(x: now.x - t.x, y: now.y - t.y)
    var near: ScreenArrangement.Edges = []
    if start.x < bounds.minX + Tune.corner { near.insert(.left) }
    if start.x > bounds.maxX - Tune.corner { near.insert(.right) }
    if start.y < bounds.minY + Tune.corner { near.insert(.top) }
    if start.y > bounds.maxY - Tune.corner { near.insert(.bottom) }
    // The swipe must start in the band at an edge and move away from it.
    let inward: ScreenArrangement.Edges? =
      if start.x < bounds.minX + Tune.edgeBand, t.x > abs(t.y) { .left }
      else if start.x > bounds.maxX - Tune.edgeBand, -t.x > abs(t.y) { .right }
      else if start.y < bounds.minY + Tune.edgeBand, t.y > abs(t.x) { .top }
      else if start.y > bounds.maxY - Tune.edgeBand, -t.y > abs(t.x) { .bottom }
      else { nil }
    guard let inward else { return nil }
    return near.rawValue.nonzeroBitCount == 2 ? near : inward
  }

  /// The pointer to an edge's middle or a corner of the display it is on:
  /// the Dock, a full-screen app's menu bar, a Hot Corner (§3.6).
  func jump(to edges: ScreenArrangement.Edges) {
    let frames = session.shownDisplays.map { $0.frame.cg }
    guard let frame = frames.first(where: { $0.insetBy(dx: -1, dy: -1).contains(session.pointer) }) ?? frames.first else { return }
    let target = ScreenArrangement.edgePoint(edges, on: frame)
    // Two moves: macOS reveals the Dock and the menu bar on a move that reaches the edge.
    let inset = CGPoint(x: edges.contains(.left) ? 1 : edges.contains(.right) ? -1 : 0,
                        y: edges.contains(.top) ? 1 : edges.contains(.bottom) ? -1 : 0)
    movePointer(to: CGPoint(x: target.x + inset.x, y: target.y + inset.y))
    movePointer(to: target)
    Haptics.keyDown()
  }

  private func isLive(_ g: UIGestureRecognizer) -> Bool { g.state == .began || g.state == .changed }

  // MARK: - Pointer

  private func macPoint(_ location: CGPoint) -> CGPoint {
    session.viewport?.mac(location) ?? session.pointer
  }

  private func clampToDisplays(_ point: CGPoint) -> CGPoint {
    ScreenArrangement.clamp(point, to: session.shownDisplays.map { $0.frame.cg })
  }

  private func movePointer(to point: CGPoint, follow: Bool = true) {
    session.movePointer(to: clampToDisplays(point))
    pointerChanged(follow: follow)
  }

  /// Draws the pointer where the session has it, first moving the picture
  /// to keep it in view.
  private func pointerChanged(follow: Bool) {
    if follow, var viewport = session.viewport {
      viewport.follow(session.pointer, margin: Tune.followMargin)
      if viewport != session.viewport {
        session.viewport = viewport
        placeLayers()
        return
      }
    }
    placeCursor()
  }

  func pointerMoved() { pointerChanged(follow: true) }

  func cursorChanged() {
    cursorLayer.contents = session.cursor?.image
    placeCursor()
  }

  private func startMomentum() {
    momentum?.invalidate()
    guard phaser.inMomentum else { return }
    let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
    link.add(to: .main, forMode: .common)
    momentum = link
  }

  @objc private func momentumStep(_ link: CADisplayLink) {
    session.scroll(phaser.tick(link.targetTimestamp - link.timestamp))
    if !phaser.inMomentum { link.invalidate(); momentum = nil }
  }

  private func stopMomentum() {
    momentum?.invalidate()
    momentum = nil
    session.scroll(phaser.interrupt())
  }

  private func updateAutoScroll() {
    guard session.heldButton != nil, !trackpad, edgeVelocity(dragFinger) != .zero, autoScroll == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(autoScrollStep(_:)))
    link.add(to: .main, forMode: .common)
    autoScroll = link
  }

  /// Touch Mode: a drag held near a view edge scrolls the view that way, faster the deeper the finger sits.
  private func edgeVelocity(_ finger: CGPoint) -> CGVector {
    guard let visible = session.viewport?.visible else { return .zero }
    let margin = Tune.followMargin
    func axis(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
      if value < low + margin { return Tune.autoScrollSpeed * min(1, (low + margin - value) / margin) }
      if value > high - margin { return -Tune.autoScrollSpeed * min(1, (value - (high - margin)) / margin) }
      return 0
    }
    return CGVector(dx: axis(finger.x, visible.minX, visible.maxX), dy: axis(finger.y, visible.minY, visible.maxY))
  }

  @objc private func autoScrollStep(_ link: CADisplayLink) {
    let velocity = edgeVelocity(dragFinger)
    guard session.heldButton != nil, velocity != .zero, var viewport = session.viewport else { stopAutoScroll(); return }
    let dt = link.targetTimestamp - link.timestamp
    viewport.pan(by: CGVector(dx: velocity.dx * dt, dy: velocity.dy * dt))
    session.viewport = viewport
    // The finger stays put while the picture moves under it, so the drag carries on across the Mac.
    session.movePointer(to: clampToDisplays(macPoint(dragFinger)))
    placeLayers()
  }

  private func stopAutoScroll() {
    autoScroll?.invalidate()
    autoScroll = nil
  }

  // MARK: - Indicator

  private func showIndicator(at location: CGPoint, color: UIColor) {
    let size = Tune.indicatorSize
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    indicator.bounds = CGRect(x: 0, y: 0, width: size, height: size)
    indicator.path = UIBezierPath(ovalIn: indicator.bounds).cgPath
    indicator.fillColor = color.resolvedColor(with: traitCollection).withAlphaComponent(0.45).cgColor
    indicator.strokeColor = color.resolvedColor(with: traitCollection).cgColor
    indicator.lineWidth = 2
    indicator.position = location
    indicator.opacity = 1
    CATransaction.commit()
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.3
    grow.toValue = 1
    grow.duration = 0.12
    grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
    indicator.add(grow, forKey: "grow")
  }

  private func moveIndicator(to location: CGPoint) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    indicator.position = location
    CATransaction.commit()
  }

  private func hideIndicator() {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = indicator.presentation()?.opacity ?? 1
    fade.toValue = 0
    fade.duration = 0.18
    indicator.opacity = 0
    indicator.add(fade, forKey: "fade")
  }

  // MARK: - Layout

  /// iOS 26 tracks what this reads from the session and runs it again on a change.
  override func updateProperties() {
    super.updateProperties()
    _ = session.displays
    _ = session.settings.display
    let hidden = session.fullscreen || !session.drivable
    if toolbar.isHidden != hidden {
      toolbar.isHidden = hidden
      if hidden { session.openRow = nil }
    }
    toolbar.update()
    updateKeyboard()
    setNeedsLayout()
  }

  /// The key input holds focus while the software keyboard is asked for, or
  /// while a hardware keyboard is attached and the Screen shows (its keys are the Mac's).
  private func updateKeyboard() {
    let usable = session.isShown && session.drivable && window != nil
    let wanted = usable && (session.keyboardUp || GCKeyboard.coalesced != nil)
    if wanted, !input.isFirstResponder { input.becomeFirstResponder() }
    if !wanted, input.isFirstResponder { input.resignFirstResponder() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil, input.isFirstResponder { input.resignFirstResponder() }
    setNeedsUpdateProperties()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    stage.frame = bounds
    let keyboardTop = min(bounds.maxY, keyboardSpacer.frame.maxY)
    // The panel itself shrinks above the keyboard, so the stage's size can't
    // tell; the keyboard's height can (a hardware keyboard's bar stays short).
    let keyboardShows = keyboardLayoutGuide.layoutFrame.height > Tune.softKeyboardHeight
    if !keyboardShows { restingSize = bounds.size }
    // The keyboard shrinks the stage; the toolbar keeps the side the stage at rest gave it.
    let landscape = restingSize.width > restingSize.height
    toolbar.vertical = landscape
    let bar = ScreenToolbar.thickness, inset = Tune.barInset
    let rows: CGFloat = session.openRow == nil ? 1 : 2
    let toolbarShown = !toolbar.isHidden

    // Fit: the stage at rest (as if the keyboard were down) less the toolbar's own band.
    var fit = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: max(bounds.height, keyboardShows ? restingSize.height : 0)))
    var visible = CGRect(x: 0, y: 0, width: bounds.width, height: keyboardTop)
    if toolbarShown {
      if landscape {
        toolbar.frame = CGRect(x: inset, y: inset, width: bar * rows, height: keyboardTop - 2 * inset)
        fit.origin.x = bar + 2 * inset
        fit.size.width -= bar + 2 * inset
        visible.origin.x = toolbar.frame.maxX
        visible.size.width = bounds.maxX - visible.minX
      } else {
        let height = bar * rows
        toolbar.frame = CGRect(x: Chrome.Space.m, y: keyboardTop - inset - height, width: bounds.width - 2 * Chrome.Space.m, height: height)
        fit.size.height -= bar + 2 * inset
        visible.size.height = toolbar.frame.minY
      }
    }

    let ids = session.shownDisplays.map(\.id)
    var animated = false
    if session.viewport == nil || ids != shownIDs {
      animated = !shownIDs.isEmpty && session.viewport == nil
      shownIDs = ids
      let shown = session.shownDisplays.map { (frame: $0.frame.cg, pixelWidth: $0.pixelWidth) }
      session.viewport = shown.isEmpty ? nil : ScreenViewport(displays: shown, fit: fit, visible: visible)
      if var viewport = session.viewport {
        viewport.follow(session.pointer, margin: Tune.followMargin)
        session.viewport = viewport
      }
    } else if var viewport = session.viewport {
      viewport.layout(fit: fit, visible: visible)
      viewport.follow(session.pointer, margin: Tune.followMargin)
      session.viewport = viewport
    }
    attachLayers()
    placeLayers(animated: animated)
  }

  /// A placeholder and the video layer for every display the Mac has.
  private func attachLayers() {
    let ids = Set(session.displays.map(\.id))
    for (id, layer) in placeholders where !ids.contains(id) { layer.removeFromSuperlayer(); placeholders[id] = nil }
    for (id, layer) in videos where !ids.contains(id) { layer.removeFromSuperlayer(); videos[id] = nil }
    for display in session.displays {
      if placeholders[display.id] == nil {
        let placeholder = CALayer()
        placeholder.cornerRadius = 2
        placeholders[display.id] = placeholder
        stage.addSublayer(placeholder)
      }
      if let video = session.layer(for: display.id), videos[display.id] !== video {
        videos[display.id]?.removeFromSuperlayer()
        videos[display.id] = video
        stage.addSublayer(video)
      }
    }
    stylePlaceholders()
  }

  private func stylePlaceholders() {
    for layer in placeholders.values { layer.backgroundColor = Chrome.UI.fill2.resolvedColor(with: traitCollection).cgColor }
  }

  private func placeLayers(animated: Bool = false) {
    guard let viewport = session.viewport else { return }
    let shown = Set(shownIDs)
    CATransaction.begin()
    if animated {
      CATransaction.setAnimationDuration(0.35)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
    } else {
      CATransaction.setDisableActions(true)
    }
    for display in session.displays {
      let frame = viewport.stage(display.frame.cg)
      for layer in [placeholders[display.id], videos[display.id]].compactMap({ $0 }) {
        layer.frame = frame
        layer.opacity = shown.contains(display.id) ? 1 : 0
      }
    }
    CATransaction.commit()
    placeCursor()
  }

  private func placeCursor() {
    guard let viewport = session.viewport, let cursor = session.cursor, session.drivable else {
      cursorLayer.isHidden = true
      return
    }
    let scale = viewport.scale
    cursorLayer.isHidden = false
    cursorLayer.contents = cursor.image
    cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursor.size.width * scale, height: cursor.size.height * scale)
    cursorLayer.anchorPoint = CGPoint(x: cursor.hotSpot.x / max(cursor.size.width, 1), y: cursor.hotSpot.y / max(cursor.size.height, 1))
    cursorLayer.position = viewport.stage(session.pointer)
  }
}

extension ScreenWire.Rect {
  var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
