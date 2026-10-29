import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    recordLaunch()
    MicrophoneCapture.waitForSlowAudioServer()
    Dictation.shared.transcribeLeftovers()
    TerminalView.registerFonts()
    SessionRegistry.shared.restoreSaved()
    PushNotifications.shared.install()

    // App lifecycle → core: suspend and save when the whole app leaves the
    // screen, resume the moment it returns.
    let center = NotificationCenter.default
    center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { SessionRegistry.shared.suspendAll() }
      DiagnosticLog.record(.app, "background")
      DiagnosticLog.flush()
    }
    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      DiagnosticLog.record(.app, "foreground", DiagnosticLog.clocks)
      MainActor.assumeIsolated { SessionRegistry.shared.resumeAll() }
    }
    // The tmux badge: agents checked at once on coming to the front, then
    // every few seconds while Term stays there. The usage count sends a
    // finished day's flags at the first chance after it ends.
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      DiagnosticLog.record(.app, "active")
      MainActor.assumeIsolated {
        TmuxStore.shared.checkAgents(retry: true)
        Task { await UsageCounter.shared.becameActive() }
      }
    }
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      DiagnosticLog.record(.app, "inactive")
    }
    center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
      DiagnosticLog.record(.app, "memory-warning")
    }
    Task { await TmuxStore.shared.watchAgents() }
    return true
  }

  func applicationWillTerminate(_ application: UIApplication) {
    DiagnosticLog.record(.app, "terminate")
    DiagnosticLog.flush()
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    PushNotifications.shared.registered(deviceToken)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushNotifications.shared.failed(error)
  }

  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    UISceneConfiguration(name: "Terminal", sessionRole: session.role)
  }

  /// Windows the user closed end their shells.
  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    SessionRegistry.shared.discardScenes(Set(sceneSessions.map(\.persistentIdentifier)))
  }

  /// The build and device every later line in the log comes from, and where the clocks stand.
  private func recordLaunch() {
    let info = Bundle.main.infoDictionary ?? [:]
    func value(_ key: String) -> String { info[key] as? String ?? "unknown" }
    var machine = utsname()
    uname(&machine)
    let model = withUnsafeBytes(of: machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { " simulator=\($0)" } ?? ""
    DiagnosticLog.record(.app, "launch", "version=\(value("CFBundleShortVersionString"))(\(value("CFBundleVersion")))"
      + " commit=\(value("TermBuildCommit")) built=\(value("TermBuildTime"))"
      + " os=\(UIDevice.current.systemVersion) model=\(model)\(simulated) tz=\(TimeZone.current.identifier) "
      + DiagnosticLog.clocks)
  }
}
