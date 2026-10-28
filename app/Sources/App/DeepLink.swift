import Foundation

/// A link another app opens Term with.
enum DeepLink: Equatable {
  /// `term://attach?host=<alias>&session=<name>`: tmux session `name` on the
  /// saved host with that alias, in the tab already attached to it, else a new one.
  case attach(host: String, session: String)

  init?(_ url: URL) {
    guard url.scheme?.lowercased() == "term", url.host() == "attach",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
          let session = items.first(where: { $0.name == "session" })?.value, !session.isEmpty
    else { return nil }
    self = .attach(host: host, session: session)
  }
}
