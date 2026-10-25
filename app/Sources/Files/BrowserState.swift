import Foundation

/// One sort for every folder, the user's choice rather than the folder's: it
/// stays as they set it across folders and relaunches. Newest first until
/// they change it.
struct FilesSort: Codable, Hashable, Sendable {
  enum By: String, Codable, CaseIterable, Sendable {
    case name, date, size, kind

    var label: String {
      switch self {
      case .name: "Name"
      case .date: "Date Modified"
      case .size: "Size"
      case .kind: "Kind"
      }
    }

    /// The direction labels, ascending then descending.
    var directions: (String, String) {
      switch self {
      case .name, .kind: ("A to Z", "Z to A")
      case .date: ("Oldest First", "Newest First")
      case .size: ("Smallest First", "Largest First")
      }
    }
  }

  var by: By
  var descending: Bool

  static let `default` = FilesSort(by: .date, descending: true)

  /// Picking the current column flips it; a new one starts where it is most
  /// useful (newest and largest first, A to Z).
  func picking(_ by: By) -> FilesSort {
    by == self.by ? FilesSort(by: by, descending: !descending) : FilesSort(by: by, descending: by == .date || by == .size)
  }

  /// Name and Kind keep folders first, as Finder does; Date and Size mix them.
  func arrange(_ entries: [RemoteEntry], hidden: Bool) -> [RemoteEntry] {
    let shown = hidden ? entries : entries.filter { !$0.isHidden }
    return shown.sorted { a, b in
      if by == .name || by == .kind, a.isDirectory != b.isDirectory { return a.isDirectory }
      let order: ComparisonResult = switch by {
      case .name: a.name.localizedStandardCompare(b.name)
      case .date: Self.compare(a.mtime, b.mtime)
      case .size: Self.compare(a.isDirectory ? 0 : a.size, b.isDirectory ? 0 : b.size)
      case .kind: Self.kindOrder(a, b)
      }
      if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
      return descending ? order == .orderedDescending : order == .orderedAscending
    }
  }

  private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
  }

  private static func kindOrder(_ a: RemoteEntry, _ b: RemoteEntry) -> ComparisonResult {
    let byKind = FileKind.of(a).rawValue.compare(FileKind.of(b).rawValue)
    if byKind != .orderedSame { return byKind }
    let byExt = FilePath.ext(a.name).compare(FilePath.ext(b.name))
    return byExt != .orderedSame ? byExt : a.name.localizedStandardCompare(b.name)
  }
}

/// What Files remembers per host: a browser-like history of folders, the
/// sort, hidden files, pinned folders, recently opened files and the file
/// left open (reopened over its folder at launch, as Context does).
struct BrowserState: Codable, Equatable, Sendable {
  static let maxHistory = 50
  static let maxRecents = 20

  var history: [String] = []
  var index = 0
  var sort = FilesSort.default
  var hidden = false
  var pins: [String] = []
  var recents: [String] = []
  var open: String?

  var current: String? { history.indices.contains(index) ? history[index] : nil }
  var canBack: Bool { canBack(at: index) }
  var canForward: Bool { canForward(at: index) }

  /// Back and Forward for the page at `i` in the history as they are while it
  /// is the current one, so a page sliding away or showing beneath a swipe
  /// looks as it will when it lands.
  func canBack(at i: Int) -> Bool { i > 0 && i < history.count }
  func canForward(at i: Int) -> Bool { i >= 0 && i + 1 < history.count }

  /// Opens `path` after the current folder, dropping the forward entries as
  /// a browser does. Leaving a folder closes its file.
  mutating func go(_ path: String) {
    guard current != path else { return }
    var next = Array(history.prefix(min(index + 1, history.count)))
    next.append(path)
    if next.count > Self.maxHistory { next.removeFirst(next.count - Self.maxHistory) }
    history = next
    index = next.count - 1
    open = nil
  }

  /// Moves within the history (back, forward, a pick from the hold menu).
  mutating func jump(_ to: Int) {
    guard !history.isEmpty else { return }
    let target = max(0, min(history.count - 1, to))
    if target != index { open = nil }
    index = target
  }

  /// Swaps the current folder for another (one that is gone becomes its
  /// nearest parent). When that is the folder before, the gone one just
  /// leaves the history, so Back doesn't land where he already is.
  mutating func replaceCurrent(_ path: String) {
    guard history.indices.contains(index) else {
      go(path)
      return
    }
    open = nil
    if index > 0, history[index - 1] == path {
      history.remove(at: index)
      index -= 1
    } else {
      history[index] = path
    }
  }

  mutating func togglePin(_ path: String) {
    if let i = pins.firstIndex(of: path) { pins.remove(at: i) } else { pins.append(path) }
  }

  /// A file opened: first in the recents, and the one left open.
  mutating func opened(_ path: String) {
    recents.removeAll { $0 == path }
    recents.insert(path, at: 0)
    if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    open = path
  }

  /// A path that moved or went to the Trash: its pin, recents and the open
  /// file follow it (`to` nil drops them).
  mutating func moved(_ path: String, to: String?) {
    func follow(_ p: String) -> String? {
      if p == path { return to }
      guard let rel = FilePath.relative(p, to: path) else { return p }
      return to.map { FilePath.join($0, rel) }
    }
    pins = pins.compactMap(follow)
    recents = recents.compactMap(follow)
    open = open.flatMap(follow)
  }

  init() {}

  /// Anything missing or malformed takes its default, so a file from an
  /// older build still opens where the user was.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    history = (try? c.decode([String].self, forKey: .history)) ?? []
    index = (try? c.decode(Int.self, forKey: .index)) ?? 0
    sort = (try? c.decode(FilesSort.self, forKey: .sort)) ?? .default
    hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
    pins = (try? c.decode([String].self, forKey: .pins)) ?? []
    recents = (try? c.decode([String].self, forKey: .recents)) ?? []
    open = try? c.decode(String.self, forKey: .open)
    if !history.isEmpty { index = max(0, min(history.count - 1, index)) } else { index = 0 }
  }
}

/// BrowserState saved per host as JSON in Application Support/files.
enum BrowserStateStore {
  static let directory: URL = {
    let url = AppDirectories.support.appending(path: "files", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static func url(for hostKey: String, in directory: URL = directory) -> URL {
    let safe = hostKey.map { $0.isLetter || $0.isNumber || "@.-_".contains($0) ? $0 : "_" }
    return directory.appending(path: String(safe) + ".json")
  }

  static func load(_ hostKey: String, from directory: URL = directory) -> BrowserState {
    guard let data = try? Data(contentsOf: url(for: hostKey, in: directory)),
          let state = try? JSONDecoder().decode(BrowserState.self, from: data) else { return BrowserState() }
    return state
  }

  static func save(_ state: BrowserState, for hostKey: String, in directory: URL = directory) {
    guard let data = try? JSONEncoder.pretty.encode(state) else { return }
    try? data.write(to: url(for: hostKey, in: directory), options: .atomic)
  }
}
