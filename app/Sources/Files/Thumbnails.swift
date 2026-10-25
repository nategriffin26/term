import CryptoKit
import UIKit

/// Row thumbnails for small images: read over SFTP (term_fs_read), shrunk,
/// kept in memory and as JPEGs in Caches so a relaunch draws them at once.
@MainActor
final class Thumbnails {
  static let maxBytes: UInt64 = 12_000_000
  /// Pixels on the short side (38 pt at 3x).
  nonisolated static let pixels: CGFloat = 120
  private static let concurrent = 4

  private let memory = NSCache<NSString, UIImage>()
  private let directory: URL
  private var inflight: [String: Task<UIImage?, Never>] = [:]
  private var running = 0
  private var queue: [CheckedContinuation<Void, Never>] = []

  init(directory: URL = URL.cachesDirectory.appending(path: "thumbs", directoryHint: .isDirectory)) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  static func wants(_ entry: RemoteEntry) -> Bool {
    guard !entry.isDirectory, !entry.isBroken, entry.size > 0, entry.size <= maxBytes else { return false }
    return FileKind.of(entry) == .image && FilePath.ext(entry.name) != "svg"
  }

  /// Already drawn, without asking the host.
  func cached(_ entry: RemoteEntry, fs: RemoteFS) -> UIImage? {
    memory.object(forKey: key(entry, fs) as NSString)
  }

  func image(_ entry: RemoteEntry, fs: RemoteFS) async -> UIImage? {
    let key = key(entry, fs)
    if let hit = memory.object(forKey: key as NSString) { return hit }
    if let task = inflight[key] { return await task.value }
    let file = directory.appending(path: key + ".jpg")
    let task = Task<UIImage?, Never> {
      if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
      await acquire()
      defer { release() }
      guard let data = try? await fs.read(entry.path, max: entry.size) else { return nil }
      let image = await Task.detached(priority: .utility) { Self.shrink(data) }.value
      if let jpeg = image?.jpegData(compressionQuality: 0.8) { try? jpeg.write(to: file, options: .atomic) }
      return image
    }
    inflight[key] = task
    let image = await task.value
    inflight[key] = nil
    if let image { memory.setObject(image, forKey: key as NSString) }
    return image
  }

  nonisolated private static func shrink(_ data: Data) -> UIImage? {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
    let scale = pixels / min(image.size.width * image.scale, image.size.height * image.scale)
    guard scale < 1 else { return image }
    let size = CGSize(width: (image.size.width * image.scale * scale).rounded(), height: (image.size.height * image.scale * scale).rounded())
    return image.preparingThumbnail(of: size)
  }

  private func key(_ entry: RemoteEntry, _ fs: RemoteFS) -> String {
    let digest = SHA256.hash(data: Data("\(fs.hostKey)\n\(entry.path)\n\(Int64(entry.mtime.timeIntervalSince1970))".utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  private func acquire() async {
    if running < Self.concurrent {
      running += 1
      return
    }
    await withCheckedContinuation { queue.append($0) }
  }

  private func release() {
    if queue.isEmpty {
      running -= 1
    } else {
      queue.removeFirst().resume()
    }
  }
}
