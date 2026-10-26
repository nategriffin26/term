import XCTest
@testable import Term

/// The `@diagrams` fetch rule: a drawing no source matches costs at most
/// `triesPerDrawing` execs, `fetchInterval` apart, however often the screen
/// redraws; sources are kept by hash.
@MainActor
final class DiagramSourceTests: XCTestCase {
  static let interval = Duration.milliseconds(50)

  /// Execs a fake host saw, and when.
  final class Host {
    var calls: [ContinuousClock.Instant] = []
    var reply: Data?
    init(reply: Data?) { self.reply = reply }
  }

  /// A source on a static screen: like the overlay, every change matches
  /// the screen again, and the drawings stay unmatched.
  func staticScreen(_ host: Host, drawings: Set<String>) -> DiagramSource {
    let source = DiagramSource(tmuxSession: "diag", fetchInterval: Self.interval) { _ in
      host.calls.append(.now)
      return host.reply
    }
    source.onChange = { [unowned source] in source.unmatched(drawings) }
    return source
  }

  func settle(_ ms: Int = 400) async throws {
    try await Task.sleep(for: .milliseconds(ms))
  }

  func json(_ entries: [(String, Double, String)]) -> String {
    let d = entries.map { h, t, src in
      let s = String(data: try! JSONSerialization.data(withJSONObject: [src], options: []), encoding: .utf8)!
      return "{\"h\":\"\(h)\",\"t\":\(t),\"src\":\(s.dropFirst().dropLast())}"
    }
    return "{\"v\":1,\"d\":[\(d.joined(separator: ","))]}"
  }

  func testParseReadsEveryPaneAndSkipsJunk() {
    let out = [
      json([("a1", 10, "flowchart TD\n A --> B")]),
      "not json",
      #"{"v":2,"d":[{"h":"v2","t":1,"src":"x"}]}"#,
      #"{"v":1,"d":[{"h":"nosrc","t":1},{"t":1,"src":"nohash"},{"h":"empty","t":1,"src":""},{"h":"b2","src":"pie\n \"caf\u00e9\" : 1"}]}"#,
      "",
    ].joined(separator: "\n")
    XCTAssertEqual(DiagramSource.parse(Data(out.utf8)), [
      .init(hash: "a1", time: 10, source: "flowchart TD\n A --> B"),
      .init(hash: "b2", time: 0, source: "pie\n \"café\" : 1"),
    ])
  }

  func testParseOfNothingIsNothing() {
    XCTAssertEqual(DiagramSource.parse(Data()), [])
    XCTAssertEqual(DiagramSource.parse(Data([0xFF, 0xFE, 0x0A])), [])
  }

  /// zsh expands an unquoted leading `=` (`=diag` → the path of a `diag` command).
  func testFetchCommandQuotesTheExactTarget() {
    XCTAssertTrue(DiagramSource.fetchCommand(tmuxSession: "diag").contains("list-panes -s -t '=diag' "))
    XCTAssertTrue(DiagramSource.fetchCommand(tmuxSession: "it's").contains(#"-t '=it'\''s' "#))
    XCTAssertTrue(DiagramSource.fetchCommand(tmuxSession: nil).contains("list-panes -a "))
  }

  func testAnUnmatchedDrawingFetchesThreeTimesIntervalApartThenStops() async throws {
    let host = Host(reply: Data())
    let source = staticScreen(host, drawings: ["alpha beta"])
    source.unmatched(["alpha beta"])
    try await settle()
    XCTAssertEqual(host.calls.count, DiagramSource.triesPerDrawing)
    for (a, b) in zip(host.calls, host.calls.dropFirst()) {
      XCTAssertGreaterThanOrEqual(b - a, Self.interval)
    }
    source.unmatched(["alpha beta"])
    try await settle(100)
    XCTAssertEqual(host.calls.count, DiagramSource.triesPerDrawing)
  }

  func testAFailedExecCountsAsATry() async throws {
    let host = Host(reply: nil)
    let source = staticScreen(host, drawings: ["alpha beta"])
    source.unmatched(["alpha beta"])
    try await settle()
    XCTAssertEqual(host.calls.count, DiagramSource.triesPerDrawing)
  }

  func testANewDrawingGetsItsOwnTries() async throws {
    let host = Host(reply: Data())
    let source = staticScreen(host, drawings: ["alpha beta"])
    source.unmatched(["alpha beta"])
    try await settle()
    source.onChange = { [unowned source] in source.unmatched(["alpha beta", "gamma delta"]) }
    source.unmatched(["alpha beta", "gamma delta"])
    try await settle()
    XCTAssertEqual(host.calls.count, 2 * DiagramSource.triesPerDrawing)
  }

  func testAFetchFindsItsSourceAndMatchingStops() async throws {
    let host = Host(reply: Data(json([("f1", 5, "flowchart TD\n A[alpha] --> B[beta]")]).utf8))
    let source = DiagramSource(tmuxSession: "diag", fetchInterval: Self.interval) { _ in
      host.calls.append(.now)
      return host.reply
    }
    var changes = 0
    source.onChange = { changes += 1 }
    source.unmatched(["alpha beta"])
    try await settle(100)
    XCTAssertEqual(host.calls.count, 1)
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(source.source("f1"), "flowchart TD\n A[alpha] --> B[beta]")
    XCTAssertEqual(source.candidates.map(\.hash), ["f1"])
  }

  func testMergeKeepsKnownSourcesWhenAFetchReturnsFewer() {
    let source = DiagramSource(tmuxSession: nil) { _ in nil }
    source.merge([.init(hash: "a", time: 1, source: "A"), .init(hash: "b", time: 2, source: "B")])
    source.merge([.init(hash: "b", time: 2, source: "B")])
    XCTAssertEqual(source.source("a"), "A")
    XCTAssertEqual(source.candidates.map(\.hash), ["a", "b"])
  }

  /// omp re-stamps a source it draws again: it becomes the newest candidate.
  func testARepublishedSourceBecomesTheNewest() {
    let source = DiagramSource(tmuxSession: nil) { _ in nil }
    source.merge([.init(hash: "a", time: 1, source: "A"), .init(hash: "b", time: 2, source: "B")])
    source.merge([.init(hash: "a", time: 3, source: "A")])
    XCTAssertEqual(source.candidates.map(\.hash), ["b", "a"])
    XCTAssertEqual(source.candidates.last?.time, 3)
  }

  func testCapacityDropsTheOldest() {
    let source = DiagramSource(tmuxSession: nil) { _ in nil }
    let cap = DiagramSource.capacity
    source.merge((1...cap).map { .init(hash: "h\($0)", time: Double($0), source: "s\($0)") })
    XCTAssertEqual(source.candidates.count, cap)
    XCTAssertNotNil(source.source("h1"))
    source.merge([.init(hash: "h\(cap + 1)", time: Double(cap + 1), source: "new")])
    XCTAssertEqual(source.candidates.count, cap)
    XCTAssertNil(source.source("h1"))
    XCTAssertNotNil(source.source("h2"))
    XCTAssertEqual(source.source("h\(cap + 1)"), "new")
  }
}
