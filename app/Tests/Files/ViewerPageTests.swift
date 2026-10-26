import XCTest
@testable import Term

final class LoadPlanTests: XCTestCase {
  /// Bugs: an off-by-one at a tier reads a 16 MB + 1 file whole into the
  /// editor, or sends a 1 MB + 1 file through one unbounded read.
  func testTiersAtTheirBoundaries() {
    let mb: UInt64 = 1 << 20
    XCTAssertEqual(LoadPlan.text(size: 0), .read)
    XCTAssertEqual(LoadPlan.text(size: mb), .read)
    XCTAssertEqual(LoadPlan.text(size: mb + 1), .fetch)
    XCTAssertEqual(LoadPlan.text(size: 16 * mb), .fetch)
    XCTAssertEqual(LoadPlan.text(size: 16 * mb + 1), .head(mb))
  }

  /// Bug: text just over 5 MB opens editable (Runestone crawls), or a file
  /// shown cut off at 1 MB can be saved, truncating it on the host.
  func testReadOnlyAboveFiveMegabytesAndWhenCut() {
    let mb: UInt64 = 1 << 20
    XCTAssertNil(LoadPlan.readOnlyReason(size: 5 * mb))
    XCTAssertEqual(LoadPlan.readOnlyReason(size: 5 * mb + 1), "Over 5 MB · read-only")
    XCTAssertEqual(LoadPlan.readOnlyReason(size: 16 * mb), "Over 5 MB · read-only")
    XCTAssertEqual(LoadPlan.readOnlyReason(size: 16 * mb + 1)?.hasPrefix("First 1 MB of "), true)
  }
}

final class TermFSURLTests: XCTestCase {
  /// Bug: a "#" or "?" in a file name becomes the URL's fragment or query,
  /// a "%" is read as an escape, so the image or link never loads.
  func testPathsRoundTrip() {
    for path in ["/Users/n/a b.png", "/tmp/shot #1.png", "/tmp/why?.md", "/tmp/100%.txt", "/tmp/a;b.css", "/home/n/café/日本.md"] {
      XCTAssertEqual(TermFSURL.path(TermFSURL.file(path)), path)
    }
  }

  /// Bug: a base URL without its trailing slash resolves "img/x.png" next to
  /// the folder instead of inside it.
  func testRelativeLinksResolveInTheFilesFolder() {
    let base = TermFSURL.folder(of: "/Users/n/docs/README.md")
    XCTAssertEqual(TermFSURL.path(URL(string: "img/x.png", relativeTo: base)!.absoluteURL), "/Users/n/docs/img/x.png")
    XCTAssertEqual(TermFSURL.path(URL(string: "../shots/a%20b.png", relativeTo: base)!.absoluteURL), "/Users/n/shots/a b.png")
    XCTAssertEqual(TermFSURL.path(URL(string: "/etc/hosts", relativeTo: base)!.absoluteURL), "/etc/hosts")
    XCTAssertEqual(TermFSURL.path(TermFSURL.folder(of: "/README.md")), "/")
  }

  func testOnlyFileURLsNameHostPaths() {
    XCTAssertNil(TermFSURL.path(URL(string: "termfs://app/font.woff2")!))
    XCTAssertNil(TermFSURL.path(URL(string: "https://example.com/a.png")!))
  }
}

final class MarkdownPageTests: XCTestCase {
  /// Bug (why swift-markdown's HTMLFormatter was rejected): HTML inside code
  /// renders as markup instead of showing as text.
  func testCodeIsEscaped() {
    let html = MarkdownPage.render("Use `<b>bold</b>`.\n\n```html\n<script>alert(1)</script>\n```\n")
    XCTAssertTrue(html.contains("<code>&lt;b&gt;bold&lt;/b&gt;</code>"), html)
    XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), html)
    XCTAssertTrue(html.contains("<pre lang=\"html\">"), html)
  }

  /// Bug: GitHub's extensions not attached, so tables show as pipes, task
  /// lists as "[x]" and ~~gone~~ as tildes.
  func testGitHubExtensions() {
    let html = MarkdownPage.render("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n- [ ] todo\n\n~~gone~~ www.example.com\n")
    XCTAssertTrue(html.contains("<table>"), html)
    XCTAssertTrue(html.contains("<td>2</td>"), html)
    XCTAssertTrue(html.contains("type=\"checkbox\" checked=\"\" disabled=\"\""), html)
    XCTAssertTrue(html.contains("<del>gone</del>"), html)
    XCTAssertTrue(html.contains("<a href=\"http://www.example.com\">"), html)
  }

  /// Bug: raw <script> in a README passes through (raw HTML is on for
  /// <img>/<details>; GitHub's tag filter must still defuse scripts).
  func testRawScriptIsFiltered() {
    let html = MarkdownPage.render("<details><summary>More</summary>hidden</details>\n\n<script>alert(1)</script>\n")
    XCTAssertTrue(html.contains("<details><summary>More</summary>"), html)
    XCTAssertFalse(html.contains("<script>"), html)
  }

  /// Bug: a table of contents ("[Usage](#usage)") jumps nowhere: cmark gives
  /// headings no ids. Repeated headings get -1, as on GitHub.
  func testHeadingsGetGitHubIds() {
    let html = MarkdownPage.render("# Hello, World!\n\n## Hello, World!\n\n### `term_fs` API\n")
    XCTAssertTrue(html.contains("<h1><a id=\"hello-world\"></a>Hello, World!</h1>"), html)
    XCTAssertTrue(html.contains("<h2><a id=\"hello-world-1\"></a>Hello, World!</h2>"), html)
    XCTAssertTrue(html.contains("<a id=\"term_fs-api\"></a>"), html)
  }

  /// Bug: a SKILL.md's front matter renders as a rule and a big setext
  /// heading ("description: …" underlined by the closing ---).
  func testFrontMatterIsATable() {
    let page = MarkdownPage.html("---\nname: glass\ndescription: \"The <default> look\"\n---\n# Glass\n")
    XCTAssertTrue(page.contains("<table class=\"front\"><tr><th>name</th><td>glass</td></tr><tr><th>description</th><td>The &lt;default&gt; look</td></tr></table>"), page)
    XCTAssertFalse(page.contains("<h2>"), page)
    XCTAssertFalse(page.contains("<hr"), page)
    XCTAssertTrue(page.contains("Glass</h1>"), page)
  }

  /// Nested YAML can't be a flat table: shown as its source. A lone "---"
  /// with no closing line is a rule, not front matter.
  func testFrontMatterEdges() {
    let nested = MarkdownPage.html("---\nmetadata:\n  kind: style\n---\nbody\n")
    XCTAssertTrue(nested.contains("<pre class=\"front\">metadata:\n  kind: style</pre>"), nested)
    XCTAssertNil(MarkdownPage.splitFrontMatter("---\nnot closed\n").front)
    XCTAssertNil(MarkdownPage.splitFrontMatter("text\n---\nmore\n---\n").front)
    XCTAssertEqual(MarkdownPage.splitFrontMatter("---\r\na: 1\r\n---\r\nbody").front, "a: 1")
  }
}
