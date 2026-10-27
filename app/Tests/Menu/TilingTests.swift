import XCTest
@testable import Term

/// The Sessions tiling: the even default, the shelf, border drags and
/// evening out, drops on an edge or a middle, sessions arriving and leaving,
/// and a saved tiling coming back. Expected frames are worked out by hand
/// from the rules (8 pt gaps, 112×78 floor, rounded extents with the last
/// part taking the rest, chips wrapping left to right).
final class TilingTests: XCTestCase {
  private typealias Tree = SplitTree<String>

  private func w(_ id: String) -> Tree { .window(id) }
  private func across(_ parts: (CGFloat, Tree)...) -> Tree { .split(.across, parts.map { .init(share: $0.0, node: $0.1) }) }
  private func down(_ parts: (CGFloat, Tree)...) -> Tree { .split(.down, parts.map { .init(share: $0.0, node: $0.1) }) }
  private func chips(_ width: CGFloat) -> (String) -> CGFloat { { _ in width } }
  private func ids(_ s: String) -> [String] { s.map(String.init) }

  private func layout(_ tree: Tree?, _ area: CGRect, chip: CGFloat = 60) -> Tiling.Layout<String> {
    Tiling.layout(tree, in: area, chipWidth: chips(chip))
  }

  private func even(_ s: String, _ area: CGRect, chip: CGFloat = 60) -> Tiling.Layout<String> {
    layout(Tiling.evenTree(ids(s), in: area, chipWidth: chips(chip)), area, chip: chip)
  }

  // MARK: The even default

  // Bug: one window (the session the user came from, or one asking) drawn larger than the rest.
  func testFourSessionsShareThePanelEvenly() {
    let layout = even("abcd", CGRect(x: 0, y: 0, width: 600, height: 400))
    XCTAssertEqual(layout.frames, [
      "a": CGRect(x: 0, y: 0, width: 296, height: 196), "b": CGRect(x: 304, y: 0, width: 296, height: 196),
      "c": CGRect(x: 0, y: 204, width: 296, height: 196), "d": CGRect(x: 304, y: 204, width: 296, height: 196),
    ])
    XCTAssertEqual(layout.shelf, [])
  }

  // Bug: nine sessions in uneven rows (3+2+2+2) where a 3×3 grid gives every window the same size.
  func testNineSessionsMakeAThreeByThreeGrid() {
    let area = CGRect(x: 0, y: 0, width: 637, height: 820)
    XCTAssertEqual(Tiling.evenRows(count: 9, in: area), [3, 3, 3])
    let frames = even("abcdefghi", area).frames
    XCTAssertEqual(frames.count, 9)
    XCTAssertEqual(Set(frames.values.map(\.size)), [CGSize(width: 207, height: 268)])
  }

  // Bug: rows of very different lengths (4+1) instead of lengths at most one apart, longer first.
  func testRowLengthsStayWithinOne() {
    XCTAssertEqual(Tiling.evenRows(count: 5, in: CGRect(x: 0, y: 0, width: 768, height: 300)), [3, 2])
    XCTAssertEqual(Tiling.evenRows(count: 1, in: CGRect(x: 0, y: 0, width: 300, height: 300)), [1])
  }

  // Bug: a window let under 112×78, or one refused at exactly 112×78.
  func testMinimumWindowBoundary() {
    XCTAssertEqual(Tiling.evenRows(count: 2, in: CGRect(x: 0, y: 0, width: 232, height: 78)), [2])
    XCTAssertNil(Tiling.evenRows(count: 2, in: CGRect(x: 0, y: 0, width: 230, height: 78)))
    XCTAssertNil(Tiling.evenRows(count: 2, in: CGRect(x: 0, y: 0, width: 232, height: 77)))
  }

  // MARK: The shelf

  func testEverythingThatFitsGetsAWindow() {
    let layout = even("abcd", CGRect(x: 0, y: 0, width: 232, height: 164))
    XCTAssertEqual(layout.shelf, [])
    XCTAssertEqual(layout.frames["d"], CGRect(x: 120, y: 86, width: 112, height: 78))
  }

  // Bug: a fifth session shrunk under 112×78 instead of shelved, or the shelf drawn over the windows.
  func testWhatDoesNotFitGoesToTheShelfUnderTheWindows() {
    // Four fit in 232×164; five need the shelf, whose 36 + 8 pt leave one row of 120.
    let layout = even("abcde", CGRect(x: 0, y: 0, width: 232, height: 164))
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 112, height: 120), "b": CGRect(x: 120, y: 0, width: 112, height: 120)])
    XCTAssertEqual(layout.shelf, ["c", "d", "e"], "the last in swipe order leave first, and the shelf keeps swipe order")
    XCTAssertEqual(layout.chips, ["c": CGRect(x: 0, y: 128, width: 60, height: 36), "d": CGRect(x: 68, y: 128, width: 60, height: 36),
                                  "e": CGRect(x: 136, y: 128, width: 60, height: 36)])
  }

  // Bug: chips running off the panel's edge, or a second row of chips drawn over the windows.
  func testChipsWrapIntoRowsThatTakeTheirHeightFromTheWindows() {
    let area = CGRect(x: 0, y: 0, width: 232, height: 250)
    // Chips 60 wide share one row: four windows still fit above it.
    XCTAssertEqual(even("abcdefg", area).frames.count, 4)
    // Two chips 100 wide fill a row: the third wraps, and the rows leave room for two windows.
    let layout = even("abcdefg", area, chip: 100)
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 112, height: 118), "b": CGRect(x: 120, y: 0, width: 112, height: 118)])
    XCTAssertEqual(layout.chips, ["c": CGRect(x: 0, y: 126, width: 100, height: 36), "d": CGRect(x: 108, y: 126, width: 100, height: 36),
                                  "e": CGRect(x: 0, y: 170, width: 100, height: 36), "f": CGRect(x: 108, y: 170, width: 100, height: 36),
                                  "g": CGRect(x: 0, y: 214, width: 100, height: 36)])
  }

  // Bug: sessions vanishing when not even one window fits.
  func testNoRoomPutsEverySessionOnTheShelf() {
    let layout = even("ab", CGRect(x: 0, y: 0, width: 100, height: 50))
    XCTAssertEqual(layout.frames, [:])
    XCTAssertEqual(layout.shelf, ["a", "b"])
    XCTAssertEqual(Set(layout.chips.keys), ["a", "b"])
    XCTAssertEqual(even("", CGRect(x: 0, y: 0, width: 400, height: 400)), Tiling.Layout())
  }

  // Bug: in the user's tiling, the first window shelved, or every window shrunk under the floor, when a row runs out of room.
  func testTheUsersTilingShelvesTheLastWindowThatIsTooSmall() {
    let row = across((0.25, w("a")), (0.25, w("b")), (0.25, w("c")), (0.25, w("d")))
    let layout = layout(row, CGRect(x: 0, y: 0, width: 360, height: 400))
    XCTAssertEqual(layout.shelf, ["d"])
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 115, height: 356), "b": CGRect(x: 123, y: 0, width: 115, height: 356),
                                   "c": CGRect(x: 246, y: 0, width: 114, height: 356)])
  }

  // Bug: a parked session drawn as a sliver window, or taking room from the others.
  func testAParkedSessionIsAChipAndTakesNoRoom() {
    let layout = layout(across((0.5, w("a")), (0.5, w("b")), (0, w("c"))), CGRect(x: 0, y: 0, width: 600, height: 400))
    XCTAssertEqual(layout.shelf, ["c"])
    XCTAssertEqual(layout.frames, ["a": CGRect(x: 0, y: 0, width: 296, height: 356), "b": CGRect(x: 304, y: 0, width: 296, height: 356)])
  }

  // Bug: a parked session in the middle of a row taking a gap, so a window that fits is shelved in its place.
  func testAParkedSessionTakesNoGapEither() {
    // Without p's gap a and b are (236 - 8) / 2 = 114 wide; with it they would be 110.
    let layout = layout(across((0.5, w("a")), (0, w("p")), (0.5, w("b"))), CGRect(x: 0, y: 0, width: 236, height: 400))
    XCTAssertEqual(layout.shelf, ["p"])
    XCTAssertEqual(layout.frames["a"]?.width, 114)
    XCTAssertEqual(layout.frames["b"]?.width, 114)
  }

  // Bug: another window's sessions dropped, or shown before this window's shelf.
  func testOtherWindowsSessionsFollowTheShelf() {
    let layout = Tiling.layout(across((0.5, w("a")), (0.5, w("b")), (0, w("c"))), others: ["x"],
                               in: CGRect(x: 0, y: 0, width: 600, height: 400), chipWidth: chips(60))
    XCTAssertEqual(layout.shelf, ["c", "x"])
    XCTAssertEqual(layout.chips["x"], CGRect(x: 68, y: 364, width: 60, height: 36))
  }

  // MARK: Resizing

  private let three = CGRect(x: 0, y: 0, width: 600, height: 400)
  private var row: Tree { across((1.0 / 3, w("a")), (1.0 / 3, w("b")), (1.0 / 3, w("c"))) }

  private func border(between a: String, _ b: String, in layout: Tiling.Layout<String>) throws -> Tiling.Border {
    let frames = layout.frames
    return try XCTUnwrap(layout.borders.first { border in
      guard let fa = frames[a], let fb = frames[b] else { return false }
      return border.axis == .across ? abs(border.rect.minX - fa.maxX) < 1 && abs(border.rect.maxX - fb.minX) < 1
        : abs(border.rect.minY - fa.maxY) < 1 && abs(border.rect.maxY - fb.minY) < 1
    })
  }

  // Bug: a border drag that resizes every window, or none.
  func testDraggingABorderTradesRoomBetweenTheTwoBesideIt() throws {
    let border = try border(between: "a", "b", in: layout(row, three))
    let resized = Tiling.resizing(row, at: border, to: 250)
    XCTAssertEqual(layout(resized, three).frames, [
      "a": CGRect(x: 0, y: 0, width: 250, height: 400), "b": CGRect(x: 258, y: 0, width: 140, height: 400),
      "c": CGRect(x: 406, y: 0, width: 194, height: 400),
    ])
  }

  // Bug: a border dragged past the floor squeezing a window under 112 pt (or shelving it).
  func testABorderStopsWhereAWindowWouldGoUnderTheFloor() throws {
    let border = try border(between: "a", "b", in: layout(row, three))
    func width(at position: CGFloat, _ id: String) -> CGFloat? {
      layout(Tiling.resizing(row, at: border, to: position), three).frames[id]?.width
    }
    // b ends at 398: a may end anywhere from 112 to 398 - 8 - 112 = 278.
    XCTAssertEqual(width(at: 277, "b"), 113)
    XCTAssertEqual(width(at: 278, "b"), 112)
    XCTAssertEqual(width(at: 279, "b"), 112)
    XCTAssertEqual(width(at: 600, "b"), 112)
    XCTAssertEqual(width(at: 111, "a"), 112)
    XCTAssertEqual(width(at: -50, "a"), 112)
  }

  // Bug: resizing a group of windows re-evening the windows inside it (Tern keeps their proportions).
  func testResizingAGroupKeepsItsWindowsProportions() throws {
    let tree = across((0.5, w("a")), (0.5, down((0.25, w("b")), (0.75, w("c")))))
    let before = layout(tree, three)
    XCTAssertEqual(before.frames["b"]?.height, 98)
    let resized = layout(Tiling.resizing(tree, at: try border(between: "a", "b", in: before), to: 400), three)
    XCTAssertEqual(resized.frames["a"]?.width, 400)
    XCTAssertEqual(resized.frames["b"], CGRect(x: 408, y: 0, width: 192, height: 98))
    XCTAssertEqual(resized.frames["c"], CGRect(x: 408, y: 106, width: 192, height: 294))
  }

  // Bug: a touch just beside a gap missing its border (or one deeper into a window taking it), or the wrong border where two meet.
  func testABordersTouchZoneReachesTenPointsIntoEachSide() throws {
    // The even 2×2 grid: a horizontal gap at y 196–204, vertical gaps at x 296–304 in each row.
    let borders = layout(grid, three).borders
    func axis(_ x: CGFloat, _ y: CGFloat) -> Tiling.Axis? { Tiling.border(at: CGPoint(x: x, y: y), in: borders)?.axis }
    XCTAssertEqual(axis(300, 100), .across)
    XCTAssertEqual(axis(286, 100), .across)
    XCTAssertNil(axis(285.5, 100))
    XCTAssertEqual(axis(313.5, 100), .across)
    XCTAssertNil(axis(314, 100))
    XCTAssertEqual(axis(100, 186), .down)
    XCTAssertNil(axis(100, 185.5))
    XCTAssertEqual(axis(100, 213.5), .down)
    XCTAssertNil(axis(100, 214))
    // Where the zones cross, the nearer gap's middle wins.
    XCTAssertEqual(axis(292, 189), .across, "8 pt from the vertical gap's middle, 11 from the horizontal one's")
    XCTAssertEqual(axis(310, 199), .down, "10 pt from the vertical gap's middle, 1 from the horizontal one's")
    let lower = try XCTUnwrap(Tiling.border(at: CGPoint(x: 300, y: 300), in: borders))
    XCTAssertEqual(lower.rect, CGRect(x: 296, y: 204, width: 8, height: 196), "the bottom row's own border")
  }

  // MARK: Evening out

  // Bug: evening out leaving the sizes the user dragged, or reshaping the tiling.
  func testEveningOutGivesEverySplitEqualParts() {
    let tree = across((0.6, w("a")), (0.4, down((0.2, w("b")), (0.8, w("c")))))
    XCTAssertEqual(tree.equalized(), across((0.5, w("a")), (0.5, down((0.5, w("b")), (0.5, w("c"))))))
  }

  // Bug: windows split one after another along a row evening out to 1/2, 1/4, 1/4 instead of thirds (as Tern does).
  func testARowBuiltBySplittingEvensOutToEqualThirds() {
    let tree = w("a").placing("b", beside: "a", on: .right).placing("c", beside: "b", on: .right)
    XCTAssertEqual(tree.windows, ["a", "b", "c"])
    let frames = layout(tree.equalized(), three).frames
    XCTAssertEqual(frames["a"]?.width, 195)
    XCTAssertEqual(frames["b"]?.width, 195)
    XCTAssertEqual(frames["c"]?.width, 194)
  }

  // Bug: a parked session staying parked when everything is evened out though there is room.
  func testEveningOutBringsAParkedSessionBackWhenItFits() {
    let tree = across((0.5, w("a")), (0.5, w("b")), (0, w("c"))).equalized()
    XCTAssertEqual(layout(tree, three).shelf, [])
  }

  // Bug: evening out a tiling into exactly the even one but keeping it fixed (so the keyboard or a rotation no longer
  // re-picks the rows), or evening out one the user arranged into the even rows, losing the arrangement.
  func testEveningOutIntoTheEvenTilingMakesItEvenAgain() {
    func evenedOut(_ tree: Tree) -> Tree? { Tiling.evenedOut(tree, in: three, chipWidth: chips(60)) }
    XCTAssertNil(evenedOut(across((0.5, w("a")), (0.2, w("b")), (0.3, w("c")))))
    XCTAssertNil(evenedOut(down((0.5, across((0.7, w("a")), (0.3, w("b")))), (0.5, across((0.5, w("c")), (0.5, w("d")))))))
    XCTAssertEqual(evenedOut(across((0.7, w("a")), (0.3, down((0.2, w("b")), (0.8, w("c")))))),
                   across((0.5, w("a")), (0.5, down((0.5, w("b")), (0.5, w("c"))))))
  }

  // MARK: Dropping

  // Bug: a drop on a window's middle splitting it, or a drop near an edge swapping.
  func testDropZones() {
    let frames = ["a": CGRect(x: 0, y: 0, width: 200, height: 100), "b": CGRect(x: 300, y: 0, width: 200, height: 100)]
    func drop(_ x: CGFloat, _ y: CGFloat) -> Tiling.Drop<String>? { Tiling.drop(at: CGPoint(x: x, y: y), lifted: "b", frames: frames) }
    XCTAssertEqual(drop(100, 50), .swap("a"))
    XCTAssertEqual(drop(50, 50), .swap("a"), "a quarter in from the edge is still the middle")
    XCTAssertEqual(drop(49, 50), .split("a", .left))
    XCTAssertEqual(drop(190, 50), .split("a", .right))
    XCTAssertEqual(drop(100, 5), .split("a", .top))
    XCTAssertEqual(drop(100, 95), .split("a", .bottom))
    XCTAssertNil(drop(400, 50), "over the lifted window itself")
    XCTAssertNil(drop(250, 50), "over no window")
  }

  private var grid: Tree { down((0.5, across((0.5, w("a")), (0.5, w("b")))), (0.5, across((0.5, w("c")), (0.5, w("d"))))) }

  // Bug: a drop on a window's side within its row halving that window (sizes the user did not choose) instead of the
  // row sharing evenly, or the window landing on the wrong side or out of swipe order.
  func testADropOnAnEdgeAlongARowTakesAnEqualShareOfIt() {
    let third = 1.0 / 3
    let left = Tiling.dropping("d", .split("a", .left), in: grid)
    XCTAssertEqual(left, down((0.5, across((third, w("d")), (third, w("a")), (third, w("b")))), (0.5, w("c"))))
    XCTAssertEqual(left.windows, ["d", "a", "b", "c"])
    let right = Tiling.dropping("d", .split("b", .right), in: grid)
    XCTAssertEqual(right.windows, ["a", "b", "d", "c"])
    XCTAssertEqual(["a", "b", "d"].map { layout(right, three).frames[$0]?.width }, [195, 195, 194])
    let column = across((0.5, w("a")), (0.5, down((0.5, w("b")), (0.5, w("c")))))
    XCTAssertEqual(Tiling.dropping("a", .split("c", .bottom), in: column), down((third, w("b")), (third, w("c")), (third, w("a"))))
  }

  // Bug: a drop on a window's side across its row not splitting that window there, or leaving the swipe order behind.
  func testADropOnAnEdgeAcrossARowHalvesTheTarget() {
    let below = Tiling.dropping("d", .split("a", .bottom), in: grid)
    XCTAssertEqual(below, down((0.5, across((0.5, down((0.5, w("a")), (0.5, w("d")))), (0.5, w("b")))), (0.5, w("c"))))
    XCTAssertEqual(below.windows, ["a", "d", "b", "c"])
    XCTAssertEqual(Tiling.dropping("b", .split("a", .top), in: across((0.5, w("a")), (0.5, w("b")))),
                   down((0.5, w("b")), (0.5, w("a"))), "a lone window left is split in half")
  }

  // Bug: a swap that moves other windows, or does not change the swipe order.
  func testADropOnTheMiddleSwapsTheTwo() {
    let swapped = Tiling.dropping("d", .swap("a"), in: grid)
    XCTAssertEqual(swapped, down((0.5, across((0.5, w("d")), (0.5, w("b")))), (0.5, across((0.5, w("c")), (0.5, w("a"))))))
    XCTAssertEqual(swapped.windows, ["d", "b", "c", "a"])
    XCTAssertEqual(Tiling.dropping("a", .swap("a"), in: grid), grid)
  }

  // Bug: a window let go on the shelf keeping its room, taking its split's room with it, or not ending the swipe order.
  func testAWindowParkedOnTheShelfLeavesItsRoomToItsSplit() {
    let parked = Tiling.parking("a", in: across((0.5, w("a")), (0.3, w("b")), (0.2, w("c"))))
    XCTAssertEqual(parked, across((0.6, w("b")), (0.4, w("c")), (0, w("a"))))
    let fromGrid = Tiling.parking("b", in: grid)
    XCTAssertEqual(fromGrid?.windows, ["a", "c", "d", "b"])
    let shown = layout(fromGrid, three)
    XCTAssertEqual(shown.shelf, ["b"])
    XCTAssertEqual(shown.frames["a"], CGRect(x: 0, y: 0, width: 600, height: 174))
    XCTAssertNil(Tiling.parking("a", in: w("a")), "the only session has nowhere to leave room")
  }

  // MARK: Sessions arriving and leaving

  private func reconciled(_ tree: Tree?, _ order: String, _ area: CGRect) -> Tree? {
    Tiling.reconciled(tree, order: ids(order), in: area, chipWidth: chips(60))
  }

  // Bug: a closed session's room going to one neighbour (or nowhere) instead of its split's others in proportion.
  func testAClosedSessionsRoomIsSharedInProportion() {
    XCTAssertEqual(across((0.5, w("a")), (0.25, w("b")), (0.25, w("c"))).removing("a"), across((0.5, w("b")), (0.5, w("c"))))
    XCTAssertEqual(grid.removing("b"), down((0.5, w("a")), (0.5, across((0.5, w("c")), (0.5, w("d"))))))
  }

  // Bug: a row left inside a row by a closed session evening out to 1/2, 1/4, 1/4 instead of thirds.
  func testARowLeftInsideARowMergesIntoIt() {
    let tree = across((0.5, w("a")), (0.5, down((0.5, w("b")), (0.5, across((0.5, w("c")), (0.5, w("d")))))))
    let left = tree.removing("b")
    XCTAssertEqual(left, across((0.5, w("a")), (0.25, w("c")), (0.25, w("d"))))
    XCTAssertEqual(left?.equalized(), across((1.0 / 3, w("a")), (1.0 / 3, w("c")), (1.0 / 3, w("d"))))
  }

  // Bug: a new session landing away from the one before it in swipe order, or not getting an even share.
  func testANewSessionJoinsTheSplitOfTheOneBeforeIt() throws {
    let tree = try XCTUnwrap(reconciled(across((0.5, w("a")), (0.5, w("b"))), "acb", three))
    XCTAssertEqual(tree.windows, ["a", "c", "b"])
    let frames = layout(tree, three).frames
    XCTAssertEqual(frames["a"]?.width, 195)
    XCTAssertEqual(frames["c"]?.width, 195)
    XCTAssertEqual(frames["b"]?.width, 194)
  }

  // Bug: a fourth session squeezed into a full row (shelving a window) when splitting the one before it fits.
  func testANewSessionSplitsTheOneBeforeItWhenItsRowIsFull() throws {
    let area = CGRect(x: 0, y: 0, width: 360, height: 400)
    let tree = try XCTUnwrap(reconciled(row, "abcd", area))
    let layout = layout(tree, area)
    XCTAssertEqual(layout.shelf, [])
    XCTAssertEqual(layout.frames["c"], CGRect(x: 246, y: 0, width: 114, height: 196))
    XCTAssertEqual(layout.frames["d"], CGRect(x: 246, y: 204, width: 114, height: 196))
  }

  // Bug: a new session with no room anywhere pushing an older one to the shelf.
  func testANewSessionWithNoRoomIsParked() throws {
    let area = CGRect(x: 0, y: 0, width: 360, height: 160)
    let layout = layout(try XCTUnwrap(reconciled(row, "abcd", area)), area)
    XCTAssertEqual(layout.shelf, ["d"])
    XCTAssertEqual(Set(layout.frames.keys), ["a", "b", "c"])
  }

  // Bug: the keyboard rising re-evening the sizes the user set.
  func testTheKeyboardKeepsTheUsersProportions() {
    let tree = across((0.7, w("a")), (0.3, w("b")))
    let short = CGRect(x: 0, y: 0, width: 600, height: 200)
    XCTAssertEqual(reconciled(tree, "ab", short), tree)
    XCTAssertEqual(layout(tree, three).frames["a"]?.width, 414)
    XCTAssertEqual(layout(tree, short).frames["a"], CGRect(x: 0, y: 0, width: 414, height: 200))
  }

  // Bug: a session moved in the swipe order (VoiceOver's Move Earlier) taking its old window's size along, or the tiling losing its shape.
  func testTheSwipeOrderFillsTheSameWindows() {
    XCTAssertEqual(reconciled(across((0.7, w("a")), (0.3, w("b"))), "ba", three), across((0.7, w("b")), (0.3, w("a"))))
  }

  // Bug: a tiling of one session staying the user's, so sessions opened later are not laid out evenly.
  func testOneSessionLeftMakesTheTilingEvenAgain() {
    XCTAssertNil(reconciled(across((0.7, w("a")), (0.3, w("b"))), "a", three))
    XCTAssertNil(reconciled(across((0.7, w("a")), (0.3, w("b"))), "", three))
    XCTAssertNil(reconciled(nil, "abc", three))
  }

  // Bug: shaping an even tiling for the first time throwing shelved sessions into windows or moving windows.
  func testShapingTheEvenTilingStartsFromWhatShows() throws {
    let area = CGRect(x: 0, y: 0, width: 232, height: 250)
    let tree = try XCTUnwrap(Tiling.evenTree(ids("abcdefg"), in: area, chipWidth: chips(100)))
    let shown = layout(tree, area, chip: 100)
    XCTAssertEqual(reconciled(tree, "abcdefg", area), tree)
    let border = try XCTUnwrap(shown.borders.first)
    let shaped = Tiling.resizing(tree, at: border, to: border.rect.minX)
    XCTAssertEqual(layout(shaped, area, chip: 100), shown)
  }

  // MARK: Saved tilings

  // Bug: a tiling saved for relaunch coming back with other splits or shares.
  func testATilingSurvivesEncoding() throws {
    let tree = down((0.4, across((0.25, w("a")), (0.75, w("b")))), (0.6, across((1, w("c")), (0, w("d")))))
    let data = try JSONEncoder().encode(tree)
    XCTAssertEqual(try JSONDecoder().decode(Tree.self, from: data), tree)
  }

  // Bug: a saved tiling for sessions that did not all come back (and a smaller panel) leaving holes or windows under the floor.
  func testASavedTilingDegradesToTheSessionsThatCameBack() throws {
    let area = CGRect(x: 0, y: 0, width: 360, height: 300)
    let tree = try XCTUnwrap(reconciled(grid, "ace", area))
    XCTAssertEqual(tree.windows, ["a", "c", "e"])
    let layout = layout(tree, area)
    XCTAssertEqual(layout.shelf, [])
    XCTAssertEqual(layout.frames.count, 3)
    XCTAssertTrue(layout.frames.values.allSatisfy { $0.width >= 112 && $0.height >= 78 })
  }

  // Bug: a damaged saved tiling (a session twice) shown as is.
  func testADamagedTilingFallsBackToEven() {
    XCTAssertNil(reconciled(across((0.5, w("a")), (0.5, w("a"))), "a", three))
    XCTAssertNil(reconciled(across((0.5, w("a")), (0.5, w("a"))), "ab", three))
  }
}
