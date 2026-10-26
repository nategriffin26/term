import Runestone
import UIKit
import TreeSitterBashRunestone
import TreeSitterCRunestone
import TreeSitterCPPRunestone
import TreeSitterCSSRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterLuaRunestone
import TreeSitterMarkdownRunestone
import TreeSitterMarkdownInlineRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSCSSRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

/// The editor in the terminal's colours: its background and foreground, and
/// syntax drawn from its ANSI palette (bright colours on dark themes, normal
/// ones on light), so code looks like it does in the terminal.
final class EditorTheme: Runestone.Theme {
  let font: UIFont
  let textColor: UIColor
  let gutterBackgroundColor: UIColor
  let gutterHairlineColor: UIColor
  let lineNumberColor: UIColor
  let lineNumberFont: UIFont
  let selectedLineBackgroundColor: UIColor
  let selectedLinesLineNumberColor: UIColor
  let selectedLinesGutterBackgroundColor: UIColor
  let invisibleCharactersColor: UIColor
  let pageGuideHairlineColor: UIColor
  let pageGuideBackgroundColor: UIColor
  let markedTextBackgroundColor: UIColor
  let background: UIColor
  private let colors: [String: UIColor]
  private let bold: UIFont
  private let italic: UIFont

  init(theme: Theme, font: UIFont) {
    self.font = font
    bold = font.adding(.traitBold)
    italic = font.adding(.traitItalic)
    let bg = UIColor(rgb: theme.background)
    let fg = UIColor(rgb: theme.foreground)
    background = bg
    textColor = fg
    gutterBackgroundColor = bg
    gutterHairlineColor = .clear
    lineNumberColor = fg.mixed(with: bg, 0.62)
    lineNumberFont = font.withSize(max(9, font.pointSize - 2))
    selectedLineBackgroundColor = fg.withAlphaComponent(0.05)
    selectedLinesLineNumberColor = fg.mixed(with: bg, 0.2)
    selectedLinesGutterBackgroundColor = bg
    invisibleCharactersColor = fg.mixed(with: bg, 0.75)
    pageGuideHairlineColor = fg.withAlphaComponent(0.08)
    pageGuideBackgroundColor = fg.withAlphaComponent(0.03)
    markedTextBackgroundColor = fg.withAlphaComponent(0.15)

    let offset = theme.isDark ? 8 : 0
    func ansi(_ i: Int) -> UIColor { UIColor(rgb: theme.palette[min(i + offset, theme.palette.count - 1)]) }
    let comment = fg.mixed(with: bg, 0.48)
    let quiet = fg.mixed(with: bg, 0.22)
    colors = [
      "comment": comment,
      "keyword": ansi(5), "conditional": ansi(5), "repeat": ansi(5), "include": ansi(5), "import": ansi(5),
      "exception": ansi(5), "storageclass": ansi(5), "type.qualifier": ansi(5),
      "string": ansi(2), "character": ansi(2), "text.literal": ansi(2),
      "string.escape": ansi(6), "escape": ansi(6), "string.special": ansi(6), "string.regex": ansi(6),
      "number": ansi(3), "float": ansi(3), "boolean": ansi(3), "constant": ansi(3), "constant.builtin": ansi(3),
      "function": ansi(4), "method": ansi(4), "function.method": ansi(4), "function.call": ansi(4),
      "function.builtin": ansi(4), "function.macro": ansi(4), "constructor": ansi(6), "text.title": ansi(4),
      "type": ansi(6), "type.builtin": ansi(6), "namespace": ansi(6), "module": ansi(6), "label": ansi(6),
      "attribute": ansi(3), "tag": ansi(1), "tag.attribute": ansi(3),
      "variable.builtin": ansi(1), "text.uri": ansi(6), "text.reference": ansi(6),
      "operator": quiet, "punctuation": quiet, "punctuation.special": ansi(5), "embedded": ansi(5),
      "property": fg, "field": fg, "variable": fg, "parameter": fg, "variable.parameter": fg,
      "error": ansi(1),
    ]
  }

  /// "function.method.builtin" falls back to "function.method", then "function".
  func textColor(for highlightName: String) -> UIColor? {
    var name = Substring(highlightName)
    while true {
      if let color = colors[String(name)] { return color }
      guard let dot = name.lastIndex(of: ".") else { return nil }
      name = name[..<dot]
    }
  }

  func font(for highlightName: String) -> UIFont? {
    switch highlightName {
    case "comment", "text.emphasis": italic
    case "text.title", "text.strong": bold
    default: nil
    }
  }

  @available(iOS 16, *)
  func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
    switch style {
    case .found: HighlightedRange(range: foundTextRange, color: Chrome.UI.accent.withAlphaComponent(0.22))
    case .highlighted: HighlightedRange(range: foundTextRange, color: Chrome.UI.accent.withAlphaComponent(0.55))
    default: nil
    }
  }
}

/// Tree-sitter grammars by language and by the names injections use
/// (Markdown code fences, `<script>` in HTML). Built once, on first use.
final class EditorLanguages: TreeSitterLanguageProvider, @unchecked Sendable {
  static let shared = EditorLanguages()

  private let lock = NSLock()
  private var cache: [String: TreeSitterLanguage] = [:]

  func language(_ language: SourceLanguage) -> TreeSitterLanguage? {
    treeSitterLanguage(named: language.rawValue)
  }

  func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
    let name = Self.aliases[languageName.lowercased()] ?? languageName.lowercased()
    lock.lock()
    defer { lock.unlock() }
    if let hit = cache[name] { return hit }
    let made: TreeSitterLanguage? = switch name {
    case "bash": .bash
    case "c": .c
    case "cpp": .cpp
    case "css": .css
    case "go": .go
    case "html": .html
    case "java": .java
    case "javascript": .jsx
    case "json": .json
    case "lua": .lua
    case "markdown": .markdown
    case "markdown_inline": .markdownInline
    case "python": .python
    case "ruby": .ruby
    case "rust": .rust
    case "scss": .scss
    case "sql": .sql
    case "swift": .swift
    case "toml": .toml
    case "tsx": .tsx
    case "typescript": .typeScript
    case "yaml": .yaml
    default: nil
    }
    cache[name] = made
    return made
  }

  private static let aliases: [String: String] = [
    "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "c++": "cpp", "cc": "cpp", "h": "c",
    "golang": "go", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
    "ts": "typescript", "jsonc": "json", "json5": "json", "md": "markdown", "py": "python", "python3": "python",
    "rb": "ruby", "rs": "rust", "yml": "yaml", "xml": "html", "svg": "html",
  ]
}

extension UIColor {
  /// `self` moved `amount` (0...1) of the way to `other`.
  func mixed(with other: UIColor, _ amount: CGFloat) -> UIColor {
    var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                   blue: b1 + (b2 - b1) * amount, alpha: a1 + (a2 - a1) * amount)
  }
}

extension UIFont {
  func adding(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
    fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)).map { UIFont(descriptor: $0, size: pointSize) } ?? self
  }
}
