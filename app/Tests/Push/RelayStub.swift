import Foundation
import Network

/// An HTTP/1.1 server on 127.0.0.1 standing in for the push relay. It answers
/// each request as the Worker does (relay/src: statuses and bodies its
/// tests assert) through `answer`, and keeps every request it received.
final class RelayStub: @unchecked Sendable {
  struct Request {
    var method: String
    var path: String
    var authorization: String?
    var body: [String: Any]
    var raw: String
  }

  struct Reply {
    var status: Int
    var body = ""
    /// A redirect's target, sent as Location.
    var location: String?
  }

  private(set) var baseURL = URL(string: "http://127.0.0.1")!
  private let listener: NWListener
  private let queue = DispatchQueue(label: "RelayStub")
  private let lock = NSLock()
  private var received: [Request] = []
  /// nil: the request is kept, then the connection closes unanswered (a lost answer).
  private let answer: @Sendable (Request) -> Reply?

  var requests: [Request] { lock.withLock { received } }

  init(answer: @escaping @Sendable (Request) -> Reply?) async throws {
    self.answer = answer
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let resume = Resume(continuation)
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready: resume(.success(listener.port?.rawValue ?? 0))
        case .failed(let error): resume(.failure(error))
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
      listener.start(queue: queue)
    }
    baseURL = URL(string: "http://127.0.0.1:\(port)")!
  }

  private final class Resume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func callAsFunction(_ result: Result<UInt16, Error>) {
      lock.withLock {
        continuation?.resume(with: result)
        continuation = nil
      }
    }
  }

  func stop() { listener.cancel() }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, Data())
  }

  private func read(_ connection: NWConnection, _ buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
      guard let self, error == nil else { return connection.cancel() }
      let buffer = buffer + (data ?? Data())
      guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        return done ? connection.cancel() : read(connection, buffer)
      }
      let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self).split(separator: "\r\n").map(String.init)
      let header = { (name: String) in
        head.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }
          .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
      }
      let length = header("content-length").flatMap(Int.init) ?? 0
      let body = buffer[split.upperBound...]
      guard body.count >= length else { return done ? connection.cancel() : read(connection, buffer) }
      let line = head.first?.split(separator: " ").map(String.init) ?? []
      let raw = Data(body.prefix(length))
      let request = Request(method: line.first ?? "", path: line.count > 1 ? line[1] : "",
                            authorization: header("authorization"),
                            body: (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:],
                            raw: String(decoding: raw, as: UTF8.self))
      lock.withLock { received.append(request) }
      guard let reply = answer(request) else { return connection.cancel() }
      let payload = Data(reply.body.utf8)
      let location = reply.location.map { "Location: \($0)\r\n" } ?? ""
      let response = "HTTP/1.1 \(reply.status) Stub\r\nContent-Type: application/json\r\n\(location)Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
