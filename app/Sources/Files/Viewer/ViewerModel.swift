import Foundation
import Observation

/// How much of a text file the viewer reads, and how: up to 1 MB in one
/// read, up to 16 MB through the cache with progress, beyond that its first
/// 1 MB. Text over 5 MB opens read-only.
enum LoadPlan: Equatable {
  case read
  case fetch
  case head(UInt64)

  static let mb: UInt64 = 1 << 20
  static let readLimit = 1 * mb
  static let fetchLimit = 16 * mb
  static let editLimit = 5 * mb
  /// A name that says nothing: a file up to this size is read whole and
  /// sniffed, a bigger one by its first `sniffHead` bytes.
  static let sniffWhole: UInt64 = 64 << 10
  static let sniffHead: UInt64 = 4 << 10

  static func text(size: UInt64) -> LoadPlan {
    if size <= readLimit { return .read }
    if size <= fetchLimit { return .fetch }
    return .head(readLimit)
  }

  /// Why text of this size opens read-only, in one line.
  static func readOnlyReason(size: UInt64) -> String? {
    if size > fetchLimit { return "First 1 MB of \(FileFormat.size(size)) · read-only" }
    if size > editLimit { return "Over 5 MB · read-only" }
    return nil
  }
}

/// One file in the viewer: what it is, its contents (text in a
/// TextDocument, anything else as a local copy or its first bytes), and
/// saving with the host's mtime as the conflict check.
@MainActor @Observable
final class ViewerModel {
  enum Content {
    case text(TextDocument)
    /// A local copy for Quick Look, AVKit and images.
    case file(URL)
    /// The first bytes of a file nothing here draws.
    case binary(Data)
  }

  enum Phase {
    case loading
    case failed(String)
    case ready(Content)
  }

  enum SaveOutcome: Equatable {
    case saved
    case conflict
    case failed(String)
  }

  let fs: RemoteFS
  /// The stat's entry: canonical path, current size and mtime.
  private(set) var entry: RemoteEntry
  private(set) var kind: ViewerKind?
  private(set) var phase = Phase.loading
  /// Fraction of a download in progress (opening a large file, sharing).
  private(set) var progress: Double?
  /// Modified, staged or added in git: Git Diff has something to show.
  private(set) var gitChanged = false
  /// The view appearing again (back from a linked file) must not reload
  /// over unsaved edits.
  private var started = false

  init(entry: RemoteEntry, fs: RemoteFS) {
    self.entry = entry
    self.fs = fs
  }

  var document: TextDocument? {
    if case .ready(.text(let document)) = phase { return document }
    return nil
  }

  func loadOnce() async {
    guard !started else { return }
    started = true
    await load()
  }

  func load() async {
    phase = .loading
    progress = nil
    do {
      let stat = try await fs.stat(entry.path)
      entry = stat
      var whole: Data?
      var kind = ViewerKind.forName(stat.name)
      if kind == nil {
        let all = stat.size <= LoadPlan.sniffWhole
        let head = try await fs.read(stat.path, max: all ? LoadPlan.sniffWhole : LoadPlan.sniffHead)
        kind = ViewerKind.sniff(head)
        if all { whole = head }
      }
      let decided = kind ?? .binary
      self.kind = decided
      if decided.isTextual {
        let data = if let whole { whole } else { try await textBytes(stat) }
        phase = .ready(decode(data, stat: stat, language: decided.sourceLanguage))
      } else if decided == .binary {
        let head = if let whole { whole } else { try await fs.read(stat.path, max: LoadPlan.sniffHead) }
        phase = .ready(.binary(head.prefix(Int(LoadPlan.sniffHead))))
      } else {
        phase = .ready(.file(try await localCopy()))
      }
      progress = nil
    } catch {
      progress = nil
      phase = .failed(Self.message(error))
      return
    }
    await refreshGit()
  }

  /// The local copy (from the cache when current), with progress.
  func localCopy() async throws -> URL {
    defer { progress = nil }
    return try await FileCache.shared.fetch(entry, fs: fs) { [weak self] fraction in self?.progress = fraction }
  }

  /// Writes `text` over the host's copy unless it changed since it was read
  /// (`force` writes regardless), then takes the new mtime as the baseline.
  func save(_ text: String, document: TextDocument, force: Bool) async -> SaveOutcome {
    let temp = FileManager.default.temporaryDirectory.appending(path: "save-\(UUID().uuidString)", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: temp) }
    do {
      try document.encoded(text).write(to: temp)
      try await fs.upload(temp, to: document.path, ifMtime: force ? nil : document.mtime) { _ in }
      let stat = try await fs.stat(document.path)
      entry = stat
      document.saved(text, mtime: stat.mtime)
    } catch RemoteFSError.changedOnHost {
      return .conflict
    } catch {
      return .failed(Self.message(error))
    }
    await refreshGit()
    return .saved
  }

  /// Replaces the document's text with the host's, dropping unsaved edits.
  func reload(_ document: TextDocument) async throws {
    let (text, stat) = try await hostText(document)
    entry = stat
    document.reloaded(text, mtime: stat.mtime)
    await refreshGit()
  }

  /// The host's current text of the document's file.
  func hostText(_ document: TextDocument) async throws -> (String, RemoteEntry) {
    let stat = try await fs.stat(document.path)
    let data = try await textBytes(stat)
    return (ViewerKind.decodeUTF8(data) ?? String(decoding: data, as: UTF8.self), stat)
  }

  func gitDiff() async throws -> [DiffLine] {
    let q = Command.shellQuote
    let name = q(entry.name)
    let command = "cd \(q(FilePath.parent(entry.path))) && { git --no-pager diff --no-ext-diff --no-color HEAD -- \(name) 2>/dev/null"
      + " || git --no-pager diff --no-ext-diff --no-color --cached -- \(name); }"
    let out = try await fs.exec(command)
    return UnifiedDiff.parse(String(decoding: out.stdout, as: UTF8.self))
  }

  func refreshGit() async {
    guard let out = try? await fs.exec(GitStatus.command(FilePath.parent(entry.path))),
          let change = GitStatus.parse(out.stdout)?.change(at: entry.path, isDirectory: false) else {
      gitChanged = false
      return
    }
    gitChanged = change != .untracked && change != .deleted
  }

  // MARK: - Text

  private func textBytes(_ stat: RemoteEntry) async throws -> Data {
    switch LoadPlan.text(size: stat.size) {
    case .read:
      return try await fs.read(stat.path, max: LoadPlan.readLimit)
    case .fetch:
      let url = try await FileCache.shared.fetch(stat, fs: fs) { [weak self] fraction in self?.progress = fraction }
      return try Data(contentsOf: url, options: .mappedIfSafe)
    case .head(let bytes):
      return try await fs.read(stat.path, max: bytes)
    }
  }

  /// Text as a document; bytes with NULs as binary. Text that is not UTF-8
  /// opens read-only rather than being rewritten in another encoding.
  private func decode(_ data: Data, stat: RemoteEntry, language: SourceLanguage?) -> Content {
    var reason = LoadPlan.readOnlyReason(size: stat.size)
    let text: String
    if let decoded = ViewerKind.decodeUTF8(data) {
      text = decoded
    } else if !data.contains(0) {
      text = String(decoding: data, as: UTF8.self)
      reason = reason ?? "Not UTF-8 · read-only"
    } else {
      kind = .binary
      return .binary(data.prefix(Int(LoadPlan.sniffHead)))
    }
    return .text(TextDocument(path: stat.path, text: text, hasBOM: data.starts(with: [0xEF, 0xBB, 0xBF]),
                              mtime: stat.mtime, language: language, readOnlyReason: reason))
  }

  static func message(_ error: Error) -> String {
    (error as? RemoteFSError)?.message ?? error.localizedDescription
  }
}
