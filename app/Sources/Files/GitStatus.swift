import Foundation

/// A repository's working-tree status for row badges and the branch in the
/// bar, from one exec: the toplevel, then `git status --porcelain=v1 -z -b`.
struct GitStatus: Equatable, Sendable {
  enum Change: Int, Comparable, Sendable {
    case deleted, untracked, added, renamed, modified, conflicted

    static func < (a: Change, b: Change) -> Bool { a.rawValue < b.rawValue }

    /// Porcelain XY code.
    init?(x: Character, y: Character) {
      switch (x, y) {
      case ("?", "?"): self = .untracked
      case ("!", "!"): return nil
      case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): self = .conflicted
      case ("R", _), ("C", _): self = .renamed
      case ("A", _): self = .added
      case ("D", _), (_, "D"): self = .deleted
      default: self = .modified
      }
    }

    var letter: String {
      switch self {
      case .deleted: "D"
      case .untracked: "U"
      case .added: "A"
      case .renamed: "R"
      case .modified: "M"
      case .conflicted: "!"
      }
    }
  }

  var root: String
  var branch: String
  /// By path relative to the root; an untracked folder is "dir/".
  var files: [String: Change] = [:]
  /// The strongest change under each folder (relative path, no slash).
  var folders: [String: Change] = [:]

  static func command(_ dir: String) -> String {
    let q = Command.shellQuote(dir)
    return "cd \(q) 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && git status --porcelain=v1 -z -b 2>/dev/null"
  }

  /// nil when the folder is not in a repository (empty output).
  static func parse(_ data: Data) -> GitStatus? {
    guard let newline = data.firstIndex(of: 0x0A) else { return nil }
    let root = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
    guard root.hasPrefix("/") else { return nil }
    var status = GitStatus(root: root, branch: "")
    let fields = data[data.index(after: newline)...].split(separator: 0, omittingEmptySubsequences: true)
    var i = 0
    while i < fields.count {
      let field = String(decoding: fields[i], as: UTF8.self)
      i += 1
      if field.hasPrefix("## ") {
        status.branch = branch(fromHeader: String(field.dropFirst(3)))
        continue
      }
      let chars = Array(field.prefix(3))
      guard chars.count == 3, chars[2] == " " else { continue }
      if chars[0] == "R" || chars[0] == "C" { i += 1 }  // the original path follows
      guard let change = Change(x: chars[0], y: chars[1]) else { continue }
      let path = String(field.dropFirst(3))
      status.files[path] = change
      var dir = path.hasSuffix("/") ? String(path.dropLast()) : parentRel(path)
      while !dir.isEmpty {
        status.folders[dir] = max(status.folders[dir] ?? change, change)
        dir = parentRel(dir)
      }
    }
    return status
  }

  /// "main...origin/main [ahead 1]" → "main"; "No commits yet on main" → "main"; "HEAD (no branch)" → "HEAD".
  static func branch(fromHeader header: String) -> String {
    for prefix in ["No commits yet on ", "Initial commit on "] where header.hasPrefix(prefix) {
      return String(header.dropFirst(prefix.count))
    }
    if header.hasPrefix("HEAD (no branch)") { return "HEAD" }
    let name = header.range(of: "...").map { String(header[..<$0.lowerBound]) } ?? header
    return name.split(separator: " ").first.map(String.init) ?? name
  }

  /// The badge for an absolute path in this repository.
  func change(at path: String, isDirectory: Bool) -> Change? {
    guard let rel = FilePath.relative(path, to: root), !rel.isEmpty else { return nil }
    if isDirectory, let change = folders[rel] { return change }
    if !isDirectory, let change = files[rel] { return change }
    // Inside an untracked folder, everything is untracked.
    var dir = Self.parentRel(rel)
    while !dir.isEmpty {
      if files[dir + "/"] == .untracked { return .untracked }
      dir = Self.parentRel(dir)
    }
    return nil
  }

  /// "a/b/c" → "a/b", "a" → "".
  private static func parentRel(_ rel: String) -> String {
    rel.lastIndex(of: "/").map { String(rel[..<$0]) } ?? ""
  }
}
