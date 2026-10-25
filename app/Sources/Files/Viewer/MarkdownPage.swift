import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Markdown as a Helm-styled HTML page, rendered by cmark-gfm (GitHub's
/// renderer): tables, task lists, strikethrough, autolinks, footnotes, raw
/// HTML with GitHub's tag filter (the page runs no JavaScript either way),
/// heading anchors for in-page links, and YAML front matter as a table.
enum MarkdownPage {
  static func html(_ markdown: String) -> String {
    let (front, body) = splitFrontMatter(markdown)
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>\(css)</style></head><body>
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

  /// Helm, dark: Geist for prose, Geist Mono for code, hairlines, the
  /// accent only on links.
  static let css = """
    @font-face { font-family: Geist; src: url(termfs://app/GeistVariable.woff2) format("woff2"); font-weight: 100 900; }
    @font-face { font-family: "Geist Mono"; src: url(termfs://app/GeistMonoVariable.woff2) format("woff2"); font-weight: 100 900; }
    :root { color-scheme: dark; }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; padding: 14px 16px 56px; background: #121722; color: #a2abbf; font: 15px/1.6 Geist, -apple-system, sans-serif;
      letter-spacing: -0.005em; overflow-wrap: break-word; -webkit-font-smoothing: antialiased; }
    body > :first-child { margin-top: 0; }
    h1, h2, h3, h4, h5, h6 { color: #e6eaf3; font-weight: 600; line-height: 1.3; margin: 1.5em 0 0.55em; letter-spacing: -0.01em; }
    h1 { font-size: 22px; } h2 { font-size: 18px; } h3 { font-size: 16px; } h4, h5, h6 { font-size: 15px; }
    h1, h2 { padding-bottom: 0.35em; border-bottom: 1px solid rgba(150,175,255,.075); }
    p, ul, ol, blockquote, pre, table, details { margin: 0 0 14px; }
    a { color: #6f8cff; text-decoration: none; }
    strong { color: #e6eaf3; font-weight: 600; }
    del { color: #7c85a1; }
    code { font: 13px/1.5 "Geist Mono", ui-monospace, monospace; background: rgba(150,175,255,.08); border-radius: 5px; padding: 0.1em 0.35em; color: #e6eaf3; }
    pre { background: #0a0d13; border: 1px solid rgba(150,175,255,.075); border-radius: 8px; padding: 12px 14px; overflow-x: auto; }
    pre code { background: none; padding: 0; border-radius: 0; font-size: 12.5px; color: #a2abbf; }
    blockquote { margin-left: 0; padding-left: 14px; border-left: 2px solid rgba(150,175,255,.14); color: #7c85a1; }
    hr { border: 0; border-top: 1px solid rgba(150,175,255,.14); margin: 24px 0; }
    img { max-width: 100%; }
    ul, ol { padding-left: 22px; }
    li + li, li > ul, li > ol { margin-top: 4px; }
    li > ul, li > ol { margin-bottom: 0; }
    li:has(> input[type=checkbox]) { list-style: none; }
    input[type=checkbox] { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; margin: 0 7px 0 -21px;
      vertical-align: -2px; border: 1px solid rgba(150,175,255,.3); border-radius: 4px; }
    input[type=checkbox]:checked { background: #a2abbf; border-color: #a2abbf;
      box-shadow: inset 0 0 0 3px #121722; }
    table { border-collapse: collapse; display: block; overflow-x: auto; font-size: 13.5px; }
    th, td { border-bottom: 1px solid rgba(150,175,255,.075); padding: 7px 14px 7px 0; text-align: left; vertical-align: top; }
    th { color: #e6eaf3; font-weight: 600; border-bottom-color: rgba(150,175,255,.14); }
    table.front { font: 12px/1.5 "Geist Mono", ui-monospace, monospace; margin-bottom: 22px; }
    table.front th { color: #7c85a1; font-weight: 400; border-bottom-color: rgba(150,175,255,.075); white-space: nowrap; }
    table.front td { color: #a2abbf; }
    pre.front { font-size: 12px; color: #7c85a1; }
    .footnotes { font-size: 13px; color: #7c85a1; }
    summary { color: #e6eaf3; }
    """
}
