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

  static func named(_ name: String) -> Theme {
    all.first { $0.name == name } ?? all[0]
  }

  /// Term's own themes and a curated set from iTerm2-Color-Schemes, in
  /// Ghostty's format (app/Resources/Themes); "Term" first, then by name.
  static let all: [Theme] = {
    guard let folder = Bundle.main.url(forResource: "Themes", withExtension: nil) else {
      preconditionFailure("app/Resources/Themes is not in the app bundle")
    }
    let themes = catalog(in: folder)
    precondition(themes.first?.name == "Term", "Themes/Term.ghostty is missing or unreadable")
    return themes
  }()

  /// Every readable `.ghostty` file in `folder`, "Term" first, then by name.
  static func catalog(in folder: URL) -> [Theme] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let themes = files.filter { $0.pathExtension == "ghostty" }.compactMap { url -> Theme? in
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      return Theme(name: url.deletingPathExtension().lastPathComponent, ghostty: text)
    }
    return themes.sorted { a, b in
      a.name == "Term" || (b.name != "Term" && a.name.localizedStandardCompare(b.name) == .orderedAscending)
    }
  }
}

extension Theme {
  /// Reads a Ghostty theme: `palette = N=#rrggbb`, `background`,
  /// `foreground`, `cursor-color` (the foreground when absent); other keys
  /// and `#` comments are skipped. Nil unless background, foreground and
  /// palette 0-15 are all there.
  init?(name: String, ghostty text: String) {
    var fg: UInt32?, bg: UInt32?, cursor: UInt32?
    var palette = [UInt32?](repeating: nil, count: 16)
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      switch key {
      case "background": bg = Self.hex(value)
      case "foreground": fg = Self.hex(value)
      case "cursor-color": cursor = Self.hex(value)
      case "palette":
        guard let sep = value.firstIndex(of: "="), let i = Int(value[..<sep].trimmingCharacters(in: .whitespaces)),
              palette.indices.contains(i) else { continue }
        palette[i] = Self.hex(value[value.index(after: sep)...].trimmingCharacters(in: .whitespaces))
      default: continue
      }
    }
    let colors = palette.compactMap { $0 }
    guard let fg, let bg, colors.count == 16 else { return nil }
    self.init(name: name, foreground: fg, background: bg, cursor: cursor ?? fg, palette: colors)
  }

  /// "#rrggbb" or "rrggbb".
  private static func hex(_ s: String) -> UInt32? {
    let digits = s.hasPrefix("#") ? s.dropFirst() : Substring(s)
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
    return UInt32(digits, radix: 16)
  }
}

extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
              blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}
