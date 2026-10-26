import Foundation

/// Segments' audio while it waits for its text: one m4a file each in
/// Caches, so queued speech takes no memory and outlives the app. A file's
/// name is the launch that said it, then the segment's place in that
/// launch's order, so names sort in spoken order across launches.
struct SpeechSpool: Sendable {
  let directory: URL
  /// This launch, as nanoseconds since 1970 (19 digits).
  private let launch: String

  init(directory: URL) {
    self.directory = directory
    launch = String(format: "%019llu", clock_gettime_nsec_np(CLOCK_REALTIME))
  }

  /// Writes segment `id`'s audio; returns its file.
  func write(_ audio: Data, id: Int) throws -> URL {
    let url = directory.appending(path: "\(launch)-\(String(format: "%09d", id)).m4a")
    try audio.write(to: url, options: .withoutOverwriting)
    return url
  }

  func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// Files earlier launches left, in spoken order.
  func leftovers() -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files
      .filter { $0.pathExtension == "m4a" && !$0.lastPathComponent.hasPrefix(launch) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}
