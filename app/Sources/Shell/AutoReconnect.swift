import Foundation

/// When to bring a silent mosh session back by itself. Pure timing: callers
/// pass the clock in seconds, so every threshold is testable without waiting.
struct ReconnectPolicy: Equatable {
  /// A mosh session counts as lost after this long UNREACHABLE. The core only
  /// reports UNREACHABLE after 5 s of silence and a probe of the host comes
  /// first, so waiting longer here only adds to the frozen screen.
  static let silence: TimeInterval = 1
  /// Wait before probing again when the host did not answer, or after a reconnect succeeded.
  static let retry: TimeInterval = 10
  /// Waits after the 1st, 2nd and later failed reconnects.
  static let backoff: [TimeInterval] = [10, 30, 60]

  /// A probe or reconnect is running; never start a second.
  private(set) var inFlight = false
  private var notBefore: TimeInterval = 0
  private var failures = 0

  /// True when the host should be probed now; that starts a flight.
  mutating func shouldProbe(now: TimeInterval, unreachableFor: TimeInterval) -> Bool {
    guard !inFlight, unreachableFor >= Self.silence, now >= notBefore else { return false }
    inFlight = true
    return true
  }

  /// Seconds until `shouldProbe` can say yes, nil while a flight runs (its end re-evaluates).
  func delay(now: TimeInterval, unreachableFor: TimeInterval) -> TimeInterval? {
    guard !inFlight else { return nil }
    return max(Self.silence - unreachableFor, notBefore - now, 0)
  }

  /// The probe found the network down: ask again later.
  mutating func probeFailed(now: TimeInterval) {
    inFlight = false
    notBefore = now + Self.retry
  }

  /// The probe's answer no longer matters (the session recovered or a reconnect started elsewhere).
  mutating func probeDropped() {
    inFlight = false
  }

  mutating func reconnectFinished(now: TimeInterval, succeeded: Bool) {
    inFlight = false
    if succeeded {
      notBefore = now + Self.retry
    } else {
      notBefore = now + Self.backoff[min(failures, Self.backoff.count - 1)]
      failures += 1
    }
  }

  /// The session was heard from again.
  mutating func recovered() {
    failures = 0
    notBefore = 0
  }
}

/// Runs `ReconnectPolicy` for one tab: tracks how long the session has been
/// UNREACHABLE, probes the host over SSH, and starts the in-place reconnect
/// when the host answers. Only mosh sessions attached to herdr qualify; their
/// state survives a new server, and without this the server's idle timeout
/// would show as a dead session.
@MainActor
final class AutoReconnect {
  private var policy = ReconnectPolicy()
  private var unreachableSince: TimeInterval?
  private var foreground = true
  private var timer: Task<Void, Never>?
  /// Bumped by `stop`, so a probe that outlives its session is ignored.
  private var generation = 0

  private let clock: () -> TimeInterval
  /// Whether this session may reconnect on its own right now.
  var isEligible: () -> Bool = { false }
  /// True when the host answers an SSH command.
  var probe: () async -> Bool = { false }
  var reconnect: () -> Void = {}

  init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.clock = clock
  }

  /// Status of the session changed: `unreachable` is whether it is silent now.
  func statusChanged(unreachable: Bool) {
    if unreachable {
      if unreachableSince == nil { unreachableSince = clock() }
    } else {
      unreachableSince = nil
      policy.recovered()
    }
    evaluate()
  }

  /// The app went to the background: nothing runs until it returns.
  func suspended() {
    foreground = false
    timer?.cancel()
    timer = nil
  }

  /// The app is back: the silence clock starts over, since the network was off.
  func resumed() {
    foreground = true
    if unreachableSince != nil { unreachableSince = clock() }
    evaluate()
  }

  /// The reconnect started by `reconnect` ended.
  func reconnectFinished(succeeded: Bool) {
    policy.reconnectFinished(now: clock(), succeeded: succeeded)
    if succeeded, unreachableSince != nil { unreachableSince = clock() }
    evaluate()
  }

  /// The session this ran for is gone.
  func stop() {
    generation += 1
    unreachableSince = nil
    policy = ReconnectPolicy()
    timer?.cancel()
    timer = nil
  }

  private func evaluate() {
    timer?.cancel()
    timer = nil
    guard let since = unreachableSince, foreground, isEligible() else { return }
    let now = clock()
    if policy.shouldProbe(now: now, unreachableFor: now - since) {
      Task { await probeHost() }
    } else if let delay = policy.delay(now: now, unreachableFor: now - since) {
      timer = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        self?.evaluate()
      }
    }
  }

  private func probeHost() async {
    let started = generation
    let answered = await probe()
    guard started == generation else { return }
    guard unreachableSince != nil, foreground, isEligible() else {
      policy.probeDropped()
      evaluate()
      return
    }
    if answered {
      reconnect()
    } else {
      policy.probeFailed(now: clock())
      evaluate()
    }
  }
}
