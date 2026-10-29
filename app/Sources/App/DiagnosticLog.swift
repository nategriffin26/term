import Foundation
import QuartzCore
import os

/// The app's diagnostic log: one line per decision or state change, in
/// Library/Logs/term.log (the 2 MB before it in term.1.log), mirrored to the
/// unified log. scripts/pull-device-log.sh copies it off a phone.
///
/// A line holds names (hosts, tmux sessions) and numbers, never what a terminal
/// shows, nor what the user types, says, copies or keeps in files, nor a secret.
/// Callers log decisions and transitions, never per frame or per byte.
final class DiagnosticLog: @unchecked Sendable {
  enum Category: String, Sendable {
    case app, scene, tap, scroll, pager, keyboard, grid, menu, connection, voice, screen, notification, rail
  }

  /// Records `event` with its `fields` (`key=value` pairs, space-separated),
  /// which the caller builds. Here the calling thread only takes the time; the
  /// timestamp, the line and the writing are done on the log's queue.
  static func record(_ category: Category, _ event: String, _ fields: String = "") {
    let now = Date()
    shared.queue.async { shared.append(category, event, fields, at: now) }
  }

  /// Writes what is buffered before returning: the app is leaving the screen or quitting.
  static func flush() {
    shared.queue.sync { shared.write() }
  }

  /// `t` seconds to the millisecond.
  static func seconds(_ t: Double) -> String { String(format: "%.3f", t) }

  /// A fraction (0...1) to three places.
  static func fraction(_ x: Double) -> String { String(format: "%.3f", x) }

  /// A name quoted so spaces and `=` cannot split it into fields.
  static func name(_ s: String) -> String { s.debugDescription }

  /// The kind of a connection or Screen failure, from the wording of the
  /// core's errors (core/ssh/src/error.rs, core/ssh/src/mosh.rs,
  /// core/termcore/src/remote.rs). Never the text itself: it can carry the
  /// remote's stderr or shell output.
  static func failure(_ message: String) -> String {
    let m = message.lowercased()
    if m.isEmpty { return "none" }
    if m == "connection lost" { return "lost" }
    // Bootstrap errors end in the server's stderr, which may say anything: match them first.
    if m.contains("mosh-server") || m.contains("mosh connect") || m.contains("detached server pid") { return "mosh-bootstrap" }
    if m.hasPrefix("cannot resolve") { return "dns" }
    if m.hasPrefix("cannot connect") {
      return m.contains("refused") ? "refused" : m.contains("timed out") ? "timeout" : "connect"
    }
    if m.hasPrefix("host key changed") { return "host-key" }
    if m.hasPrefix("authentication failed") { return "auth" }
    if m.hasPrefix("invalid key") { return "key" }
    if m.hasPrefix("ssh protocol error") { return m.contains("timed out") ? "timeout" : "protocol" }
    if m.hasPrefix("mosh:") { return "mosh" }
    return "other"
  }

  /// The three clocks a touch time may be compared with, in seconds: uptime
  /// (`ProcessInfo.systemUptime`), media (`CACurrentMediaTime`) and continuous
  /// (`mach_continuous_time`, which keeps counting while the device sleeps).
  static var clocks: String {
    "uptime=\(seconds(ProcessInfo.processInfo.systemUptime)) media=\(seconds(CACurrentMediaTime()))"
      + " continuous=\(seconds(Double(mach_continuous_time()) * tickSeconds))"
  }

  private static let tickSeconds: Double = {
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return Double(base.numer) / Double(base.denom) / 1e9
  }()

  /// The size at which term.log moves to term.1.log.
  private static let limit = 2_000_000
  private static let flushDelay: DispatchTimeInterval = .seconds(1)
  private static let bufferLimit = 64 * 1024

  private static let shared: DiagnosticLog = {
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    return DiagnosticLog(directory: library.appending(path: "Logs", directoryHint: .isDirectory))
  }()

  private let queue = DispatchQueue(label: "term.diagnostic-log", qos: .utility)
  private let directory: URL
  private let file: URL
  private let previous: URL
  private let subsystem = Bundle.main.bundleIdentifier ?? "term"

  // Touched only on `queue`.
  private var pending = Data()
  private var flushScheduled = false
  private var handle: FileHandle?
  private var size = 0
  private var loggers: [Category: Logger] = [:]

  private init(directory: URL) {
    self.directory = directory
    file = directory.appending(path: "term.log")
    previous = directory.appending(path: "term.1.log")
  }

  private func append(_ category: Category, _ event: String, _ fields: String, at date: Date) {
    let body = fields.isEmpty ? event : event + " " + fields
    logger(category).log("\(body, privacy: .public)")
    pending.append(contentsOf: "\(Self.timestamp(date)) \(category.rawValue) \(body)\n".utf8)
    if pending.count >= Self.bufferLimit {
      write()
    } else if !flushScheduled {
      flushScheduled = true
      queue.asyncAfter(deadline: .now() + Self.flushDelay) { [self] in write() }
    }
  }

  private func logger(_ category: Category) -> Logger {
    if let logger = loggers[category] { return logger }
    let logger = Logger(subsystem: subsystem, category: category.rawValue)
    loggers[category] = logger
    return logger
  }

  /// Appends the buffer to term.log, first moving a full log to term.1.log.
  private func write() {
    flushScheduled = false
    guard !pending.isEmpty else { return }
    if handle == nil { open() }
    if size > 0, size + pending.count > Self.limit { rotate() }
    guard let handle else {
      // No file to write to: drop these lines rather than hold them without bound.
      pending.removeAll(keepingCapacity: false)
      return
    }
    do {
      try handle.write(contentsOf: pending)
      size += pending.count
    } catch {
      // The disk is full or the file went away: drop these lines and reopen next time.
      try? handle.close()
      self.handle = nil
    }
    pending.removeAll(keepingCapacity: true)
  }

  private func open() {
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: file), let end = try? handle.seekToEnd() else { return }
    self.handle = handle
    size = Int(end)
  }

  private func rotate() {
    try? handle?.close()
    handle = nil
    let manager = FileManager.default
    try? manager.removeItem(at: previous)
    try? manager.moveItem(at: file, to: previous)
    open()
  }

  /// Local wall-clock time to the millisecond: 2026-10-27 19:42:03.127.
  private static func timestamp(_ date: Date) -> String {
    let t = date.timeIntervalSince1970
    var seconds = time_t(t.rounded(.down))
    var parts = tm()
    localtime_r(&seconds, &parts)
    let ms = min(999, Int((t - t.rounded(.down)) * 1000))
    return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                  parts.tm_hour, parts.tm_min, parts.tm_sec, ms)
  }
}
