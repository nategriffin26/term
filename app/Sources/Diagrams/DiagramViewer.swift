import UIKit

/// A diagram on its own, full screen (local/diagrams/design.md §3): laid out
/// for the screen's width on the terminal's ground, pinch and pan up to 4×,
/// double-tap to fit or zoom in, Copy Source and Share. It is drawn again at
/// the zoom a pinch settles at, and laid out again when the width changes.
@MainActor
final class DiagramViewer: UIViewController, UIScrollViewDelegate {
  static let maxZoom: CGFloat = 4
  /// Most pixels drawn for one zoom (resvg stops at 16 Mpx).
  static let maxPixels: CGFloat = 12_000_000
  /// Room kept clear of the close button above and the actions below.
  private static let topClear = Chrome.Size.target + 2 * Chrome.Space.s
  private static let bottomClear = Chrome.Size.target + 2 * Chrome.Space.l

  /// Called once it has gone.
  var onClose: (() -> Void)?

  private let source: String
  private let sourceHash: String
  private let style: DiagramEngine.Style
  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private let closeGlass = GlassView()
  private let actionsGlass = GlassView()
  private let copyButton = UIButton(type: .system)
  private let shareButton = UIButton(type: .system)
  /// Width the shown image is laid out for, in points; 0 before the first layout.
  private var laidOutWidth: CGFloat = 0
  /// Pixels per point of the shown image.
  private var drawnScale: CGFloat = 0
  private var drawing: Task<Void, Never>?
  private var copiedReset: Task<Void, Never>?

  init(_ shown: DiagramOverlay.Shown) {
    source = shown.drawing.source
    sourceHash = shown.drawing.hash
    style = shown.style
    super.init(nibName: nil, bundle: nil)
    imageView.image = shown.image
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  isolated deinit {
    drawing?.cancel()
    copiedReset?.cancel()
  }

  private var ground: UIColor { UIColor(argb: 0xFF00_0000 | style.background) }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    var white: CGFloat = 0
    ground.getWhite(&white, alpha: nil)
    return white < 0.5 ? .lightContent : .darkContent
  }

  /// Takes the keyboard away from the terminal while it shows.
  override var canBecomeFirstResponder: Bool { true }

  /// Swiping down closes it only when nothing is zoomed or scrolled.
  var isAtRest: Bool {
    scrollView.zoomScale <= max(scrollView.minimumZoomScale, 1) + 0.001
      && scrollView.contentOffset.y <= -scrollView.contentInset.top + 1
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = ground

    scrollView.delegate = self
    scrollView.maximumZoomScale = Self.maxZoom
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.backgroundColor = ground
    imageView.contentMode = .scaleToFill
    imageView.accessibilityLabel = "Diagram"
    scrollView.addSubview(imageView)
    view.addSubview(scrollView)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark", withConfiguration: Chrome.uiSymbol(.control)), for: .normal)
    close.tintColor = Chrome.UI.fg
    close.accessibilityLabel = "Close"
    close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
    configure(copyButton, title: "Copy Source", symbol: "doc.on.doc") { $0.copySource() }
    configure(shareButton, title: "Share", symbol: "square.and.arrow.up") { $0.share() }
    let actions = UIStackView(arrangedSubviews: [copyButton, shareButton])
    actions.spacing = Chrome.Space.xs

    for (glass, content) in [(closeGlass, close as UIView), (actionsGlass, actions)] {
      glass.isGlassShown = true
      glass.cornerConfiguration = .capsule()
      glass.translatesAutoresizingMaskIntoConstraints = false
      content.translatesAutoresizingMaskIntoConstraints = false
      glass.contentView.addSubview(content)
      view.addSubview(glass)
    }
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      closeGlass.topAnchor.constraint(equalTo: safe.topAnchor, constant: Chrome.Space.s),
      closeGlass.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Chrome.Space.l),
      closeGlass.widthAnchor.constraint(equalToConstant: Chrome.Size.target),
      closeGlass.heightAnchor.constraint(equalToConstant: Chrome.Size.target),
      close.topAnchor.constraint(equalTo: closeGlass.contentView.topAnchor),
      close.bottomAnchor.constraint(equalTo: closeGlass.contentView.bottomAnchor),
      close.leadingAnchor.constraint(equalTo: closeGlass.contentView.leadingAnchor),
      close.trailingAnchor.constraint(equalTo: closeGlass.contentView.trailingAnchor),

      actionsGlass.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
      actionsGlass.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Chrome.Space.l),
      actionsGlass.heightAnchor.constraint(equalToConstant: Chrome.Size.target),
      actions.topAnchor.constraint(equalTo: actionsGlass.contentView.topAnchor),
      actions.bottomAnchor.constraint(equalTo: actionsGlass.contentView.bottomAnchor),
      actions.leadingAnchor.constraint(equalTo: actionsGlass.contentView.leadingAnchor, constant: Chrome.Space.xs),
      actions.trailingAnchor.constraint(equalTo: actionsGlass.contentView.trailingAnchor, constant: -Chrome.Space.xs),
    ])
  }

  private func configure(_ button: UIButton, title: String, symbol: String, _ action: @escaping (DiagramViewer) -> Void) {
    var c = UIButton.Configuration.plain()
    c.title = title
    c.image = UIImage(systemName: symbol, withConfiguration: Chrome.uiSymbol(.inline))
    c.imagePadding = Chrome.Space.s
    c.baseForegroundColor = Chrome.UI.fg
    c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Chrome.Space.m, bottom: 0, trailing: Chrome.Space.m)
    c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var a = attributes
      a.font = Chrome.uiFont(.body, .medium)
      return a
    }
    button.configuration = c
    button.addAction(UIAction { [weak self] _ in if let self { action(self) } }, for: .primaryActionTriggered)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    becomeFirstResponder()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed {
      onClose?()
      onClose = nil
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrollView.frame = view.bounds
    let width = (view.bounds.inset(by: view.safeAreaInsets).width - 2 * Chrome.Space.l).rounded(.down)
    if width > 0, abs(width - laidOutWidth) >= 1 {
      layOut(width)
    } else {
      fit()
    }
  }

  // MARK: Drawing

  /// Lays the diagram out again for `width`: the image shown so far, scaled
  /// to it, until the new layout is drawn.
  private func layOut(_ width: CGFloat) {
    laidOutWidth = width
    drawnScale = 0
    if let image = imageView.image {
      let k = min(1, width / image.size.width)
      show(CGSize(width: image.size.width * k, height: image.size.height * k))
    }
    draw(scale: view.traitCollection.displayScale, newLayout: true)
  }

  private func draw(scale: CGFloat, newLayout: Bool) {
    drawing?.cancel()
    let width = laidOutWidth
    var style = style
    style.scale = Double(scale)
    let request = DiagramEngine.Request(hash: sourceHash, maxWidth: Int(width), style: style)
    let source = source
    drawing = Task { [weak self] in
      let image = await DiagramEngine.shared.draw(request, source: source)
      guard let self, let image, !Task.isCancelled, width == laidOutWidth else { return }
      drawnScale = scale
      imageView.image = image
      if newLayout { show(image.size) }
    }
  }

  /// Shows an image `size` points at zoom 1, fitted and centered.
  private func show(_ size: CGSize) {
    scrollView.zoomScale = 1
    imageView.frame = CGRect(origin: .zero, size: size)
    scrollView.contentSize = size
    fit()
    scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
  }

  /// Zoom 1 is the laid-out size; the least zoom shows it whole.
  private func fit() {
    let size = imageView.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let room = view.bounds.inset(by: view.safeAreaInsets)
    let height = room.height - Self.topClear - Self.bottomClear
    let width = room.width - 2 * Chrome.Space.l
    scrollView.minimumZoomScale = min(1, height / size.height, width / size.width)
    if scrollView.zoomScale < scrollView.minimumZoomScale { scrollView.zoomScale = scrollView.minimumZoomScale }
    center()
  }

  /// Centers the image while it is smaller than the screen, clear of the controls.
  private func center() {
    let bounds = scrollView.bounds.size
    let content = scrollView.contentSize
    let safe = view.safeAreaInsets
    let v = (bounds.height - content.height) / 2
    let h = (bounds.width - content.width) / 2
    scrollView.contentInset = UIEdgeInsets(
      top: max(v, safe.top + Self.topClear), left: max(h, safe.left + Chrome.Space.l),
      bottom: max(v, safe.bottom + Self.bottomClear), right: max(h, safe.right + Chrome.Space.l))
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

  /// Sharp at the zoom a pinch settles at, within the pixel budget.
  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    let size = imageView.bounds.size
    let budget = (Self.maxPixels / max(size.width * size.height, 1)).squareRoot()
    let wanted = min(self.view.traitCollection.displayScale * scale, budget)
    if wanted > drawnScale + 0.01 { draw(scale: wanted, newLayout: false) }
  }

  @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
    if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
      return
    }
    let zoom = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 2.5)
    let p = g.location(in: imageView)
    let size = CGSize(width: scrollView.bounds.width / zoom, height: scrollView.bounds.height / zoom)
    scrollView.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
  }

  // MARK: Actions

  private func copySource() {
    UIPasteboard.general.string = DiagramCopy.fenced(source)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    copyButton.configuration?.title = "Copied"
    copyButton.configuration?.image = UIImage(systemName: "checkmark", withConfiguration: Chrome.uiSymbol(.inline))
    copiedReset?.cancel()
    copiedReset = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard let self, !Task.isCancelled else { return }
      copyButton.configuration?.title = "Copy Source"
      copyButton.configuration?.image = UIImage(systemName: "doc.on.doc", withConfiguration: Chrome.uiSymbol(.inline))
    }
  }

  /// A PNG at three pixels a point, laid out as shown.
  private func share() {
    var style = style
    style.scale = max(Double(view.traitCollection.displayScale), 3)
    let request = DiagramEngine.Request(hash: sourceHash, maxWidth: Int(laidOutWidth), style: style)
    let source = source
    Task { [weak self] in
      guard let image = await DiagramEngine.shared.draw(request, source: source), let png = image.pngData(),
            let self else { return }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("Diagram.png")
      do {
        try png.write(to: url, options: .atomic)
      } catch {
        return
      }
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = shareButton
      present(sheet, animated: true)
    }
  }
}

extension TerminalView {
  /// Shows a drawn diagram full screen, zooming out of its tile.
  func openDiagram(_ shown: DiagramOverlay.Shown) {
    var host = sequence(first: self as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
    while let presented = host?.presentedViewController { host = presented }
    guard let host else { return }
    let viewer = DiagramViewer(shown)
    let hadKeyboard = isFirstResponder
    viewer.onClose = { [weak self] in if hadKeyboard { self?.becomeFirstResponder() } }
    let options = UIViewController.Transition.ZoomOptions()
    options.interactiveDismissShouldBegin = { [weak viewer] _ in viewer?.isAtRest ?? true }
    let hash = shown.drawing.hash
    viewer.preferredTransition = .zoom(options: options) { [weak self] _ in self?.diagramOverlay.tile(for: hash) }
    host.present(viewer, animated: true)
  }

  /// The long-press menu of the diagram it was opened on.
  func diagramMenu() -> UIMenu? {
    guard let shown = diagramOverlay.menuTarget else { return nil }
    return UIMenu(children: [
      UIAction(title: "Copy Source") { _ in UIPasteboard.general.string = DiagramCopy.fenced(shown.drawing.source) },
      UIAction(title: "Copy Image") { _ in UIPasteboard.general.image = shown.image },
      UIAction(title: "Open") { [weak self] _ in self?.openDiagram(shown) },
    ])
  }
}
