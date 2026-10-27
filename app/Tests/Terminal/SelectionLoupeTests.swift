import UIKit
import XCTest
@testable import Term

/// The loupe over a dragged selection: a long press that only selected a
/// word shows none until the finger starts extending it, a handle shows it
/// at once, and lifting (or clearing the selection) removes it.
@MainActor
final class SelectionLoupeTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() async throws {
    await MainActor.run { window?.isHidden = true; window = nil }
  }

  private func view() throws -> UIView {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let w = UIWindow(windowScene: scene)
    w.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
    let v = UIView(frame: w.bounds)
    w.addSubview(v)
    w.isHidden = false
    window = w
    return v
  }

  private let caret = CGRect(x: 100, y: 100, width: 2, height: 20)

  func testTheFingerMustLeaveTheSlopBeforeAPressShowsTheLoupe() {
    let origin = CGPoint(x: 50, y: 50)
    XCTAssertFalse(SelectionLoupe.hasLeft(origin, for: CGPoint(x: 55.9, y: 50)))
    XCTAssertTrue(SelectionLoupe.hasLeft(origin, for: CGPoint(x: 56, y: 50)))
    XCTAssertTrue(SelectionLoupe.hasLeft(origin, for: CGPoint(x: 54.3, y: 54.3)), "diagonal: 6.08 pt away")
    XCTAssertFalse(SelectionLoupe.hasLeft(origin, for: CGPoint(x: 53, y: 54)), "5 pt away")
  }

  func testAWordSelectedByAPressShowsNoLoupeUntilTheFingerMoves() throws {
    let v = try view(), loupe = SelectionLoupe()
    loupe.arm(at: CGPoint(x: 50, y: 50))
    loupe.move(to: CGPoint(x: 52, y: 50), caret: caret, in: v)
    XCTAssertFalse(loupe.isShowing, "a stationary press popped a loupe")
    loupe.move(to: CGPoint(x: 70, y: 50), caret: caret, in: v)
    XCTAssertTrue(loupe.isShowing)
    loupe.end()
    XCTAssertFalse(loupe.isShowing, "the loupe outlived the touch")
  }

  func testAHandleShowsTheLoupeAtOnce() throws {
    let v = try view(), loupe = SelectionLoupe()
    loupe.move(to: CGPoint(x: 50, y: 50), caret: caret, in: v)
    XCTAssertTrue(loupe.isShowing)
    loupe.end()
    XCTAssertFalse(loupe.isShowing)
  }

  func testANewPressDropsTheLoupeOfThePreviousOne() throws {
    let v = try view(), loupe = SelectionLoupe()
    loupe.move(to: CGPoint(x: 50, y: 50), caret: caret, in: v)
    loupe.arm(at: CGPoint(x: 10, y: 10))
    XCTAssertFalse(loupe.isShowing)
  }
}

/// A pan whose state and finger position the test dictates, handed to the
/// terminal's own handle-drag action: the same code path a real drag takes,
/// without the touch synthesis UIKit does not offer to a unit test.
private final class ScriptedPan: UIPanGestureRecognizer {
  var scriptedState: UIGestureRecognizer.State = .possible
  var finger = CGPoint.zero
  override var state: UIGestureRecognizer.State {
    get { scriptedState }
    set {}
  }
  override func location(in view: UIView?) -> CGPoint { finger }
}

/// Dragging either selection handle of the real terminal view drives the
/// loupe, and the selection edge follows the finger.
@MainActor
final class SelectionHandleLoupeTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() async throws {
    await MainActor.run { window?.isHidden = true; window = nil }
  }

  private func selectedTerminal(endCol: Int = 12) async throws -> TerminalView {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let w = UIWindow(windowScene: scene)
    w.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
    let session = try XCTUnwrap(Session(localCols: 20, rows: 5))
    let view = TerminalView(session: session)
    view.frame = w.bounds
    w.addSubview(view)
    w.isHidden = false
    window = w
    view.layoutIfNeeded()
    session.feed("alpha beta\r\ngamma delta\r\nepsilon zeta\r\neta theta\r\n")
    try await Task.sleep(for: .milliseconds(300))
    view.selection = (GridPoint(row: 1, col: 2), GridPoint(row: 1, col: endCol))
    view.updateHandles()
    return view
  }

  private func drag(_ handle: SelectionHandle, in view: TerminalView, from: CGPoint, to: CGPoint, check: () -> Void) {
    let pan = ScriptedPan(target: view, action: nil)
    handle.addGestureRecognizer(pan)
    for (state, point) in [(UIGestureRecognizer.State.began, from), (.changed, to)] {
      pan.scriptedState = state
      pan.finger = point
      view.perform(NSSelectorFromString("handleDragHandle:"), with: pan)
    }
    check()
    pan.scriptedState = .ended
    view.perform(NSSelectorFromString("handleDragHandle:"), with: pan)
  }

  func testTheEndHandleMovesTheSelectionEdgeAndTheLoupeFollowsIt() async throws {
    let view = try await selectedTerminal()
    let knob = CGPoint(x: view.endHandle.frame.midX, y: view.endHandle.frame.maxY - 10)
    XCTAssertTrue(view.hitTest(knob, with: nil)?.isDescendant(of: view.endHandle) == true)
    let cell = view.rect(col: 9, row: 3)
    let target = CGPoint(x: cell.midX, y: cell.midY + view.cellSizePoints.height / 2)
    drag(view.endHandle, in: view, from: knob, to: target) {
      XCTAssertTrue(view.selectionLoupe.isShowing, "no loupe while the end handle is dragged")
      XCTAssertEqual(view.selection?.start, GridPoint(row: 1, col: 2))
      XCTAssertEqual(view.selection?.end, GridPoint(row: 3, col: 9))
      let looking = view.selectionLoupe.lookingAt
      XCTAssertEqual(looking?.x ?? 0, target.x, accuracy: 0.5)
      XCTAssertEqual(looking?.y ?? 0, cell.midY, accuracy: 0.5, "the loupe looks at the aimed line, not under the finger")
    }
    XCTAssertFalse(view.selectionLoupe.isShowing, "the loupe outlived the drag")
  }

  func testTheStartHandleMovesTheSelectionEdgeAndTheLoupeFollowsIt() async throws {
    let view = try await selectedTerminal()
    let knob = CGPoint(x: view.startHandle.frame.midX, y: view.startHandle.frame.minY + 10)
    XCTAssertTrue(view.hitTest(knob, with: nil)?.isDescendant(of: view.startHandle) == true)
    let cell = view.rect(col: 1, row: 0)
    let target = CGPoint(x: cell.midX, y: cell.midY - view.cellSizePoints.height / 2)
    drag(view.startHandle, in: view, from: knob, to: target) {
      XCTAssertTrue(view.selectionLoupe.isShowing, "no loupe while the start handle is dragged")
      XCTAssertEqual(view.selection?.start, GridPoint(row: 0, col: 1))
      XCTAssertEqual(view.selection?.end, GridPoint(row: 1, col: 12))
      XCTAssertEqual(view.selectionLoupe.lookingAt?.y ?? 0, cell.midY, accuracy: 0.5)
    }
    XCTAssertFalse(view.selectionLoupe.isShowing)
  }

  func testAShortSelectionsHandlesAreEachGrabbable() async throws {
    let view = try await selectedTerminal(endCol: 4)
    XCTAssertLessThan(view.endHandle.frame.midX - view.startHandle.frame.midX, 44, "the frames must overlap for this to test anything")
    let startKnob = CGPoint(x: view.startHandle.frame.midX, y: view.startHandle.frame.minY + 10)
    let endKnob = CGPoint(x: view.endHandle.frame.midX, y: view.endHandle.frame.maxY - 10)
    XCTAssertTrue(view.hitTest(startKnob, with: nil)?.isDescendant(of: view.startHandle) == true, "the start handle's knob is covered by the end handle")
    XCTAssertTrue(view.hitTest(endKnob, with: nil)?.isDescendant(of: view.endHandle) == true)
  }
}
