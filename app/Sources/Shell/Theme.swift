import UIKit

/// A terminal colour scheme. Colours are 0xRRGGBB; the core gets 0xAARRGGBB.
struct Theme: Identifiable, Hashable, Sendable {
  var name: String
  var foreground: UInt32
  var background: UInt32
  var cursor: UInt32
  /// ANSI 0-7 then bright 8-15.
  var palette: [UInt32]

  var id: String { name }

  func termTheme(boldIsBright: Bool) -> TermTheme {
    var t = TermTheme()
    t.fg = 0xFF00_0000 | foreground
    t.bg = 0xFF00_0000 | background
    t.cursor = 0xFF00_0000 | cursor
    withUnsafeMutableBytes(of: &t.palette) { raw in
      let slots = raw.bindMemory(to: UInt32.self)
      for (i, color) in palette.prefix(slots.count).enumerated() {
        slots[i] = 0xFF00_0000 | color
      }
    }
    t.bold_is_bright = boldIsBright ? 1 : 0
    return t
  }

  var backgroundColor: UIColor { UIColor(rgb: background) }
  var foregroundColor: UIColor { UIColor(rgb: foreground) }
  var isDark: Bool {
    let r = Double((background >> 16) & 0xFF), g = Double((background >> 8) & 0xFF), b = Double(background & 0xFF)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128
  }

  /// The theme called `name`: an imported one, else one Term ships, else
  /// Dusk (a name deleted or no longer shipped). Reads that one file.
  static func named(_ name: String) -> Theme {
    load(name, from: [ImportedThemes.folder, bundledFolder]) ?? dusk
  }

  /// Term's own Dusk: the default theme and the fixed app palette's source.
  static let dusk: Theme = {
    guard let dusk = load("Dusk", from: [bundledFolder]) else { preconditionFailure("Themes/Dusk.ghostty is missing or unreadable") }
    return dusk
  }()

  /// Term's own themes, first in the catalog in this order; the first is the
  /// default for anyone who never picked one.
  static let own = ["Dusk", "Term"]

  /// Term's own themes and the iTerm2-Color-Schemes catalog, in Ghostty's
  /// format (app/Resources/Themes).
  static let bundledFolder: URL = {
    guard let folder = Bundle.main.url(forResource: "Themes", withExtension: nil) else {
      preconditionFailure("app/Resources/Themes is not in the app bundle")
    }
    return folder
  }()

  /// Every theme Term ships, Term's own first, then by name. About 800
  /// files, so read when first asked for (the All page), never at launch.
  static let bundled: [Theme] = {
    let themes = catalog(in: bundledFolder)
    precondition(themes.prefix(own.count).map(\.name) == own, "Themes/Dusk.ghostty or Term.ghostty is missing or unreadable")
    return themes
  }()

  private static let bundledNames = fileNames(in: bundledFolder)

  /// The name of every theme there is, shipped and imported, without reading them.
  static var names: [String] { bundledNames + fileNames(in: ImportedThemes.folder) }

  /// Every readable `.ghostty` file in `folder`, Term's own first, then by name.
  static func catalog(in folder: URL) -> [Theme] {
    let themes = fileNames(in: folder).compactMap { load($0, from: [folder]) }
    let rank = { (name: String) in own.firstIndex(of: name) ?? own.count }
    return themes.sorted { a, b in
      rank(a.name) != rank(b.name) ? rank(a.name) < rank(b.name) : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }

  private static func fileNames(in folder: URL) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "ghostty" }.map { $0.deletingPathExtension().lastPathComponent }
  }

  /// The first folder's readable `name.ghostty`; nil for a name that is not a plain file name.
  private static func load(_ name: String, from folders: [URL]) -> Theme? {
    guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
    for folder in folders {
      if let text = try? String(contentsOf: folder.appending(path: name + ".ghostty"), encoding: .utf8) {
        return Theme(name: name, ghostty: text)
      }
    }
    return nil
  }

  /// The themes whose names hold every word of `query`, ignoring case,
  /// accents, spaces and punctuation ("tokyo night" finds "TokyoNight Storm",
  /// "rosé" finds "Rose Pine"); names that start with the query come first.
  static func search(_ themes: [Theme], _ query: String) -> [Theme] {
    let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { folded(String($0)) }
    guard !words.isEmpty else { return themes }
    let found = themes.filter { theme in
      let name = folded(theme.name)
      return words.allSatisfy(name.contains)
    }
    let start = words.joined()
    return found.filter { folded($0.name).hasPrefix(start) } + found.filter { !folded($0.name).hasPrefix(start) }
  }

  private static func folded(_ s: String) -> String {
    String(String.UnicodeScalarView(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
  }
}

/// Themes the user imported (Ghostty theme files and `.itermcolors`), kept
/// in Ghostty's format under Application Support/Themes.
enum ImportedThemes {
  static let folder = URL.applicationSupportDirectory.appending(path: "Themes", directoryHint: .isDirectory)

  enum Failure: LocalizedError, Equatable {
    case notATheme(file: String)

    var errorDescription: String? {
      switch self {
      case .notATheme(let file): "\(file) isn't a Ghostty theme or an .itermcolors file."
      }
    }
  }

  static func all(in folder: URL = folder) -> [Theme] { Theme.catalog(in: folder) }

  /// Reads a theme file and saves it under its file's name, made unique
  /// against `taken` (every theme's name); returns the theme saved.
  static func add(_ data: Data, fileName: String, taken: [String], in folder: URL = folder) throws -> Theme {
    var theme = try Theme(file: data, named: fileName)
    theme.name = uniqueName(theme.name, taken: Set(taken))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(theme.ghosttyText.utf8).write(to: folder.appending(path: theme.name + ".ghostty"), options: .atomic)
    return theme
  }

  static func delete(_ name: String, in folder: URL = folder) throws {
    try FileManager.default.removeItem(at: folder.appending(path: name + ".ghostty"))
  }

  /// `name` made a plain file name, then "name 2", "name 3", … until no theme has it.
  static func uniqueName(_ name: String, taken: Set<String>) -> String {
    var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasPrefix(".") { base.removeFirst() }
    if base.isEmpty { base = "Imported" }
    var candidate = base
    var n = 2
    while taken.contains(candidate) {
      candidate = "\(base) \(n)"
      n += 1
    }
    return candidate
  }
}

extension Theme {
  /// Reads a Ghostty theme: `palette = N=#rrggbb`, `background`,
  /// `foreground`, `cursor-color` (the foreground when absent); other keys
  /// and `#` comments are skipped. Nil unless background, foreground and
  /// palette 0-15 are all there.
  init?(name: String, ghostty text: String) {
    guard let c = Colors(ghostty: text), let fg = c.foreground, let bg = c.background, !c.palette.contains(nil) else { return nil }
    self.init(name: name, foreground: fg, background: bg, cursor: c.cursor ?? fg, palette: c.palette.compactMap { $0 })
  }

  /// Reads a theme file someone imports: an `.itermcolors` property list or
  /// a Ghostty theme. Colours the file leaves out are Ghostty's defaults, as
  /// Ghostty would show that file; the name is the file's, less a theme extension.
  init(file data: Data, named fileName: String) throws {
    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    let colors = plist.flatMap(Colors.init(itermcolors:)) ?? String(data: data, encoding: .utf8).flatMap(Colors.init(ghostty:))
    guard let colors, !colors.isEmpty else { throw ImportedThemes.Failure.notATheme(file: fileName) }
    let ext = (fileName as NSString).pathExtension.lowercased()
    let name = ["itermcolors", "ghostty", "conf", "theme", "txt"].contains(ext) ? (fileName as NSString).deletingPathExtension : fileName
    let fg = colors.foreground ?? Colors.ghosttyForeground
    self.init(name: name, foreground: fg, background: colors.background ?? Colors.ghosttyBackground, cursor: colors.cursor ?? fg,
              palette: zip(colors.palette, Colors.ghosttyPalette).map { $0 ?? $1 })
  }

  /// The theme as a Ghostty theme file.
  var ghosttyText: String {
    let hex = { (rgb: UInt32) in String(format: "#%06x", rgb) }
    return palette.enumerated().map { "palette = \($0)=\(hex($1))\n" }.joined()
      + "background = \(hex(background))\nforeground = \(hex(foreground))\ncursor-color = \(hex(cursor))\n"
  }

  /// The colours a theme file sets; nil where it sets none.
  private struct Colors {
    var foreground: UInt32?, background: UInt32?, cursor: UInt32?
    var palette = [UInt32?](repeating: nil, count: 16)

    var isEmpty: Bool { foreground == nil && background == nil && cursor == nil && !palette.contains { $0 != nil } }

    /// Ghostty's own colours, for what a file leaves out (src/config/Config.zig, src/terminal/color.zig).
    static let ghosttyForeground: UInt32 = 0xFFFFFF
    static let ghosttyBackground: UInt32 = 0x282C34
    static let ghosttyPalette: [UInt32] = [
      0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
      0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
    ]

    /// Nil when a colour is malformed: a bad value rejects the whole file.
    init?(ghostty text: String) {
      for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "background", "foreground", "cursor-color":
          guard let c = Self.hex(value) else { return nil }
          if key == "background" { background = c } else if key == "foreground" { foreground = c } else { cursor = c }
        case "palette":
          guard let sep = value.firstIndex(of: "="), let i = Int(value[..<sep].trimmingCharacters(in: .whitespaces)),
                palette.indices.contains(i) else { continue }
          guard let c = Self.hex(value[value.index(after: sep)...].trimmingCharacters(in: .whitespaces)) else { return nil }
          palette[i] = c
        default: continue
        }
      }
    }

    /// iTerm's keys: "Ansi N Color", "Background Color", "Foreground Color",
    /// "Cursor Color", each red/green/blue components 0-1 in its "Color Space".
    init?(itermcolors plist: [String: Any]) {
      let color = { (key: String) in (plist[key] as? [String: Any]).flatMap(Self.rgb) }
      foreground = color("Foreground Color")
      background = color("Background Color")
      cursor = color("Cursor Color")
      palette = (0..<16).map { color("Ansi \($0) Color") }
      if isEmpty { return nil }
    }

    /// "#rrggbb" or "rrggbb".
    private static func hex(_ s: String) -> UInt32? {
      let digits = s.hasPrefix("#") ? s.dropFirst() : Substring(s)
      guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
      return UInt32(digits, radix: 16)
    }

    /// An iTerm colour as sRGB: "sRGB" (and no colour space, as older files
    /// have) is taken as is; "P3" and "Calibrated" (generic RGB) are converted.
    private static func rgb(_ c: [String: Any]) -> UInt32? {
      guard let r = c["Red Component"] as? Double, let g = c["Green Component"] as? Double,
            let b = c["Blue Component"] as? Double else { return nil }
      var parts = [r, g, b]
      let source: CFString? = switch c["Color Space"] as? String {
      case "P3": CGColorSpace.displayP3
      case "Calibrated": "kCGColorSpaceGenericRGB" as CFString  // CGColorSpace.genericRGB, which Swift hides
      default: nil
      }
      if let source, let from = CGColorSpace(name: source), let to = CGColorSpace(name: CGColorSpace.sRGB),
         let converted = CGColor(colorSpace: from, components: parts.map { CGFloat($0) } + [1])?
           .converted(to: to, intent: .defaultIntent, options: nil)?.components {
        parts = converted.prefix(3).map(Double.init)
      }
      return parts.reduce(0) { $0 << 8 | UInt32((min(max($1, 0), 1) * 255).rounded()) }
    }
  }
}

extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
              blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}
