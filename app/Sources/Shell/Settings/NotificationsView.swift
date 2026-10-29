import SwiftUI

/// Settings › Notifications: this iPhone registered with the relay or not,
/// and each saved host paired or not.
struct NotificationsView: View {
  private let pairings = PushPairings.shared
  private let config = ConfigStore.shared
  /// The switch is turning notifications on or off.
  @State private var switching = false
  /// Hosts being paired or unpaired.
  @State private var busy: Set<UUID> = []
  @State private var switchError: String?
  @State private var hostError: String?

  var body: some View {
    SettingsPageView(title: "Notifications") {
      List {
        if pairings.relay == nil {
          ListSection {
            ValueRow("Relay", "Not Set")
          } footer: {
            failure(PushPairings.Failure.noRelay.message)
          }
        } else {
          ListSection {
            Toggle("Notifications", isOn: Binding(get: { pairings.isOn }, set: { turn($0) }))
              .disabled(switching)
          } footer: {
            if let switchError { failure(switchError) }
          }
          if pairings.isOn { hosts }
        }
      }
      .chromeList()
    }
  }

  @ViewBuilder private var hosts: some View {
    ListSection("Hosts") {
      if config.hosts.isEmpty {
        PageRow(page: .newHost) { Text("Add Host") }
      }
      ForEach(config.hosts) { host in
        let paired = pairings.pairing(for: host) != nil
        HStack(spacing: Chrome.Space.s) {
          Text(host.alias).font(Chrome.mono(.body, .medium)).lineLimit(1)
          Spacer(minLength: Chrome.Space.s)
          if busy.contains(host.id) {
            ProgressView()
          } else {
            Button(paired ? "Unpair" : "Pair") { change(host, pair: !paired) }
              .buttonStyle(CapsuleButtonStyle(kind: paired ? .destructive : .standard))
              .disabled(switching)
          }
        }
      }
    } footer: {
      if let hostError { failure(hostError) }
    }
  }

  private func failure(_ text: String) -> some View {
    Text(text).font(Chrome.font(.secondary)).foregroundStyle(Chrome.bad)
  }

  private func turn(_ on: Bool) {
    switching = true
    switchError = nil
    hostError = nil
    Task {
      defer { switching = false }
      do throws(PushPairings.Failure) {
        if on { try await pairings.turnOn() } else { try await pairings.turnOff() }
      } catch {
        switchError = error.message
      }
    }
  }

  private func change(_ host: Host, pair: Bool) {
    busy.insert(host.id)
    hostError = nil
    Task {
      defer { busy.remove(host.id) }
      do throws(PushPairings.Failure) {
        if pair { try await pairings.pair(host) } else { try await pairings.unpair(host) }
      } catch {
        hostError = error.message
      }
    }
  }

  /// The root row's value.
  static var summary: String {
    let pairings = PushPairings.shared
    guard pairings.relay != nil else { return "No Relay" }
    guard pairings.isOn else { return "Off" }
    let count = ConfigStore.shared.hosts.filter { pairings.pairing(for: $0) != nil }.count
    return count == 0 ? "On" : count == 1 ? "1 Host" : "\(count) Hosts"
  }
}
