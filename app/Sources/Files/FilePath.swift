import Foundation

/// POSIX path arithmetic on the host's absolute paths.
enum FilePath {
  /// "/a/b" → "/a", "/a" → "/", "/" → "/".
  static func parent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[..<slash])
  }

  /// "/a/b" → "b", "/" → "/".
  static func name(_ path: String) -> String {
    guard path != "/", let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  static func join(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
  }

  /// Folders above `path`, nearest first, ending at "/".
  static func ancestors(_ path: String) -> [String] {
    var out: [String] = []
    var p = path
    while p != "/" {
      p = parent(p)
      out.append(p)
    }
    return out
  }

  /// `/Users/me/Projects` → `~/Projects` under `home`.
  static func tilde(_ path: String, home: String?) -> String {
    guard let home, home != "/" else { return path }
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  /// `path` relative to `root` ("" for root itself), nil when outside it.
  static func relative(_ path: String, to root: String) -> String? {
    if path == root { return "" }
    let prefix = root == "/" ? "/" : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
  }

  /// Lowercased extension without the dot; "" for none and for dotfiles.
  static func ext(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[name.index(after: dot)...].lowercased()
  }
}

/// Finder's way out of a name clash: "notes.txt" → "notes 2.txt", "notes 2.txt" → "notes 3.txt".
enum UniqueName {
  private static let doubleExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"]

  static func make(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let (stem, ext) = split(name)
    var base = stem
    var n = 2
    if let space = stem.lastIndex(of: " "), space != stem.startIndex,
       case let digits = stem[stem.index(after: space)...], !digits.isEmpty,
       digits.allSatisfy({ $0.isASCII && $0.isNumber }), let k = Int(digits), k >= 2 {
      base = String(stem[..<space])
      n = k + 1
    }
    while taken.contains("\(base) \(n)\(ext)") { n += 1 }
    return "\(base) \(n)\(ext)"
  }

  /// "a.tar.gz" → ("a", ".tar.gz"), ".zshrc" → (".zshrc", ""), "Makefile" → ("Makefile", "").
  static func split(_ name: String) -> (stem: String, ext: String) {
    let lower = name.lowercased()
    if let double = doubleExtensions.first(where: { lower.hasSuffix($0) && lower.count > $0.count }) {
      return (String(name.dropLast(double.count)), String(name.suffix(double.count)))
    }
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
    return (String(name[..<dot]), String(name[dot...]))
  }
}

/// What a file is, from its name: picks the glyph, the Kind sort and what
/// gets a thumbnail.
enum FileKind: String, CaseIterable {
  case folder, image, video, audio, pdf, markdown, code, json, text, html, archive, other

  static func of(_ entry: RemoteEntry) -> FileKind {
    entry.isDirectory ? .folder : of(name: entry.name)
  }

  static func of(name: String) -> FileKind {
    let ext = FilePath.ext(name)
    if let kind = byExtension[ext] { return kind }
    switch name {
    case "Makefile", "Dockerfile", "Gemfile", "Rakefile", "Podfile", "Brewfile", "Justfile", "justfile": return .code
    case "LICENSE", "README", "CHANGELOG", "AUTHORS": return .text
    default: return name.hasPrefix(".") ? .text : .other
    }
  }

  private static let byExtension: [String: FileKind] = {
    var map: [String: FileKind] = [:]
    let groups: [(FileKind, [String])] = [
      (.image, ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "ico", "svg", "avif"]),
      (.video, ["mov", "mp4", "m4v", "avi", "mkv", "webm"]),
      (.audio, ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus"]),
      (.pdf, ["pdf"]),
      (.markdown, ["md", "markdown", "mdx"]),
      (.json, ["json", "jsonl", "ndjson"]),
      (.html, ["html", "htm"]),
      (.archive, ["zip", "gz", "tgz", "tar", "bz2", "xz", "zst", "7z", "rar", "dmg"]),
      (.text, ["txt", "log", "csv", "tsv", "ini", "conf", "cfg", "env", "lock"]),
      (.code, ["swift", "rs", "c", "h", "m", "mm", "cc", "cpp", "hpp", "go", "py", "rb", "js", "jsx", "ts", "tsx",
               "mjs", "cjs", "java", "kt", "kts", "scala", "cs", "php", "pl", "lua", "sh", "bash", "zsh", "fish",
               "css", "scss", "sass", "less", "xml", "yml", "yaml", "toml", "sql", "graphql", "proto", "zig",
               "nix", "vim", "el", "ex", "exs", "erl", "hs", "ml", "dart", "r", "jl", "tf", "metal", "plist",
               "vue", "svelte", "astro", "gradle", "cmake", "mk", "patch", "diff"]),
    ]
    for (kind, exts) in groups {
      for ext in exts { map[ext] = kind }
    }
    return map
  }()

  var symbol: String {
    switch self {
    case .folder: "folder.fill"
    case .image: "photo"
    case .video: "film"
    case .audio: "waveform"
    case .pdf: "doc.richtext"
    case .markdown: "doc.plaintext"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .json: "curlybraces"
    case .text: "doc.text"
    case .html: "globe"
    case .archive: "archivebox"
    case .other: "doc"
    }
  }

  /// zip, tar.gz and tgz extract in place.
  static func isExtractable(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
  }
}

/// How rows write dates and sizes: "9:41 AM", "Yesterday", "Tue", "Oct 4", "2025"; "785 KB", "11.7 MB".
enum FileFormat {
  static func size(_ bytes: UInt64) -> String {
    if bytes == 1 { return "1 byte" }
    if bytes < 1000 { return "\(bytes) bytes" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes) / 1000
    var i = 0
    while value >= 999.95, i < units.count - 1 {
      value /= 1000
      i += 1
    }
    let number = value >= 99.95 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    return "\(number) \(units[i])"
  }

  static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    if days <= 0 { return date.formatted(style.hour().minute()) }
    if days == 1 { return "Yesterday" }
    if days < 7 { return date.formatted(style.weekday(.abbreviated)) }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      return date.formatted(style.month(.abbreviated).day())
    }
    return String(calendar.component(.year, from: date))
  }

  /// "drwxr-xr-x".
  static func permissions(_ mode: UInt32) -> String {
    let type: Character = switch mode & 0o170000 {
    case 0o040000: "d"
    case 0o120000: "l"
    default: "-"
    }
    let bits: [(UInt32, Character)] = [
      (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
      (0o004, "r"), (0o002, "w"), (0o001, "x"),
    ]
    return String(type) + String(bits.map { mode & $0.0 != 0 ? $0.1 : "-" })
  }
}
