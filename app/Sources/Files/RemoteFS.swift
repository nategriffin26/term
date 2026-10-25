import CryptoKit
import Foundation
import Synchronization

/// One file or folder on a host. Symlinks carry their target's size, mode
/// and mtime when they resolve.
struct RemoteEntry: Hashable, Sendable {
  var path: String
  var name: String
  var size: UInt64
  var mtime: Date
  var mode: UInt32
  var isSymlink: Bool
  var isBroken: Bool

  var isDirectory: Bool { mode & 0o170000 == 0o040000 }
  var isExecutable: Bool { !isDirectory && mode & 0o111 != 0 }
  var isHidden: Bool { name.hasPrefix(".") }
}

/// Every RemoteFS failure. The core reports "changed on the host" (an upload
/// with if_mtime found newer work) and "cancelled" (term_fs_cancel) exactly.
enum RemoteFSError: Error, Equatable {
  case changedOnHost
  case cancelled
  case failed(String)

  init(core message: String) {
    switch message {
    case "changed on the host": self = .changedOnHost
    case "cancelled": self = .cancelled
    default: self = .failed(Self.plain(message))
    }
  }

  /// SFTP statuses arrive as "<code>: <server text>", and OpenSSH's text is
  /// the code again ("No such file: No such file"): say it once.
  private static func plain(_ message: String) -> String {
    guard let range = message.range(of: ": ") else { return message }
    let code = message[..<range.lowerBound]
    return message[range.upperBound...] == code ? String(code) : message
  }

  var message: String {
    switch self {
    case .changedOnHost: "Changed on the host"
    case .cancelled: "Cancelled"
    case .failed(let message): message
    }
  }

  /// The path does not exist (SFTP's "no such file").
  var isMissing: Bool {
    if case .failed(let message) = self { return message.localizedCaseInsensitiveContains("no such file") }
    return false
  }
}

/// A host's files over SFTP on the cached SSH connection (term_fs_*), plus
/// commands over term_exec. Cancelling the calling Task cancels a transfer.
/// Not main-actor: the core calls the C callbacks on its own threads, and a
/// callback written inside a main-actor class traps there.
final class RemoteFS: Sendable {
  let spec: ConnectSpec

  init(spec: ConnectSpec) {
    self.spec = spec
  }

  /// "user@host:port": names this host in saved state and caches.
  var hostKey: String { "\(spec.user)@\(spec.hostname):\(spec.port)" }

  func list(_ path: String) async throws -> [RemoteEntry] {
    let raw = try await files { c, ctx, done in term_fs_list(c, path, ctx, done) }
    return raw.map { $0.entry(path: FilePath.join(path, $0.name)) }
  }

  /// The entry at `path`, named by its canonical absolute path.
  func stat(_ path: String) async throws -> RemoteEntry {
    let raw = try await files { c, ctx, done in term_fs_stat(c, path, ctx, done) }
    guard let first = raw.first else { throw RemoteFSError.failed("no entry for \(path)") }
    return first.entry(path: first.name)
  }

  /// Up to `max` bytes from the start of a file.
  func read(_ path: String, max: UInt64) async throws -> Data {
    try await withCheckedContinuation { (c: CheckedContinuation<Result<Data, RemoteFSError>, Never>) in
      let ctx = Unmanaged.passRetained(BytesBox(c)).toOpaque()
      spec.withTermConnect(cols: 0, rows: 0) { conn in
        term_fs_read(conn, path, max, ctx) { ctx, data, len, error in
          let box = Unmanaged<BytesBox>.fromOpaque(ctx!).takeRetainedValue()
          if let error {
            box.continuation.resume(returning: .failure(RemoteFSError(core: String(cString: error))))
          } else {
            box.continuation.resume(returning: .success(data.map { Data(bytes: $0, count: len) } ?? Data()))
          }
        }
      }
    }.get()
  }

  func mkdir(_ path: String) async throws {
    try await op(UInt32(TERM_FS_MKDIR.rawValue), path, nil)
  }

  /// Fails when `to` exists.
  func rename(_ path: String, to: String) async throws {
    try await op(UInt32(TERM_FS_RENAME.rawValue), path, to)
  }

  /// A file, symlink or empty folder.
  func remove(_ path: String) async throws {
    try await op(UInt32(TERM_FS_REMOVE.rawValue), path, nil)
  }

  func download(_ remote: String, to local: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
    let localPath = local.path(percentEncoded: false)
    try await transfer(progress: progress) { c, ctx, onProgress, done in
      term_fs_download(c, remote, localPath, ctx, onProgress, done)
    }
  }

  /// Atomic on the host; with `ifMtime`, fails with .changedOnHost when the
  /// target's mtime is not that one.
  func upload(_ local: URL, to remote: String, ifMtime: Date?, progress: @escaping @MainActor (Double) -> Void) async throws {
    let localPath = local.path(percentEncoded: false)
    let mtime = ifMtime.map { Int64($0.timeIntervalSince1970.rounded()) } ?? -1
    try await transfer(progress: progress) { c, ctx, onProgress, done in
      term_fs_upload(c, localPath, remote, mtime, ctx, onProgress, done)
    }
  }

  func exec(_ command: String) async throws -> (status: Int32, stdout: Data) {
    switch await RemoteExec.run(spec, command) {
    case .success(let out): return (out.status, out.stdout)
    case .failure(let failure): throw RemoteFSError.failed(failure.message)
    }
  }

  // MARK: - Bridging

  private func files(
    _ call: (UnsafePointer<TermConnect>, UnsafeMutableRawPointer, TermFilesFn) -> Void
  ) async throws -> [RawEntry] {
    try await withCheckedContinuation { (c: CheckedContinuation<Result<[RawEntry], RemoteFSError>, Never>) in
      let ctx = Unmanaged.passRetained(FilesBox(c)).toOpaque()
      spec.withTermConnect(cols: 0, rows: 0) { conn in
        call(conn, ctx) { ctx, entries, count, error in
          let box = Unmanaged<FilesBox>.fromOpaque(ctx!).takeRetainedValue()
          if let error {
            box.continuation.resume(returning: .failure(RemoteFSError(core: String(cString: error))))
            return
          }
          var out: [RawEntry] = []
          out.reserveCapacity(count)
          for i in 0..<count {
            guard let e = entries?[i], let name = e.name else { continue }
            out.append(RawEntry(name: String(cString: name), size: e.size, mtime: e.mtime, mode: e.mode, flags: e.flags))
          }
          box.continuation.resume(returning: .success(out))
        }
      }
    }.get()
  }

  private func op(_ kind: UInt32, _ path: String, _ to: String?) async throws {
    try await withCheckedContinuation { (c: CheckedContinuation<Result<Void, RemoteFSError>, Never>) in
      let ctx = Unmanaged.passRetained(DoneBox(c)).toOpaque()
      spec.withTermConnect(cols: 0, rows: 0) { conn in
        let done: TermFsDoneFn = { ctx, error in
          let box = Unmanaged<DoneBox>.fromOpaque(ctx!).takeRetainedValue()
          box.continuation.resume(returning: error.map { .failure(RemoteFSError(core: String(cString: $0))) } ?? .success(()))
        }
        if let to {
          term_fs_op(conn, kind, path, to, ctx, done)
        } else {
          term_fs_op(conn, kind, path, nil, ctx, done)
        }
      }
    }.get()
  }

  private func transfer(
    progress: @escaping @MainActor (Double) -> Void,
    _ start: (UnsafePointer<TermConnect>, UnsafeMutableRawPointer, TermProgressFn, TermFsDoneFn) -> UInt64
  ) async throws {
    if Task.isCancelled { throw RemoteFSError.cancelled }
    let control = TransferControl()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (c: CheckedContinuation<Result<Void, RemoteFSError>, Never>) in
        let ctx = Unmanaged.passRetained(TransferBox(c, progress: progress)).toOpaque()
        let id = spec.withTermConnect(cols: 0, rows: 0) { conn in
          start(conn, ctx, { ctx, done, total in
            let box = Unmanaged<TransferBox>.fromOpaque(ctx!).takeUnretainedValue()
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            let report = box.progress
            DispatchQueue.main.async { MainActor.assumeIsolated { report(fraction) } }
          }, { ctx, error in
            let box = Unmanaged<TransferBox>.fromOpaque(ctx!).takeRetainedValue()
            box.continuation.resume(returning: error.map { .failure(RemoteFSError(core: String(cString: $0))) } ?? .success(()))
          })
        }
        control.started(id)
      }
    } onCancel: {
      control.cancel()
    }
    try result.get()
  }
}

/// A TermFileEntry copied out of the callback.
private struct RawEntry: Sendable {
  var name: String
  var size: UInt64
  var mtime: Int64
  var mode: UInt32
  var flags: UInt32

  func entry(path: String) -> RemoteEntry {
    RemoteEntry(
      path: path, name: FilePath.name(path), size: size, mtime: Date(timeIntervalSince1970: TimeInterval(mtime)),
      mode: mode, isSymlink: flags & UInt32(TERM_FILE_SYMLINK) != 0,
      isBroken: flags & UInt32(TERM_FILE_BROKEN) != 0)
  }
}

private final class FilesBox: Sendable {
  let continuation: CheckedContinuation<Result<[RawEntry], RemoteFSError>, Never>
  init(_ c: CheckedContinuation<Result<[RawEntry], RemoteFSError>, Never>) { continuation = c }
}

private final class BytesBox: Sendable {
  let continuation: CheckedContinuation<Result<Data, RemoteFSError>, Never>
  init(_ c: CheckedContinuation<Result<Data, RemoteFSError>, Never>) { continuation = c }
}

private final class DoneBox: Sendable {
  let continuation: CheckedContinuation<Result<Void, RemoteFSError>, Never>
  init(_ c: CheckedContinuation<Result<Void, RemoteFSError>, Never>) { continuation = c }
}

private final class TransferBox: Sendable {
  let continuation: CheckedContinuation<Result<Void, RemoteFSError>, Never>
  let progress: @MainActor (Double) -> Void
  init(_ c: CheckedContinuation<Result<Void, RemoteFSError>, Never>, progress: @escaping @MainActor (Double) -> Void) {
    continuation = c
    self.progress = progress
  }
}

/// A cancel can arrive before term_fs_* has returned the transfer id.
private final class TransferControl: Sendable {
  private let state = Mutex<(id: UInt64?, cancelled: Bool)>((nil, false))

  func started(_ id: UInt64) {
    let cancel = state.withLock { s in
      s.id = id
      return s.cancelled
    }
    if cancel { term_fs_cancel(id) }
  }

  func cancel() {
    let id = state.withLock { s in
      s.cancelled = true
      return s.id
    }
    if let id { term_fs_cancel(id) }
  }
}

/// Downloaded copies of remote files, one per host + path at its latest
/// mtime, under Caches/files/<hash of host and path>/<mtime>/<name> so the
/// name (and its extension) stays for QuickLook, AVKit and sharing.
@MainActor
final class FileCache {
  static let shared = FileCache(root: URL.cachesDirectory.appending(path: "files", directoryHint: .isDirectory))

  let root: URL

  init(root: URL) {
    self.root = root
  }

  /// The local copy of `entry` at its current mtime, if downloaded.
  func url(for entry: RemoteEntry, fs: RemoteFS) -> URL? {
    let url = location(of: entry, fs: fs)
    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
  }

  /// Downloads `entry` unless this mtime is cached; older copies go.
  func fetch(_ entry: RemoteEntry, fs: RemoteFS, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
    if let hit = url(for: entry, fs: fs) { return hit }
    let url = location(of: entry, fs: fs)
    let version = url.deletingLastPathComponent()
    let file = version.deletingLastPathComponent()
    let manager = FileManager.default
    for old in (try? manager.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)) ?? [] where old != version {
      try? manager.removeItem(at: old)
    }
    try? manager.createDirectory(at: version, withIntermediateDirectories: true)
    try await fs.download(entry.path, to: url, progress: progress)
    return url
  }

  private func location(of entry: RemoteEntry, fs: RemoteFS) -> URL {
    let digest = SHA256.hash(data: Data("\(fs.hostKey)\n\(entry.path)".utf8))
    let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    return root
      .appending(path: key, directoryHint: .isDirectory)
      .appending(path: String(Int64(entry.mtime.timeIntervalSince1970)), directoryHint: .isDirectory)
      .appending(path: entry.name, directoryHint: .notDirectory)
  }
}
