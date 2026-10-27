import XCTest
@testable import Term

/// The Sessions mosaic's layout: weights, the row split, the 112×78 floor and
/// the shelf, and where a lifted tile or chip lands. Expected frames are
/// worked out by hand from the rules (8 pt gaps, rows by weight, 1.35:1
/// target, chips wrapping left to right).
final class MosaicTests: XCTestCase {
  private func tiles(_ ids: String, _ importance: Mosaic.Importance = .idle) -> [Mosaic.Tile<String>] {
    ids.map { Mosaic.Tile(id: String($0), importance: importance) }
  }

  private func chips(_ width: CGFloat) -> (String) -> CGFloat { { _ in width } }

  private func place(_ id: String, after: String?) -> Mosaic.Placement<String> { .init(id: id, after: after) }

  private func agent(_ state: AgentInfo.State, unread: Bool = false) -> AgentInfo {
    var agent = AgentInfo(session: "s", state: state)
    agent.unread = unread
    return agent
  }

  // MARK: Weights

  // Bug: a session asking the user drawn no larger than the rest, or the one the user came from not the largest.
  func testWeights() {
    XCTAssertEqual(Mosaic.Importance.current.weight, 2.2)
    XCTAssertEqual(Mosaic.Importance.needsYou.weight, 1.6)
    XCTAssertEqual(Mosaic.Importance.working.weight, 1)
    XCTAssertEqual(Mosaic.Importance.stopped.weight, 1)
    XCTAssertEqual(Mosaic.Importance.idle.weight, 1)
  }

  // Bug: an agent's question or approval not read as needing the user; the session the user came from shrinking when it also asks.
  func testImportanceFromTheAgent() {
    XCTAssertEqual(Mosaic.Importance(agent: agent(.ask), isCurrent: false), .needsYou)
    XCTAssertEqual(Mosaic.Importance(agent: agent(.approval), isCurrent: false), .needsYou)
    XCTAssertEqual(Mosaic.Importance(agent: agent(.ask), isCurrent: true), .current)
    XCTAssertEqual(Mosaic.Importance(agent: agent(.working), isCurrent: false), .working)
    XCTAssertEqual(Mosaic.Importance(agent: agent(.done, unread: true), isCurrent: false), .stopped)
    XCTAssertEqual(Mosaic.Importance(agent: agent(.error, unread: true), isCurrent: false), .stopped)
    XCTAssertEqual(Mosaic.Importance(agent: agent(.done), isCurrent: false), .idle, "a stop the user has seen is at rest")
    XCTAssertEqual(Mosaic.Importance(agent: agent(.idle), isCurrent: false), .idle)
    XCTAssertEqual(Mosaic.Importance(agent: nil, isCurrent: false), .idle)
  }

  // MARK: Rows

  // Bug: one session not filling the panel.
  func testOneSessionFillsTheArea() {
    let area = CGRect(x: 12, y: 60, width: 400, height: 300)
    XCTAssertEqual(Mosaic.rows([("a", 1)], in: area), ["a": area])
  }

  // Bug: the split ignoring the panel's shape (two thin columns in a tall panel, two strips in a wide one).
  func testTwoSessionsSplitAlongTheLongSide() {
    XCTAssertEqual(Mosaic.rows([("a", 1), ("b", 1)], in: CGRect(x: 0, y: 0, width: 600, height: 200)),
                   ["a": CGRect(x: 0, y: 0, width: 296, height: 200), "b": CGRect(x: 304, y: 0, width: 296, height: 200)])
    XCTAssertEqual(Mosaic.rows([("a", 1), ("b", 1)], in: CGRect(x: 0, y: 0, width: 300, height: 500)),
                   ["a": CGRect(x: 0, y: 0, width: 300, height: 246), "b": CGRect(x: 0, y: 254, width: 300, height: 246)])
  }

  // Bug: tiles out of swipe order (rows must read left to right, top to bottom).
  func testFourSessionsReadInSwipeOrder() {
    XCTAssertEqual(Mosaic.rows([("a", 1), ("b", 1), ("c", 1), ("d", 1)], in: CGRect(x: 0, y: 0, width: 600, height: 400)),
                   ["a": CGRect(x: 0, y: 0, width: 296, height: 196), "b": CGRect(x: 304, y: 0, width: 296, height: 196),
                    "c": CGRect(x: 0, y: 204, width: 296, height: 196), "d": CGRect(x: 304, y: 204, width: 296, height: 196)])
  }

  // Bug: the session the user came from no bigger than the others (area must follow weight: 2.2 to 1 of 640 pt).
  func testAreaFollowsWeight() {
    XCTAssertEqual(Mosaic.rows([("a", 2.2), ("b", 1)], in: CGRect(x: 0, y: 0, width: 648, height: 200)),
                   ["a": CGRect(x: 0, y: 0, width: 440, height: 200), "b": CGRect(x: 448, y: 0, width: 200, height: 200)])
  }

  // Bug: tiles squeezed under 112×78, or refused at exactly 112×78.
  func testMinimumTileBoundary() {
    XCTAssertEqual(Mosaic.rows([("a", 1), ("b", 1)], in: CGRect(x: 0, y: 0, width: 232, height: 78)),
                   ["a": CGRect(x: 0, y: 0, width: 112, height: 78), "b": CGRect(x: 120, y: 0, width: 112, height: 78)])
    XCTAssertNil(Mosaic.rows([("a", 1), ("b", 1)], in: CGRect(x: 0, y: 0, width: 231, height: 78)))
    XCTAssertNil(Mosaic.rows([("a", 1), ("b", 1)], in: CGRect(x: 0, y: 0, width: 232, height: 77)))
    XCTAssertNotNil(Mosaic.rows([("a", 1)], in: CGRect(x: 0, y: 0, width: 112, height: 78)))
    XCTAssertNil(Mosaic.rows([("a", 1)], in: CGRect(x: 0, y: 0, width: 111, height: 78)))
  }

  // MARK: Shelf

  func testEverythingThatFitsGetsATile() {
    let layout = Mosaic.layout(tiles("abcd"), in: CGRect(x: 0, y: 0, width: 232, height: 164), chipWidth: chips(60))
    XCTAssertEqual(layout.shelf, [])
    XCTAssertEqual(layout.frames["d"], CGRect(x: 120, y: 86, width: 112, height: 78))
  }

  // Bug: a fifth session shrunk under 112×78 instead of shelved, or the shelf drawn over the tiles.
  func testWhatDoesNotFitGoesToTheShelfUnderTheTiles() {
    // Four fit in 232×164; five need the shelf, whose 36 + 8 pt leave one row of 120.
    let layout = Mosaic.layout(tiles("abcde"), in: CGRect(x: 0, y: 0, width: 232, height: 164), chipWidth: chips(60))
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 112, height: 120), "b": CGRect(x: 120, y: 0, width: 112, height: 120)])
    XCTAssertEqual(layout.shelf, ["c", "d", "e"], "equals leave from the end, and the shelf keeps swipe order")
    XCTAssertEqual(layout.chips, ["c": CGRect(x: 0, y: 128, width: 60, height: 36), "d": CGRect(x: 68, y: 128, width: 60, height: 36),
                                  "e": CGRect(x: 136, y: 128, width: 60, height: 36)])
  }

  // Bug: chips running off the panel's edge, or a second row of chips drawn over the tiles.
  func testChipsWrapIntoRowsThatTakeTheirHeightFromTheTiles() {
    let area = CGRect(x: 0, y: 0, width: 232, height: 250)
    // Chips 60 wide share one row: four tiles still fit above it.
    XCTAssertEqual(Mosaic.layout(tiles("abcdefg"), in: area, chipWidth: chips(60)).frames.count, 4)
    // Two chips 100 wide fill a row: the third wraps, and the rows leave room for two tiles.
    let layout = Mosaic.layout(tiles("abcdefg"), in: area, chipWidth: chips(100))
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 112, height: 118), "b": CGRect(x: 120, y: 0, width: 112, height: 118)])
    XCTAssertEqual(layout.chips, ["c": CGRect(x: 0, y: 126, width: 100, height: 36), "d": CGRect(x: 108, y: 126, width: 100, height: 36),
                                  "e": CGRect(x: 0, y: 170, width: 100, height: 36), "f": CGRect(x: 108, y: 170, width: 100, height: 36),
                                  "g": CGRect(x: 0, y: 214, width: 100, height: 36)])
  }

  // Bug: the session asking the user or the one the user came from shelved before idle ones.
  func testTheShelfTakesTheLeastImportantFirst() {
    let order: [Mosaic.Tile<String>] = [
      .init(id: "e", importance: .idle), .init(id: "a", importance: .current), .init(id: "d", importance: .stopped),
      .init(id: "b", importance: .needsYou), .init(id: "c", importance: .working),
    ]
    let layout = Mosaic.layout(order, in: CGRect(x: 0, y: 0, width: 300, height: 164), chipWidth: chips(60))
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 169, height: 120), "b": CGRect(x: 177, y: 0, width: 123, height: 120)])
    XCTAssertEqual(layout.shelf, ["e", "d", "c"])
  }

  // Bug: sessions vanishing when not even one tile fits.
  func testNoRoomPutsEverySessionOnTheShelf() {
    let layout = Mosaic.layout(tiles("ab"), in: CGRect(x: 0, y: 0, width: 100, height: 50), chipWidth: chips(60))
    XCTAssertEqual(layout.frames, [:])
    XCTAssertEqual(layout.shelf, ["a", "b"])
    XCTAssertEqual(Set(layout.chips.keys), ["a", "b"])
    XCTAssertEqual(Mosaic.layout([Mosaic.Tile<String>](), in: CGRect(x: 0, y: 0, width: 400, height: 400), chipWidth: chips(60)),
                   Mosaic.Layout())
  }

  // MARK: Reorder

  // Bug: a lifted tile landing in a slot other than the one it is held over.
  func testALiftedTileLandsInTheSlotItIsHeldOver() {
    let area = CGRect(x: 0, y: 0, width: 600, height: 400)
    let four = tiles("abcd")
    let run: Set = ["a", "b", "c", "d"]
    // Slots of the 2×2 mosaic: centres (148, 98), (452, 98), (148, 302), (452, 302).
    XCTAssertEqual(Mosaic.landing(place("a", after: nil), in: four, run: run, near: CGPoint(x: 440, y: 290), area: area,
                                  chipWidth: chips(60)), place("a", after: "d"))
    XCTAssertEqual(Mosaic.landing(place("a", after: nil), in: four, run: run, near: CGPoint(x: 160, y: 290), area: area,
                                  chipWidth: chips(60)), place("a", after: "c"))
    XCTAssertEqual(Mosaic.landing(place("a", after: "d"), in: four, run: run, near: CGPoint(x: 150, y: 100), area: area,
                                  chipWidth: chips(60)), place("a", after: nil))
  }

  // Bug: a session on the shelf that cannot be dragged into the mosaic, or a window that cannot be put on the shelf.
  func testChipsAndWindowsLandAcrossTheShelfEdge() {
    // Tiles a and b over chips c, d, e (as in testWhatDoesNotFitGoesToTheShelfUnderTheTiles).
    let area = CGRect(x: 0, y: 0, width: 232, height: 164)
    let five = tiles("abcde")
    let run: Set = ["a", "b", "c", "d", "e"]
    XCTAssertEqual(Mosaic.landing(place("e", after: "d"), in: five, run: run, near: CGPoint(x: 56, y: 60), area: area,
                                  chipWidth: chips(60)), place("e", after: nil), "chip e held over tile a takes its place")
    XCTAssertEqual(Mosaic.landing(place("a", after: nil), in: five, run: run, near: CGPoint(x: 166, y: 146), area: area,
                                  chipWidth: chips(60)), place("a", after: "e"), "window a held at the shelf's end goes there")
  }

  // Bug: a tile from one window dropped among another window's tabs.
  func testALiftedTileStaysInItsWindowsRun() {
    let area = CGRect(x: 0, y: 0, width: 600, height: 400)
    XCTAssertEqual(Mosaic.landing(place("a", after: nil), in: tiles("abcd"), run: ["a", "b"], near: CGPoint(x: 440, y: 290),
                                  area: area, chipWidth: chips(60)), place("a", after: "b"))
  }

  // Bug: a tile held between two slots flickering from one to the other.
  func testTheCurrentSlotWinsANearTie() {
    let area = CGRect(x: 0, y: 0, width: 600, height: 400)
    let run: Set = ["a", "b", "c", "d"]
    func landing(_ x: CGFloat) -> Mosaic.Placement<String> {
      Mosaic.landing(place("a", after: nil), in: tiles("abcd"), run: run, near: CGPoint(x: x, y: 98), area: area,
                     chipWidth: chips(60))
    }
    // 152 pt from both top slots: it stays; 20 pt nearer the right one is not enough to leave...
    XCTAssertEqual(landing(300), place("a", after: nil))
    XCTAssertEqual(landing(310), place("a", after: nil))
    // ...but 40 pt nearer is.
    XCTAssertEqual(landing(320), place("a", after: "b"))
  }

  // Bug: sessions opening or closing during a drag moving the lifted one away from the place the preview showed.
  func testAPlaceHeldByIdentityOutlivesSessionsOpeningAndClosing() {
    let held = place("d", after: "a")
    XCTAssertEqual(held.apply(to: ["a", "b", "c", "d"], id: { $0 }, run: ["a", "b", "c", "d"]), ["a", "d", "b", "c"])
    XCTAssertEqual(held.apply(to: ["x", "a", "b", "c", "d"], id: { $0 }, run: ["x", "a", "b", "c", "d"]), ["x", "a", "d", "b", "c"],
                   "a session opening before it")
    XCTAssertEqual(held.index(in: ["x", "a", "b", "c", "d"], run: ["x", "a", "b", "c", "d"]), 2)
    XCTAssertEqual(held.apply(to: ["a", "c", "d"], id: { $0 }, run: ["a", "c", "d"]), ["a", "d", "c"], "a session closing")
    XCTAssertEqual(held.index(in: ["a", "c", "d"], run: ["a", "c", "d"]), 1)
    XCTAssertEqual(held.apply(to: ["b", "c", "d"], id: { $0 }, run: ["b", "c", "d"]), ["b", "c", "d"],
                   "the session it follows closing: it stays put until it lands again")
    XCTAssertNil(held.apply(to: ["a", "b", "c"], id: { $0 }, run: ["a", "b", "c"]), "the lifted session closing")
    // Another window's sessions before its run: first of the run means after them.
    XCTAssertEqual(place("d", after: nil).apply(to: ["p", "q", "c", "d"], id: { $0 }, run: ["c", "d"]), ["p", "q", "d", "c"])
    XCTAssertEqual(Mosaic.Placement(of: "c", in: ["p", "q", "a", "c"], run: ["a", "c"]), place("c", after: "a"))
    XCTAssertEqual(Mosaic.Placement(of: "a", in: ["p", "q", "a", "c"], run: ["a", "c"]), place("a", after: nil))
  }
}
