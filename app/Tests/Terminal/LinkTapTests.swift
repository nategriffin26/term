import UIKit
import XCTest
@testable import Term

/// A tap on an http(s) link opens it in the default browser instead of
/// raising the keyboard or clicking; everything else taps as before.
@MainActor
final class LinkTapTests: XCTestCase {
  private var window: UIWindow?
  private var delegateStub: Stub?
  private var opened: [URL] = []
  private var savedOpen: (@MainActor (URL) async -> Bool)?

  override func setUp() async throws {
    savedOpen = LinkOpener.open
    LinkOpener.open = { [weak self] url in
      self?.opened.append(url)
      return true
    }
  }

  override func tearDown() async throws {
    if let savedOpen { LinkOpener.open = savedOpen }
    window?.isHidden = true
    window = nil
    delegateStub = nil
  }

  private final class FakeTap: TimedTapGestureRecognizer {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
  }

  private final class Stub: TerminalViewDelegate {
    var edgeBand = false
    var doubleTaps = 0
    func terminalViewHasEdgeBand(_ view: TerminalView) -> Bool { edgeBand }
    func terminalViewDoubleTapped(_ view: TerminalView) -> Bool {
      doubleTaps += 1
      return true
    }
    func terminalView(_ view: TerminalView, didChangeFontSize pointSize: CGFloat) {}
    func terminalView(_ view: TerminalView, paste clip: Clip) -> Bool { false }
    func terminalView(_ view: TerminalView, insertFrom source: InsertSource) {}
    func terminalView(_ view: TerminalView, didSizeGrid grid: GridSize) {}
    func terminalView(_ view: TerminalView, voiceNotice text: String) {}
    func terminalViewOpensVoiceSettings(_ view: TerminalView) {}
    func terminalViewDictationDestination(_ view: TerminalView) -> DictationDestination? { nil }
  }

  /// An unfocused 320 pt terminal showing `output` (its program tracking the
  /// mouse when `mouse`), and the bytes it sends.
  private func terminal(_ output: (Int) -> String, mouse: Bool = false, edgeBand: Bool = false) async throws
    -> (TerminalView, Stub, () -> String)
  {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let session = try XCTUnwrap(Session(localCols: 30, rows: 20))
    var sent = Data()
    session.onOutput = { sent.append($0) }
    let view = TerminalView(session: session)
    let stub = Stub()
    stub.edgeBand = edgeBand
    view.delegate = stub
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    self.window = window
    delegateStub = stub
    view.resignFirstResponder()
    try await until("the grid is sized") { view.snapshot.cols > 0 && view.snapshot.cols == view.gridSize.cols }
    if mouse { session.feed("\u{1B}[?1000h\u{1B}[?1006h") }
    session.feed(output(view.snapshot.cols) + "\r\n#end#")
    try await until("the output is drawn") {
      Self.find("#end#", in: view) != nil && view.snapshot.has(TERM_MODE_MOUSE_TRACKING) == mouse
    }
    return (view, stub, { String(decoding: sent, as: UTF8.self) })
  }

  private func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(3)
    while !condition(), Date.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(condition(), what)
  }

  /// The viewport cell where `needle` starts, from what the view draws.
  private static func find(_ needle: String, in view: TerminalView) -> (col: Int, row: Int)? {
    let s = view.snapshot
    for row in 0..<s.rows {
      let line = String((0..<s.cols).map { Character(Unicode.Scalar(s.cells[row * s.cols + $0].ch).map { $0 == "\0" ? " " : $0 } ?? " ") })
      if let r = line.range(of: needle) { return (line.distance(from: line.startIndex, to: r.lowerBound), row) }
    }
    return nil
  }

  private func point(_ view: TerminalView, col: Int, row: Int) -> CGPoint {
    let r = view.rect(col: col, row: row)
    return CGPoint(x: r.midX, y: r.midY)
  }

  private func point(_ view: TerminalView, of needle: String, plus offset: Int = 0) throws -> CGPoint {
    let at = try XCTUnwrap(Self.find(needle, in: view), "\(needle) on screen")
    return point(view, col: at.col + offset, row: at.row)
  }

  private func tap(_ view: TerminalView, at point: CGPoint) {
    let now = ProcessInfo.processInfo.systemUptime
    let tap = FakeTap()
    tap.point = point
    tap.touchTime = now
    tap.liftTime = now
    view.perform(NSSelectorFromString("handleTap:"), with: tap)
  }

  /// The opener runs in a task: let it.
  private func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

  private static func presses(_ output: String) -> Int { output.filter { $0 == "M" }.count }

  // Bug: tapping a link did nothing (the user had to copy it into Safari).
  func testATapOnAURLOpensItAndLeavesTheKeyboardAndMouseAlone() async throws {
    let (view, _, sent) = try await terminal { _ in "see https://example.com/a?b=c now\r\n" }
    tap(view, at: try point(view, of: "example"))
    try await settle()
    XCTAssertEqual(opened, [URL(string: "https://example.com/a?b=c")])
    XCTAssertFalse(view.isFirstResponder, "a link tap raises no keyboard")
    XCTAssertEqual(sent(), "")
  }

  // Bug: a URL the terminal wrapped onto a second row opening cut at the row end.
  func testASoftWrappedURLOpensWhole() async throws {
    var url = ""
    let (view, _, _) = try await terminal { cols in
      url = "https://example.com/" + String(repeating: "x", count: cols) + "/end"
      return url + "\r\n"
    }
    let start = try XCTUnwrap(Self.find("https://", in: view))
    tap(view, at: point(view, col: 2, row: start.row + 1))
    try await settle()
    XCTAssertEqual(opened, [URL(string: url)])
  }

  // Bug: punctuation after a URL in prose sent to the browser.
  func testTrailingPunctuationIsTrimmed() async throws {
    let (view, _, _) = try await terminal { _ in "(see https://example.com/a)." }
    tap(view, at: try point(view, of: "example"))
    try await settle()
    XCTAssertEqual(opened, [URL(string: "https://example.com/a")])
  }

  // Bug: an OSC 8 link opening its visible text instead of its target.
  func testAnOSC8LinkOpensItsURIWhateverItsText() async throws {
    let (view, _, _) = try await terminal { _ in "\u{1B}]8;;https://example.com/target\u{07}read the docs\u{1B}]8;;\u{07}\r\n" }
    tap(view, at: try point(view, of: "docs"))
    try await settle()
    XCTAssertEqual(opened, [URL(string: "https://example.com/target")])
  }

  // Bug: omp's file:// path links or a plain path opening as links instead of tapping as before.
  func testAFileLinkAndAPathTapAsBefore() async throws {
    let (view, _, _) = try await terminal { _ in
      "\u{1B}]8;;file:///tmp/notes.md\u{07}/tmp/notes.md\u{1B}]8;;\u{07}\r\nsrc/http/main.rs\r\n"
    }
    tap(view, at: try point(view, of: "notes"))
    try await settle()
    XCTAssertEqual(opened, [])
    XCTAssertTrue(view.isFirstResponder, "a file:// link tap raises the keyboard as any tap does")
    view.resignFirstResponder()
    tap(view, at: try point(view, of: "main"))
    try await settle()
    XCTAssertEqual(opened, [])
    XCTAssertTrue(view.isFirstResponder, "so does a path")
  }

  // Bug: under tmux with the mouse on, a link tap clicking (tmux moves the
  // pane focus or selects) as well as opening, or a plain tap no longer clicking.
  func testUnderMouseTrackingALinkTapSendsNoClickAndOtherTapsClick() async throws {
    let (view, _, sent) = try await terminal({ _ in "open https://example.com/a here\r\n" }, mouse: true)
    view.becomeFirstResponder()
    tap(view, at: try point(view, of: "example"))
    try await settle()
    XCTAssertEqual(opened, [URL(string: "https://example.com/a")])
    XCTAssertEqual(sent(), "", "no click for a link")
    tap(view, at: try point(view, of: "here"))
    try await settle()
    XCTAssertEqual(opened.count, 1)
    XCTAssertEqual(Self.presses(sent()), 1, "a tap off the link still clicks")
  }

  // Bug: a band tap on a link clicking (or opening at once, so a double tap opens it too).
  func testABandTapOnALinkOpensItOnceTheWindowPasses() async throws {
    let (view, stub, sent) = try await terminal({ cols in
      String(repeating: " ", count: cols - 24) + "https://example.com/abcd\r\n"
    }, mouse: true, edgeBand: true)
    let p = try point(view, of: "abcd", plus: 3)
    XCTAssertTrue(DoubleTap.band(in: view.bounds).contains(p), "the URL's end is in the band")
    tap(view, at: p)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(opened, [], "held while a second tap may come")
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(opened, [URL(string: "https://example.com/abcd")])
    XCTAssertEqual(sent(), "", "no click")
    XCTAssertEqual(stub.doubleTaps, 0)
  }

  // Bug: a band double tap over a link opening the link as well as Sessions.
  func testABandDoubleTapOnALinkOpensSessionsAndNoLink() async throws {
    let (view, stub, sent) = try await terminal({ cols in
      String(repeating: " ", count: cols - 24) + "https://example.com/abcd\r\n"
    }, mouse: true, edgeBand: true)
    let p = try point(view, of: "abcd", plus: 3)
    tap(view, at: p)
    tap(view, at: p)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(stub.doubleTaps, 1)
    XCTAssertEqual(opened, [])
    XCTAssertEqual(sent(), "")
  }

  // Bug: a tap scrolled back in history opening the link at that screen
  // position on the live screen, or nothing.
  func testATapScrolledBackOpensTheLinkShownThere() async throws {
    let (view, _, _) = try await terminal { _ in
      "https://example.com/old\r\n" + (1...60).map { "line \($0)" }.joined(separator: "\r\n")
    }
    XCTAssertNil(Self.find("example.com/old", in: view), "scrolled off")
    view.session.scroll(by: 40)
    try await until("scrolled back") { Self.find("example.com/old", in: view) != nil }
    XCTAssertGreaterThan(view.snapshot.viewportOffset, 0)
    tap(view, at: try point(view, of: "example.com/old"))
    try await settle()
    XCTAssertEqual(opened, [URL(string: "https://example.com/old")])
  }

  // Bug: a link that fails to open dropping the tap silently with no record
  // (the device log shows each link decision and its result, never the URL).
  func testAFailedOpenIsLoggedWithoutTheURL() async throws {
    LinkOpener.open = { _ in false }
    let (view, _, _) = try await terminal { _ in "see https://example.com/secret-path now\r\n" }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let file = library.appending(path: "Logs/term.log")
    DiagnosticLog.flush()
    let before = (try? Data(contentsOf: file).count) ?? 0
    tap(view, at: try point(view, of: "example"))
    try await Task.sleep(for: .milliseconds(300))
    DiagnosticLog.flush()
    let log = String(decoding: try Data(contentsOf: file).dropFirst(before), as: UTF8.self)
    let line = try XCTUnwrap(log.split(separator: "\n").first { $0.contains(" tap link ") }, "a line for this tap")
    XCTAssertTrue(line.contains("kind=text") && line.contains("scheme=https") && line.contains("result=failed"), String(line))
    XCTAssertFalse(log.contains("secret-path"), "no URL in the log")
  }
}
