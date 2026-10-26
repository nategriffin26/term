import Foundation
import os

enum ScreenLog {
  static let video = Logger(subsystem: AppIdentity.bundleID, category: "screen")
}

/// A byte stream to a socket on the Mac through its own SSH connection
/// (term_tunnel_*). Events arrive on the core's thread.
final class ScreenTunnel: @unchecked Sendable {
  enum Event {
    case data(Data)
    /// Nothing follows. `opened`: the socket answered before it ended.
    case closed(String, opened: Bool)
  }

  /// How the core's reason starts when SSH worked but the socket refused.
  static let socketRefusedPrefix = "The host could not open "

  private let lock = NSLock()
  private var handle: OpaquePointer?
  private let sink: Sink

  init(spec: ConnectSpec, target: String, onEvent: @escaping @Sendable (Event) -> Void) {
    sink = Sink(onEvent)
    let callbacks = TermCallbacks(ctx: Unmanaged.passRetained(sink).toOpaque()) { ctx, kind, data, len in
      guard let ctx else { return }
      Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().receive(kind, data, len)
    }
    handle = spec.withTermConnect(cols: 0, rows: 0) { term_tunnel_open($0, target, callbacks) }
    if handle == nil {
      Unmanaged.passUnretained(sink).release()
      onEvent(.closed("Term could not start a connection.", opened: false))
    }
  }

  func write(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard let handle else { return }
    data.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      term_tunnel_write(handle, base, raw.count)
    }
  }

  /// Ends the tunnel and its SSH connection; no event follows. Safe to call twice.
  func close() {
    lock.lock()
    let closing = handle
    handle = nil
    lock.unlock()
    guard let closing else { return }
    term_tunnel_free(closing)
    // No callback runs after term_tunnel_free returns: drop the core's reference.
    Unmanaged.passUnretained(sink).release()
  }

  private final class Sink: @unchecked Sendable {
    private let onEvent: @Sendable (Event) -> Void
    private var opened = false

    init(_ onEvent: @escaping @Sendable (Event) -> Void) { self.onEvent = onEvent }

    /// The core's thread, one event at a time.
    func receive(_ kind: UInt32, _ data: UnsafePointer<UInt8>?, _ len: Int) {
      let bytes = data.map { Data(bytes: $0, count: len) } ?? Data()
      switch kind {
      case TERM_TUNNEL_OPEN.rawValue: opened = true
      case TERM_TUNNEL_DATA.rawValue: onEvent(.data(bytes))
      case TERM_TUNNEL_CLOSED.rawValue: onEvent(.closed(String(decoding: bytes, as: UTF8.self), opened: opened))
      default: break
      }
    }
  }
}
