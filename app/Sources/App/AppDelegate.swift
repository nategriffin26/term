import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    MicrophoneCapture.waitForSlowAudioServer()
    Dictation.shared.transcribeLeftovers()
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
    // The tmux badge: agents checked at once on coming to the front, then
    // every few seconds while Term stays there.
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { TmuxStore.shared.checkAgents(retry: true) }
    }
    Task { await TmuxStore.shared.watchAgents() }
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
