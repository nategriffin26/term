import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    TerminalView.registerFonts()
    SessionRegistry.shared.restoreSaved()

    // App lifecycle → core: suspend and save when the whole app leaves the
    // screen, resume the moment it returns.
    let center = NotificationCenter.default
    center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { SessionRegistry.shared.suspendAll() }
    }
    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { SessionRegistry.shared.resumeAll() }
    }
    return true
  }

  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    UISceneConfiguration(name: "Terminal", sessionRole: session.role)
  }

  /// Windows the user closed end their shells.
  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    SessionRegistry.shared.discardScenes(Set(sceneSessions.map(\.persistentIdentifier)))
  }
}
