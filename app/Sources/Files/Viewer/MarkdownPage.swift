import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Markdown as an HTML page in the app theme's colours, rendered by cmark-gfm (GitHub's
/// renderer): tables, task lists, strikethrough, autolinks, footnotes, raw
/// HTML with GitHub's tag filter (the page runs no JavaScript either way),
/// heading anchors for in-page links, and YAML front matter as a table.
enum MarkdownPage {
  static func html(_ markdown: String, theme: AppTheme) -> String {
    let (front, body) = splitFrontMatter(markdown)
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>\(css(theme))</style></head><body>
      \(front.map(frontMatterHTML) ?? "")\(render(body))</body></html>
      """
  }

  /// cmark-gfm's HTML for `markdown`, with an id on every heading.
  static func render(_ markdown: String) -> String {
    cmark_gfm_core_extensions_ensure_registered()
    let options = CMARK_OPT_UNSAFE | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_FOOTNOTES
    guard let parser = cmark_parser_new(options) else { return "" }
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
      if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
    }
    cmark_parser_feed(parser, markdown, markdown.utf8.count)
    guard let document = cmark_parser_finish(parser) else { return "" }
    defer { cmark_node_free(document) }
    anchorHeadings(document)
    guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
    defer { free(html) }
    return String(cString: html)
  }

  /// GitHub's heading ids: lowercased, punctuation dropped, spaces to
  /// hyphens; a repeated id gets -1, -2.
  static func slug(_ heading: String, taken: inout [String: Int]) -> String {
    var base = ""
    for ch in heading.lowercased() {
      if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { base.append(ch) }
      else if ch == " " { base.append("-") }
    }
    let count = taken[base, default: 0]
    taken[base] = count + 1
    return count == 0 ? base : "\(base)-\(count)"
  }

  /// "---" … "---" at the very top, as (front matter, the rest).
  static func splitFrontMatter(_ text: String) -> (front: String?, body: String) {
    let lines = text.splitLines(omittingEmpty: false)
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
      return (nil, text)
    }
    let front = lines[1..<end].joined(separator: "\n")
    let body = lines[(end + 1)...].joined(separator: "\n")
    return (front, body)
  }

  /// Top-level `key: value` lines as a key/value table; anything nested as
  /// its source.
  static func frontMatterHTML(_ yaml: String) -> String {
    let lines = yaml.splitLines(omittingEmpty: true)
    var rows: [(String, String)] = []
    for line in lines {
      guard let colon = line.firstIndex(of: ":"), line.first.map({ !$0.isWhitespace && $0 != "-" && $0 != "#" }) == true else {
        return "<pre class=\"front\">\(escape(yaml))</pre>"
      }
      let key = line[..<colon]
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !key.contains(" "), !value.isEmpty else { return "<pre class=\"front\">\(escape(yaml))</pre>" }
      rows.append((String(key), unquote(value)))
    }
    let body = rows.map { "<tr><th>\(escape($0.0))</th><td>\(escape($0.1))</td></tr>" }.joined()
    return "<table class=\"front\">\(body)</table>"
  }

  static func escape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for ch in text {
      switch ch {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      default: out.append(ch)
      }
    }
    return out
  }

  private static func unquote(_ value: String) -> String {
    if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
      return String(value.dropFirst().dropLast())
    }
    return value
  }

  /// Puts `<a id="slug">` first in every heading (raw inline HTML; the
  /// renderer is in unsafe mode).
  private static func anchorHeadings(_ document: UnsafeMutablePointer<cmark_node>) {
    var taken: [String: Int] = [:]
    guard let iterator = cmark_iter_new(document) else { return }
    defer { cmark_iter_free(iterator) }
    var headings: [UnsafeMutablePointer<cmark_node>] = []
    while true {
      let event = cmark_iter_next(iterator)
      if event == CMARK_EVENT_DONE { break }
      if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_HEADING {
        headings.append(node)
      }
    }
    for heading in headings {
      let id = slug(plainText(heading), taken: &taken)
      guard let anchor = cmark_node_new(CMARK_NODE_HTML_INLINE) else { continue }
      cmark_node_set_literal(anchor, "<a id=\"\(escape(id))\"></a>")
      cmark_node_prepend_child(heading, anchor)
    }
  }

  private static func plainText(_ node: UnsafeMutablePointer<cmark_node>) -> String {
    var text = ""
    guard let iterator = cmark_iter_new(node) else { return text }
    defer { cmark_iter_free(iterator) }
    while true {
      let event = cmark_iter_next(iterator)
      if event == CMARK_EVENT_DONE { break }
      guard event == CMARK_EVENT_ENTER, let child = cmark_iter_get_node(iterator) else { continue }
      let type = cmark_node_get_type(child)
      if type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE, let literal = cmark_node_get_literal(child) {
        text += String(cString: literal)
      }
    }
    return text
  }

  /// A tone as CSS: #rrggbb, or rgba() when it is see-through.
  static func css(_ tone: AppTheme.Tone) -> String {
    let r = (tone.rgb >> 16) & 0xFF, g = (tone.rgb >> 8) & 0xFF, b = tone.rgb & 0xFF
    if tone.opacity >= 1 { return String(format: "#%06x", tone.rgb & 0xFFFFFF) }
    return "rgba(\(r), \(g), \(b), \(String(format: "%.3g", tone.opacity)))"
  }

  /// The page in the app's colours: the viewer's ground, prose in fg2 with
  /// headings in fg, hairlines and washes in the text colour, links
  /// underlined rather than coloured (the accent marks only what needs him).
  /// SF Pro for prose, SF Mono for code.
  static func css(_ theme: AppTheme) -> String {
    let ground = css(theme.raised), fg = css(theme.fg), fg2 = css(theme.fg2), muted = css(theme.muted)
    let fill = css(theme.fill), line = css(theme.line), line2 = css(theme.line2)
    return """
      :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
      html { -webkit-text-size-adjust: 100%; }
      body { margin: 0; padding: 12px 16px 56px; background: \(ground); color: \(fg2); font: 15px/1.6 -apple-system, sans-serif;
        letter-spacing: -0.005em; overflow-wrap: break-word; -webkit-font-smoothing: antialiased; }
      body > :first-child { margin-top: 0; }
      h1, h2, h3, h4, h5, h6 { color: \(fg); font-weight: 600; line-height: 1.3; margin: 1.5em 0 0.55em; letter-spacing: -0.01em; }
      h1 { font-size: 22px; } h2 { font-size: 18px; } h3 { font-size: 16px; } h4, h5, h6 { font-size: 15px; }
      h1, h2 { padding-bottom: 0.35em; border-bottom: 1px solid \(line); }
      p, ul, ol, blockquote, pre, table, details { margin: 0 0 16px; }
      a { color: \(fg); text-decoration: underline; text-decoration-color: \(line2); text-decoration-thickness: 1px; text-underline-offset: 3px; }
      strong { color: \(fg); font-weight: 600; }
      del { color: \(muted); }
      code { font: 13px/1.5 ui-monospace, monospace; background: \(fill); border-radius: 6px; padding: 0.1em 0.35em; color: \(fg); }
      pre { background: \(fill); border-radius: 16px; padding: 12px 16px; overflow-x: auto; }
      pre code { background: none; padding: 0; border-radius: 0; font-size: 13px; color: \(fg2); }
      blockquote { margin-left: 0; padding-left: 12px; border-left: 2px solid \(line2); color: \(muted); }
      hr { border: 0; border-top: 1px solid \(line2); margin: 24px 0; }
      img { max-width: 100%; border-radius: 6px; }
      ul, ol { padding-left: 24px; }
      li + li, li > ul, li > ol { margin-top: 4px; }
      li > ul, li > ol { margin-bottom: 0; }
      li:has(> input[type=checkbox]) { list-style: none; }
      input[type=checkbox] { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; margin: 0 8px 0 -22px;
        vertical-align: -2px; border: 1px solid \(line2); border-radius: 4px; }
      input[type=checkbox]:checked { background: \(fg2); border-color: \(fg2); box-shadow: inset 0 0 0 3px \(ground); }
      table { border-collapse: collapse; display: block; overflow-x: auto; font-size: 13px; }
      th, td { border-bottom: 1px solid \(line); padding: 8px 16px 8px 0; text-align: left; vertical-align: top; }
      th { color: \(fg); font-weight: 600; border-bottom-color: \(line2); }
      table.front { font: 13px/1.5 ui-monospace, monospace; margin-bottom: 24px; }
      table.front th { color: \(muted); font-weight: 400; border-bottom-color: \(line); white-space: nowrap; }
      table.front td { color: \(fg2); }
      pre.front { font-size: 13px; color: \(muted); }
      .footnotes { font-size: 13px; color: \(muted); }
      summary { color: \(fg); }
      """
  }
}
