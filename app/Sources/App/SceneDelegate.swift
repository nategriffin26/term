import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  /// NSUserActivity type for "New Window" (declared in NSUserActivityTypes).
  static let windowActivity = AppIdentity.bundleID + ".window"

  var window: UIWindow?
  private var space: SpaceController?
  private var settingsObserver: NSObjectProtocol?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    scene.applyAppTheme()
    settingsObserver = NotificationCenter.default.addObserver(
      forName: .termSettingsChanged, object: nil, queue: .main
    ) { [weak scene] _ in
      MainActor.assumeIsolated { scene?.applyAppTheme() }
    }
    let space = SpaceController(sceneID: session.persistentIdentifier)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = TerminalNavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window
    self.space = space

    // `simctl launch … -testpage`: show the renderer's test page for screenshots.
    if ProcessInfo.processInfo.arguments.contains("-testpage") {
      space.loadViewIfNeeded()
      space.tabs.first?.run("testpage")
    }

    if let url = connectionOptions.urlContexts.first?.url {
      // A cold launch from a link: the panes exist once the window has laid out.
      window.layoutIfNeeded()
      open(url)
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url { open(url) }
  }

  private func open(_ url: URL) {
    guard let link = DeepLink(url) else {
      DiagnosticLog.record(.scene, "link-ignored")
      return
    }
    Task { await space?.open(link) }
  }
}

/// Hosts a window's SpaceController. Its toolbar is the iPhone Duo vertical
/// bar's content; the navigation bar stays hidden.
final class TerminalNavigationController: UINavigationController {
  override init(rootViewController: UIViewController) {
    super.init(rootViewController: rootViewController)
    setNavigationBarHidden(true, animated: false)
    setToolbarHidden(true, animated: false)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// The bar springs its items to new places when the window rotates or the
  /// keyboard moves; the tmux count follows them.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    (topViewController as? SpaceController)?.barDidLayout()
  }

  override var childForStatusBarStyle: UIViewController? { topViewController }
  override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
}
