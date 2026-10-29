import Foundation

/// The push relay this build talks to: `TERM_RELAY_URL` in app/Config
/// (Info.plist `TermRelayURL`). nil when the build sets none.
enum RelayConfig {
  static let url: URL? = parse(Bundle.main.object(forInfoDictionaryKey: "TermRelayURL") as? String)

  /// HTTPS, or HTTP to this machine (`wrangler dev`); no query or fragment.
  static func parse(_ value: String?) -> URL? {
    guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
          let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
          components.query == nil, components.fragment == nil, components.user == nil
    else { return nil }
    switch components.scheme?.lowercased() {
    case "https": break
    case "http" where ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()): break
    default: return nil
    }
    return components.url
  }
}

/// The relay's endpoints (relay/src/contract.ts). Sends only what the
/// contract names; never terminal content, host names or the routing key.
struct RelayClient: Sendable {
  enum Failure: Error, Equatable {
    /// No answer: offline, the relay down, or a timeout.
    case unreachable(String)
    /// The relay does not accept this phone's device secret, or no longer knows the device.
    case deviceUnknown
    case rateLimited
    case rejected(status: Int)
    /// An answer that breaks the contract.
    case malformed

    var message: String {
      switch self {
      case .unreachable(let why): "Couldn't reach the relay: \(why)"
      case .deviceUnknown: "The relay no longer knows this iPhone. Turn Notifications off and on again."
      case .rateLimited: "The relay is busy. Try again in a minute."
      case .rejected(409): "This push token is registered to another installation. Turn Notifications off there, or ask the relay operator to remove its old registration."
      case .rejected(let status): "The relay refused the request (HTTP \(status))."
      case .malformed: "The relay sent an answer Term doesn't understand. Update Term."
      }
    }
  }

  struct Device: Codable, Equatable, Sendable {
    var device_id: String
    var device_secret: String
    var token: String
    var environment: String
  }

  struct Ping: Codable, Equatable, Sendable {
    var install_id: String
    var host_ok: Bool
    var screen_opened: Bool
    var ask_answered: Bool
  }

  let base: URL
  var session: URLSession = .relay

  func registerDevice(_ device: Device) async throws(Failure) {
    _ = try await send("POST", "devices", device, bearer: nil)
  }

  /// Forgets the device and every pairing made through it. A device the relay
  /// refuses (unknown, or another secret) is no use to this phone either.
  func deleteDevice(id: String, secret: String) async throws(Failure) {
    do throws(Failure) {
      _ = try await send("DELETE", "devices", ["device_id": id], bearer: secret)
    } catch {
      if error != .deviceUnknown { throw error }
    }
  }

  /// Registers a pairing secret; returns its pairing id, which the relay
  /// derives from the secret (SHA-256 of its hex) and must equal ours.
  func pair(deviceID: String, deviceSecret: String, secret: String) async throws(Failure) -> String {
    let data = try await send("POST", "pairings", ["device_id": deviceID, "secret": secret], bearer: deviceSecret)
    struct Answer: Decodable { var pairing_id: String }
    guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.pairing_id == Hex.sha256(secret)
    else { throw .malformed }
    return answer.pairing_id
  }

  /// Revokes a pairing; the relay answers one already gone as revoked.
  func unpair(deviceID: String, deviceSecret: String, secret: String) async throws(Failure) {
    _ = try await send("DELETE", "pairings", ["device_id": deviceID, "secret": secret], bearer: deviceSecret)
  }

  /// One completed day's flags; the relay keeps the first per install id per day.
  func ping(_ ping: Ping) async throws(Failure) {
    _ = try await send("POST", "ping", ping, bearer: nil)
  }

  private func send(_ method: String, _ path: String, _ body: some Encodable, bearer: String?) async throws(Failure) -> Data {
    var request = URLRequest(url: base.appending(path: path))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try? JSONEncoder().encode(body)
    let answer: (Data, URLResponse)
    do {
      answer = try await session.data(for: request)
    } catch {
      throw .unreachable(error.localizedDescription)
    }
    let (data, response) = answer
    guard let status = (response as? HTTPURLResponse)?.statusCode else { throw .malformed }
    switch status {
    case 200..<300: return data
    case 401, 403: throw .deviceUnknown
    case 429: throw .rateLimited
    default: throw .rejected(status: status)
    }
  }
}

extension URLSession {
  /// No cookies, cache or credentials kept between relay calls, and no
  /// redirects: a 3xx would carry the device secret to another origin, so it
  /// comes back as the answer and is refused.
  static let relay: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }()
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}
