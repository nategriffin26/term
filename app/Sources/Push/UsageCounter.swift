import Foundation
import Observation

/// The daily usage count (relay/src/contract.ts, CounterPing): one ping per
/// install per day with three flags and nothing else. Off until he turns it
/// on (About, or onboarding through `setEnabled`); while off nothing is
/// gathered, no id exists and nothing is sent. A day's flags gather while it
/// runs (UTC) and go to the relay at the first launch or return to the front
/// after it ends; the relay dates them by when they arrive.
///
/// Policy: only the most recent finished day is ever sent; an older one
/// still unsent when another ends is dropped, never merged or backfilled.
/// The install id is random and replaced each UTC month; a day is sent under
/// the id of the month it ran in, so no day's flags reach a new month's id.
/// Turning the count off erases the id and every gathered flag.
@MainActor @Observable
final class UsageCounter {
  static let shared = UsageCounter(defaults: .standard, send: { ping in
    guard let url = RelayConfig.url else { return false }
    do { try await RelayClient(base: url).ping(ping) } catch { return false }
    return true
  })

  enum Flag: String, Codable, CaseIterable, Sendable {
    /// A terminal connected to a host.
    case hostOK = "host_ok"
    /// The Screen showed a Mac.
    case screenOpened = "screen_opened"
    /// He submitted an answer in a session whose agent was asking or waiting for approval.
    case askAnswered = "ask_answered"
  }

  /// One UTC day's flags, under the install id of its month.
  struct Day: Codable, Equatable {
    var date: String
    var installID: UUID
    var flags: Set<Flag> = []
  }

  struct State: Codable, Equatable {
    /// The id for days in `month` (UTC, "2026-10").
    var installID: UUID?
    var month: String?
    /// The day gathering now.
    var current: Day?
    /// The last finished day, until the relay takes it.
    var finished: Day?
    /// The UTC day a ping last went out: at most one a day.
    var lastSent: String?
  }

  private(set) var isEnabled: Bool

  /// The one way the count turns on or off; off erases the id and every gathered flag.
  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    if !enabled { state = State() }
  }

  private(set) var state: State {
    didSet { if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) } }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let send: (RelayClient.Ping) async -> Bool
  @ObservationIgnored private var sending = false
  private static let enabledKey = "usageCountEnabled"
  private static let stateKey = "usageCount"

  init(defaults: UserDefaults, now: @escaping () -> Date = Date.init,
       send: @escaping (RelayClient.Ping) async -> Bool) {
    self.defaults = defaults
    self.now = now
    self.send = send
    let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    isEnabled = enabled
    // Off, nothing gathered earlier survives to be sent once it is turned on.
    if enabled {
      state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    } else {
      state = State()
      defaults.removeObject(forKey: Self.stateKey)
    }
  }

  /// Something happened today that the count records.
  func record(_ flag: Flag) {
    guard isEnabled else { return }
    roll()
    state.current?.flags.insert(flag)
  }

  /// Term came to the front: today starts gathering, and a finished day goes out.
  func becameActive() async {
    guard isEnabled else { return }
    roll()
    let today = Self.day(now())
    guard let finished = state.finished, state.lastSent != today, !sending else { return }
    sending = true
    defer { sending = false }
    let ping = RelayClient.Ping(install_id: finished.installID.uuidString.lowercased(),
                                host_ok: finished.flags.contains(.hostOK),
                                screen_opened: finished.flags.contains(.screenOpened),
                                ask_answered: finished.flags.contains(.askAnswered))
    guard await send(ping), isEnabled, state.finished == finished else { return }
    state.finished = nil
    state.lastSent = today
  }

  /// A new UTC day: the day before becomes the finished one, and today
  /// starts under its month's id.
  private func roll() {
    let today = Self.day(now())
    guard state.current?.date != today else { return }
    if let current = state.current { state.finished = current }
    let month = String(today.prefix(7))
    let id: UUID
    if let existing = state.installID, state.month == month {
      id = existing
    } else {
      id = UUID()
      state.installID = id
      state.month = month
    }
    state.current = Day(date: today, installID: id)
  }

  static func day(_ date: Date) -> String {
    let c = Calendar.utc.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}

private extension Calendar {
  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
}
