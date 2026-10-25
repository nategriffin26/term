import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  /// NSUserActivity type for "New Window" (declared in NSUserActivityTypes).
  static let windowActivity = AppIdentity.bundleID + ".window"

  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let space = SpaceController(sceneID: session.persistentIdentifier)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = TerminalNavigationController(rootViewController: space)
    window.makeKeyAndVisible()
    self.window = window

    // `simctl launch … -testpage`: show the renderer's test page for screenshots.
    if ProcessInfo.processInfo.arguments.contains("-testpage") {
      space.loadViewIfNeeded()
      space.tabs.first?.run("testpage")
    }
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

  override var childForStatusBarStyle: UIViewController? { topViewController }
  override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
}
