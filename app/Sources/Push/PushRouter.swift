import CryptoKit
import Foundation

/// Turns a tapped push into the exact pane it came from: the pairing names
/// the host, the host's panes (listed over SSH with its pinned key) are
/// hashed with the routing key until one matches, and that pane is selected
/// in its session. Anything less is an error, never a different pane.
@MainActor
enum PushRouter {
  enum Failure: Error, Equatable {
    case notPaired
    case hostKeyNotPinned(String)
    case unreachable(String, String)
    case tmuxNotRunning(String)
    case paneGone(String)
    case failed(String, String)

    var message: String {
      switch self {
      case .notPaired: "That host is no longer paired. Pair it again in Settings › Notifications."
      case .hostKeyNotPinned(let alias): "Connect to \(alias) once so Term knows its host key, then tap again."
      case .unreachable(let alias, let why): "Couldn't reach \(alias): \(why)"
      case .tmuxNotRunning(let alias): "tmux isn't running on \(alias), so that agent's pane is gone."
      case .paneGone(let alias): "That agent's pane on \(alias) has closed."
      case .failed(let alias, let why): "Couldn't open the pane on \(alias): \(why)"
      }
    }

    /// For the diagnostic log: the kind, never a host's words.
    var kind: String {
      switch self {
      case .notPaired: "not-paired"
      case .hostKeyNotPinned: "host-key-not-pinned"
      case .unreachable: "unreachable"
      case .tmuxNotRunning: "tmux-not-running"
      case .paneGone: "pane-gone"
      case .failed: "failed"
      }
    }
  }

  struct Target: Equatable {
    var host: Host
    var pane: TmuxPane
  }

  static func resolve(_ route: PushRoute, pairings: PushPairings = .shared,
                      hosts: [Host] = ConfigStore.shared.hosts) async -> Result<Target, Failure> {
    guard let pairing = pairings.pairing(id: route.pairingID),
          let host = hosts.first(where: { $0.id == pairing.hostID }),
          let key = Hex.data(pairing.routingKey).map({ SymmetricKey(data: $0) })
    else { return .failure(.notPaired) }
    let spec = Tab.spec(for: host)
    guard spec.hostKey != nil else { return .failure(.hostKeyNotPinned(host.alias)) }

    let listed: RemoteExec.Output
    switch await RemoteExec.run(spec, PaneRoute.listCommand) {
    case .failure(let failure): return .failure(.unreachable(host.alias, failure.message))
    case .success(let output): listed = output
    }
    if listed.status != 0 {
      let text = String(decoding: listed.stdout, as: UTF8.self)
      if listed.status == 127 { return .failure(.failed(host.alias, "tmux isn't installed")) }
      if Tmux.readableError(text) == "tmux isn't running" { return .failure(.tmuxNotRunning(host.alias)) }
      return .failure(.failed(host.alias, Tmux.readableError(text)))
    }
    guard let pane = PaneRoute.pane(route.sessionRef, in: PaneRoute.parse(listed.stdout), routingKey: key) else {
      return .failure(.paneGone(host.alias))
    }
    return .success(Target(host: host, pane: pane))
  }

  /// Selects the resolved pane for a tab already on its session, rechecking
  /// session and server generation on the host first. nil when it is selected.
  static func select(_ target: Target) async -> Failure? {
    switch await RemoteExec.run(Tab.spec(for: target.host), PaneRoute.selectCommand(target.pane)) {
    case .failure(let failure): .unreachable(target.host.alias, failure.message)
    case .success(let output) where output.status == PaneRoute.goneStatus: .paneGone(target.host.alias)
    case .success(let output) where output.status != 0:
      .failed(target.host.alias, Tmux.readableError(String(decoding: output.stdout, as: UTF8.self)))
    case .success: nil
    }
  }
}
