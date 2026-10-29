import UIKit
import XCTest
@testable import Term

/// The rail on a terminal: where its track and dots go, and which touches
/// at the right edge are the rail's and which stay the Sessions double tap's.
@MainActor
final class MessageRailViewTests: XCTestCase {
  private var window: UIWindow?
  private var stub: Stub?

  override func tearDown() async throws {
    window?.isHidden = true
    window = nil
    stub = nil
  }

  // MARK: - Layout

  // Bug: the newest mark sat in the bottom corner, hard to see and press (the user asked for at least 1.5 cm).
  func testTheTrackEndsOneAndAHalfCentimetresAboveThePanesBottomOnTheDuo() {
    // The Duo (iPhone19,4) shows 460 pixels per inch at 3x: 1.5 cm = 1.5 / 2.54 × 460 / 3 = 90.55 pt.
    let perCentimetre = ScreenDensity.pointsPerCentimetre(model: "iPhone19,4", scale: 3)
    XCTAssertEqual(perCentimetre, 60.367, accuracy: 0.001)
    let layout = RailLayout(paneTop: 17, paneBottom: 951, right: 669, pointsPerCentimetre: perCentimetre)
    XCTAssertEqual(layout.paneBottom - layout.trackBottom, 91)
    XCTAssertEqual(layout.y(1), 860, "the newest line maps to the track's end")
    XCTAssertEqual(layout.y(0), 21)
    XCTAssertTrue(layout.isLive(900))
    XCTAssertFalse(layout.isLive(860))
    XCTAssertFalse(layout.isLive(952), "below the pane is not the rail's")
    XCTAssertEqual(layout.strip, CGRect(x: 645, y: 17, width: 24, height: 934))
  }

  // Bug: a phone whose density is unknown got a gap shorter than 1.5 cm.
  func testAnUnknownPhoneGetsTheDensestPointsSoTheGapIsNeverShort() {
    // 163 points per inch: 1.5 / 2.54 × 163 = 96.26 pt.
    let layout = RailLayout(paneTop: 0, paneBottom: 500, right: 390,
                            pointsPerCentimetre: ScreenDensity.pointsPerCentimetre(model: "iPhone99,1", scale: 3))
    XCTAssertEqual(layout.paneBottom - layout.trackBottom, 97)
  }

  // Bug: dots drawn on top of each other in a busy stretch, the unread one hidden under a read one.
  func testCloseDotsMergeShowingNeedsYouOverUnreadOverRead() {
    typealias Dot = RailLayout.Dot
    let groups = RailLayout.groups([
      Dot(id: "a", y: 100, unread: false, needsYou: false), Dot(id: "b", y: 103, unread: true, needsYou: false),
      Dot(id: "c", y: 104.9, unread: false, needsYou: false), Dot(id: "d", y: 105, unread: false, needsYou: false),
      Dot(id: "e", y: 200, unread: false, needsYou: false), Dot(id: "f", y: 202, unread: true, needsYou: false),
      Dot(id: "g", y: 203, unread: false, needsYou: true),
    ])
    XCTAssertEqual(groups.map(\.ids), [["a", "b", "c"], ["d"], ["e", "f", "g"]])
    XCTAssertEqual(groups.map(\.kind), [.unread, .read, .needsYou(unread: true)])
    XCTAssertEqual(groups.map(\.y), [103, 105, 203])
    XCTAssertEqual(groups.map(\.target), ["b", "d", "f"], "a tap takes the newest unread, else the newest")
  }

  // Bug: a tap between two marks took one far away, or a tap near one missed it.
  func testATapTakesTheNearestMarkWithinReach() {
    let groups = RailLayout.groups([RailLayout.Dot(id: "a", y: 100, unread: false, needsYou: false),
                                    RailLayout.Dot(id: "b", y: 140, unread: false, needsYou: false)])
    XCTAssertEqual(RailLayout.group(at: 118, in: groups)?.target, "a")
    XCTAssertEqual(RailLayout.group(at: 122, in: groups)?.target, "b")
    XCTAssertNil(RailLayout.group(at: 163, in: groups))
    XCTAssertEqual(RailLayout.group(at: 500, in: groups, reach: .infinity)?.target, "b")
  }

  // MARK: - Touches

  private final class FakeTap: TimedTapGestureRecognizer {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
  }

  private final class FakePress: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .began
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
      get { phase }
      set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
  }

  private final class Stub: TerminalViewDelegate {
    var doubleTaps = 0
    func terminalViewHasEdgeBand(_ view: TerminalView) -> Bool { true }
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

  /// The host of a pane with 100 lines of history under tmux's status line,
  /// two messages at lines 30 and 110; it records every command.
  private final class Host {
    var commands: [String] = []
    func exec(_ command: String) -> Data? {
      commands.append(command)
      if command.contains("show-options -pqv") {
        let list = #"{"v":1,"m":[{"i":"a","t":1792987200,"h":"First answer."},{"i":"b","t":1792987260,"h":"The fix is in."}]}"#
        return Data(["%1\t100\t19\t0\ton\t0\t", list, "", "30:First answer.\n110:The fix is in."].joined(separator: "\n\u{1E}\n").utf8)
      }
      if command.contains("goto-line") { return Data("jumped 100 72\n".utf8) }
      return Data()
    }
    var jumps: [String] { commands.filter { $0.contains("goto-line") } }
    var lives: [String] { commands.filter { $0.contains("cancel") && !$0.contains("goto-line") } }
  }

  /// A 320 pt terminal (its band: the right 57.6 pt) on a 30 × 20 grid showing that pane, its rail drawn.
  private func terminal() async throws -> (TerminalView, Host) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let session = try XCTUnwrap(Session(localCols: 30, rows: 20))
    let host = Host()
    session.rail = MessageRail(tmuxSession: "rail") { host.exec($0) }
    let view = TerminalView(session: session)
    let stub = Stub()
    view.delegate = stub
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    self.window = window
    self.stub = stub
    let deadline = Date.now.addingTimeInterval(3)
    while !view.railView.isActive, Date.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertTrue(view.railView.isActive, "the rail drew its marks")
    return (view, host)
  }

  private func tap(_ view: TerminalView, at point: CGPoint) {
    let tap = FakeTap()
    tap.point = point
    tap.touchTime = ProcessInfo.processInfo.systemUptime
    tap.liftTime = tap.touchTime
    view.perform(NSSelectorFromString("handleTap:"), with: tap)
  }

  private func y(_ view: TerminalView, of id: String) throws -> CGFloat {
    try XCTUnwrap(view.railView.groups.first { $0.ids.contains(id) }).y
  }

  // Bug: the rail's strip swallowing the Sessions double tap, or the band swallowing taps on the rail (the user's (a):
  // the rail owns the outermost 24 pt, the double tap keeps the rest of the band).
  func testTheRailOwnsTheOutermost24PointsAndTheBandKeepsTheRest() async throws {
    let (view, host) = try await terminal()
    let stub = try XCTUnwrap(stub)
    let ya = try y(view, of: "a")
    tap(view, at: CGPoint(x: 310, y: ya))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.jumps.count, 1)
    XCTAssertTrue(host.jumps.first?.contains("l=30") == true, host.jumps.first ?? "")
    tap(view, at: CGPoint(x: 290, y: ya))
    tap(view, at: CGPoint(x: 292, y: ya + 2))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub.doubleTaps, 1, "just inside the strip's edge is still the band")
    XCTAssertEqual(host.jumps.count, 1)
  }

  // Bug: a band tap followed by one on the rail opened Sessions instead of the mark.
  func testABandTapThenARailTapIsAJumpNotADoubleTap() async throws {
    let (view, host) = try await terminal()
    let yb = try y(view, of: "b")
    tap(view, at: CGPoint(x: 285, y: yb))
    tap(view, at: CGPoint(x: 312, y: yb))
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(stub?.doubleTaps, 0)
    XCTAssertTrue(host.jumps.first?.contains("l=110") == true, host.jumps.joined())
  }

  // Bug: with the rail off (Settings) its strip stayed dead instead of going back to the band.
  func testWithTheRailOffTheWholeBandIsTheDoubleTaps() async throws {
    let (view, host) = try await terminal()
    let ya = try y(view, of: "a")
    view.showsMessageRail = false
    XCTAssertFalse(view.railView.isActive)
    tap(view, at: CGPoint(x: 312, y: ya))
    tap(view, at: CGPoint(x: 313, y: ya))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(stub?.doubleTaps, 1)
    XCTAssertTrue(host.jumps.isEmpty)
  }

  // Bug: nothing took the user back to the live screen from the rail.
  func testATapBelowTheTrackGoesBackToLive() async throws {
    let (view, host) = try await terminal()
    let layout = try XCTUnwrap(view.railView.layout)
    tap(view, at: CGPoint(x: 312, y: layout.paneBottom - 10))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.lives.count, 1)
    XCTAssertTrue(host.jumps.isEmpty)
    XCTAssertEqual(stub?.doubleTaps, 0)
  }

  // Bug: the marks read on attach went stale, because attaching resizes the tmux window (not the phone's
  // grid) and omp then rewrites its history; the first jump took the slow stale path (1.6 s on the Duo simulator).
  func testShowingTheRailReadsItAgainOnceTheAttachHasSettled() async throws {
    let (view, host) = try await terminal()
    // Past the reads the first layout schedules.
    try await Task.sleep(for: .seconds(3.5))
    let reads = { host.commands.filter { $0.contains("show-options -pqv") }.count }
    let before = reads()
    // Shown again, as on entering the session, with the grid unchanged.
    view.showsMessageRail = false
    view.showsMessageRail = true
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(reads(), before + 1, "read on showing")
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertEqual(reads(), before + 2, "and again once settled")
  }

  // Bug: lifting after a slide opened the message where the press began, not the one the column showed.
  func testPressAndSlideOpensTheMessageUnderTheFingerWhenLifted() async throws {
    let (view, host) = try await terminal()
    let ya = try y(view, of: "a"), yb = try y(view, of: "b")
    let press = FakePress()
    press.point = CGPoint(x: 310, y: ya)
    view.perform(NSSelectorFromString("handleRailPress:"), with: press)
    press.phase = .changed
    press.point = CGPoint(x: 309, y: (ya + yb) / 2 + 30)
    view.perform(NSSelectorFromString("handleRailPress:"), with: press)
    XCTAssertTrue(host.jumps.isEmpty, "nothing moves while sliding")
    press.phase = .ended
    view.perform(NSSelectorFromString("handleRailPress:"), with: press)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.jumps.count, 1)
    XCTAssertTrue(host.jumps.first?.contains("l=110") == true, host.jumps.first ?? "")
  }

  // Bug: word selection starting on the rail, or the rail's press starting anywhere on the terminal.
  func testTheRailsPressBeginsOnlyInItsStripAndWordSelectionNeverThere() async throws {
    let (view, _) = try await terminal()
    let ya = try y(view, of: "a")
    let railPress = FakePress()
    railPress.name = "rail-press"
    view.addGestureRecognizer(railPress)
    let wordPress = FakePress()
    view.addGestureRecognizer(wordPress)
    railPress.point = CGPoint(x: 310, y: ya)
    wordPress.point = railPress.point
    XCTAssertTrue(view.gestureRecognizerShouldBegin(railPress))
    XCTAssertFalse(view.gestureRecognizerShouldBegin(wordPress))
    railPress.point = CGPoint(x: 150, y: ya)
    wordPress.point = railPress.point
    XCTAssertFalse(view.gestureRecognizerShouldBegin(railPress))
    XCTAssertTrue(view.gestureRecognizerShouldBegin(wordPress))
  }
}
