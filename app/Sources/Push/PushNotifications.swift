import UIKit
import UserNotifications

/// Remote notifications: the APNs token, notifications shown while Term is
/// in front, and taps, which open the pane the push names in a launched,
/// woken or already running app.
@MainActor
final class PushNotifications: NSObject, UNUserNotificationCenterDelegate, PushRegistrar {
  static let shared = PushNotifications()
  /// Counts token requests, so a request's timeout never ends a later one.
  private var tokenRequest = 0
  private var tokenWaiters: [CheckedContinuation<Result<String, PushPairings.Failure>, Never>] = []
  /// A tap that came before any window could open it (a cold launch).
  private var pending: PushRoute?
  /// Notifications already opened: a launch's tap reaches both the scene and the delegate.
  private var delivered: Set<String> = []

  /// At launch, before it finishes: a tap that launched Term is delivered
  /// only to a delegate set by then. While notifications are on, APNs is asked
  /// for the token again, and the relay hears of any change.
  func install() {
    UNUserNotificationCenter.current().delegate = self
    if PushPairings.shared.isOn { UIApplication.shared.registerForRemoteNotifications() }
  }

  // MARK: - Token

  func authorize() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
  }

  func token() async throws(PushPairings.Failure) -> String {
    let result = await withCheckedContinuation { continuation in
      tokenWaiters.append(continuation)
      guard tokenWaiters.count == 1 else { return }
      tokenRequest += 1
      let request = tokenRequest
      UIApplication.shared.registerForRemoteNotifications()
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(30))
        guard let self, tokenRequest == request else { return }
        finish(.failure(.registration("no answer in 30 seconds")))
      }
    }
    return try result.get()
  }

  var environment: String { Self.environment(provision: Self.embeddedProvision, simulator: Self.isSimulator) }

  func unregister() {
    UIApplication.shared.unregisterForRemoteNotifications()
  }

  /// AppDelegate's didRegisterForRemoteNotifications.
  func registered(_ token: Data) {
    let hex = Hex.string(token)
    finish(.success(hex))
    Task { await PushPairings.shared.renew(token: hex) }
  }

  /// AppDelegate's didFailToRegisterForRemoteNotifications.
  func failed(_ error: Error) {
    DiagnosticLog.record(.notification, "register-failed")
    finish(.failure(.registration(error.localizedDescription)))
  }

  private func finish(_ result: Result<String, PushPairings.Failure>) {
    tokenRequest += 1
    let waiters = tokenWaiters
    tokenWaiters = []
    for waiter in waiters { waiter.resume(returning: result) }
  }

  /// The APNs environment of this build's token. A development profile says
  /// "development"; the App Store's builds carry no profile and use production.
  nonisolated static func environment(provision: Data?, simulator: Bool) -> String {
    if simulator { return "sandbox" }
    guard let provision else { return "production" }
    guard let start = provision.range(of: Data("<?xml".utf8)),
          let end = provision.range(of: Data("</plist>".utf8), in: start.lowerBound..<provision.endIndex),
          let plist = try? PropertyListSerialization.propertyList(from: provision[start.lowerBound..<end.upperBound], format: nil)
            as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any]
    else { return "sandbox" }
    return entitlements["aps-environment"] as? String == "production" ? "production" : "sandbox"
  }

  private static var embeddedProvision: Data? {
    Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
  }

  private static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }

  // MARK: - Delivery

  /// In front, a push still shows: it may be for a session he isn't looking at.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                         withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
    Task { @MainActor in completionHandler([.banner, .list, .sound]) }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                         withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
    let tap = Self.tap(response)
    // UIKit snapshots the cold-launched scene from this completion; it must run on the main actor.
    Task { @MainActor in
      if let tap { deliver(tap.route, id: tap.id) }
      completionHandler()
    }
  }

  /// A window opened by tapping a notification (UIScene.ConnectionOptions):
  /// the tap opens there, whether or not the delegate also hears of it.
  func launched(by response: UNNotificationResponse, in space: SpaceController) {
    if let tap = Self.tap(response) { deliver(tap.route, id: tap.id, in: space) }
  }

  /// The default action on one of the relay's notifications; nil for any other.
  private nonisolated static func tap(_ response: UNNotificationResponse) -> (route: PushRoute, id: String)? {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
    guard let route = PushRoute(userInfo: response.notification.request.content.userInfo) else {
      DiagnosticLog.record(.notification, "push-tap-ignored")
      return nil
    }
    return (route, response.notification.request.identifier)
  }

  /// Opens `route` once per notification (`id`), in `space`, the window in
  /// front, or the first window to open.
  func deliver(_ route: PushRoute, id: String, in space: SpaceController? = nil) {
    guard delivered.insert(id).inserted else { return }
    DiagnosticLog.record(.notification, "push-tap", "kind=\(route.kind.rawValue)")
    guard let space = space ?? SpaceController.frontmost else {
      pending = route
      return
    }
    Task { await space.open(route) }
  }

  /// The tap that came before any window, once one exists.
  func takePending() -> PushRoute? {
    defer { pending = nil }
    return pending
  }
}
