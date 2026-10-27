import XCTest
@testable import Term

/// Which engine drives the Mac, and what it is sent, as the host and
/// Screen Sharing report the Mac's state. Both engines are fakes that
/// record their input; everything else is the real session.
@MainActor
final class ScreenSessionTests: XCTestCase {
  /// What an engine was sent, comparable.
  enum Sent: Equatable {
    case pointer(Double, Double)
    case button(ScreenWire.MouseButton, down: Bool, x: Double, y: Double)
    case scroll
    case key(UInt16, down: Bool)
    case modifiers(ScreenWire.Modifiers)
    case text(String)
  }

  @MainActor
  final class FakeEngine: ScreenEngine {
    let onEvent: (ScreenEvent) -> Void
    var sent: [Sent] = []
    var watched: [[UInt32]] = []
    var closed = false

    init(_ onEvent: @escaping (ScreenEvent) -> Void) { self.onEvent = onEvent }

    func watch(_ displays: [UInt32]) { watched.append(displays) }
    func send(_ input: ScreenInput) {
      let entry: Sent = switch input {
      case .pointer(let p): .pointer(p.x, p.y)
      case .button(let button, let down, let p, _): .button(button, down: down, x: p.x, y: p.y)
      case .scroll: .scroll
      case .key(let code, let down): .key(code, down: down)
      case .modifiers(let held): .modifiers(held)
      case .text(let text): .text(text)
      }
      sent.append(entry)
    }
    func setClipboard(_ clipboard: ScreenWire.Clipboard) {}
    var qualities: [ScreenWire.QualityMode] = []
    func setQuality(_ mode: ScreenWire.QualityMode) { qualities.append(mode) }
    func layer(for display: UInt32) -> CALayer? { nil }
    func close() { closed = true }
  }

  // The user's Mac: the built-in display (main, 2x) and an ultrawide at 1x
  // to its right and above, as CGDisplayBounds and Screen Sharing report them.
  static let builtIn = ScreenWire.Display(id: 1, name: "Built-in Retina Display",
                                          frame: .init(x: 0, y: 0, width: 1728, height: 1117),
                                          pixelWidth: 3456, pixelHeight: 2234, isMain: true)
  static let external = ScreenWire.Display(id: 2, name: "Sceptre O34",
                                           frame: .init(x: 1728, y: -687, width: 3440, height: 1440),
                                           pixelWidth: 3440, pixelHeight: 1440, isMain: false)
  /// Screen Sharing's one framebuffer for both, measured on that Mac.
  static let framebuffer = ScreenWire.Display(id: 0, name: "Screen Sharing",
                                              frame: .init(x: 0, y: 0, width: 6896, height: 2921),
                                              pixelWidth: 6896, pixelHeight: 2921, isMain: true)

  private var session: ScreenSession!
  private var hosts: [FakeEngine] = []
  private var sharings: [FakeEngine] = []
  private let mac = Host(alias: "mac", hostname: "127.0.0.1", user: "user")

  private var host: FakeEngine { hosts.last! }
  private var sharing: FakeEngine { sharings.last! }

  override func setUp() async throws {
    continueAfterFailure = false
    Keychain.setMacPassword("saved", for: mac.id)
    session = ScreenSession(engines: ScreenEngines(
      host: { [unowned self] _, onEvent in
        let engine = FakeEngine(onEvent)
        hosts.append(engine)
        return engine
      },
      sharing: { [unowned self] _, _, onEvent in
        let engine = FakeEngine(onEvent)
        sharings.append(engine)
        return engine
      }))
    session.choose(mac)
    session.setSharedClipboard(false)
    session.setShown(true)
  }

  override func tearDown() async throws {
    session.disconnect()
    Keychain.setMacPassword(nil, for: mac.id)
  }

  private func welcome(locked: Bool = false, access: ScreenWire.Access = .init(screen: true, input: true)) {
    host.onEvent(.welcome(ScreenWire.Welcome(name: "Mac", displays: [Self.builtIn, Self.external], locked: locked,
                                            access: access, pointer: .init(x: 864, y: 558))))
  }

  /// Screen Sharing signs in: its framebuffer arrives.
  private func sharingSignsIn() {
    sharing.onEvent(.displays([Self.framebuffer]))
  }

  // MARK: Privacy grants

  // Bug: a host without Screen Recording leaving the user at a dead end
  // instead of Screen Sharing, through which they approve it on the Mac; or
  // the picture staying on Screen Sharing once the grant arrives.
  func testHostWithoutScreenAccessRunsScreenSharingUntilTheGrantArrives() {
    welcome(access: .init(screen: false, input: true))
    XCTAssertEqual(sharings.count, 1, "Screen Sharing starts")
    XCTAssertEqual(session.sharing, .signingIn)
    sharingSignsIn()
    XCTAssertEqual(session.sharing, .live)
    XCTAssertTrue(session.drivable, "the user can click through to System Settings")
    session.click(.left, at: CGPoint(x: 10, y: 20))
    XCTAssertEqual(sharing.sent.first, .button(.left, down: true, x: 10, y: 20))

    host.onEvent(.access(.init(screen: true, input: true)))
    XCTAssertEqual(session.sharing, .held, "back to the host, Screen Sharing idle")
    XCTAssertEqual(sharing.watched.last, [])
    XCTAssertEqual(host.watched.last, [1, 2], "the host streams both displays again")
  }

  // Bug: a host lacking Accessibility shows the Mac but can't click it: the
  // user could never reach System Settings to approve it.
  func testHostWithoutAccessibilityRunsScreenSharing() {
    welcome(access: .init(screen: true, input: false))
    XCTAssertEqual(session.sharing, .signingIn)
  }

  // Bug: approving Screen Recording restarts the host (Quit & Reopen); the
  // connection ending then dropped the user on "Connection lost" instead of
  // keeping Screen Sharing up and finding the host again on its own.
  func testHostRestartWhileLackingAccessKeepsScreenSharingAndReconnects() async throws {
    welcome(access: .init(screen: false, input: false))
    sharingSignsIn()
    host.onEvent(.closed(.ended("The host closed the connection.")))
    XCTAssertEqual(session.phase, .hostNotRunning)
    XCTAssertEqual(session.sharing, .live)
    try await Task.sleep(for: .seconds(5.5))
    XCTAssertEqual(hosts.count, 2, "a fresh host connection")
  }

  // MARK: Type User Password

  // Bug: on the lock screen a step missing from click, ⌘A, Delete, the
  // password, Return (the field takes keys only once clicked, and keeps what
  // an earlier attempt left); the click landing off the main display's
  // middle in Screen Sharing's framebuffer (the 2x and 1x displays sit there
  // at native pixels: 1728,1804, where a manual click unlocked this Mac); or
  // any of it going to Term Screen Host, which can't see the login window.
  func testTypeUserPasswordOnTheLockScreenClicksClearsAndTypesThroughScreenSharing() async throws {
    welcome()
    host.onEvent(.lock(true))
    XCTAssertEqual(session.sharing, .signingIn)
    sharingSignsIn()
    XCTAssertEqual(session.sharing, .live)
    let hostSent = host.sent

    session.savePassword("pässwörd 1", for: .type(withReturn: true))
    try await Task.sleep(for: .seconds(1))

    XCTAssertEqual(sharing.sent, [
      .button(.left, down: true, x: 1728, y: 1804),
      .button(.left, down: false, x: 1728, y: 1804),
      .modifiers(.command), .key(0x00, down: true), .key(0x00, down: false), .modifiers([]),  // ⌘A
      .key(0x33, down: true), .key(0x33, down: false),  // Delete
      .text("pässwörd 1"),
      .key(0x24, down: true), .key(0x24, down: false),  // Return
    ])
    XCTAssertEqual(host.sent, hostSent, "nothing reaches the host")
  }

  // Bug: the password typed into whatever engine drives the Mac after the
  // click's pause, when the Screen Sharing session that was clicked ended.
  func testPasswordIsNotTypedIntoAnotherSessionAfterTheClick() async throws {
    welcome()
    host.onEvent(.lock(true))
    sharingSignsIn()
    let clicked = sharing
    session.savePassword("secret", for: .type(withReturn: true))
    clicked.onEvent(.closed(.ended("closed")))
    session.startSharing()
    sharingSignsIn()
    try await Task.sleep(for: .seconds(1))
    XCTAssertFalse(sharing.sent.contains(.text("secret")))
    XCTAssertFalse(host.sent.contains(.text("secret")))
  }

  // MARK: Input ownership

  // Bug: a toolbar-latched ⌘ staying down on the Mac after the Screen hides,
  // changing what the Mac's own keyboard does after.
  func testLatchedModifierIsReleasedWhenTheScreenHides() {
    welcome()
    session.tapModifier(.command)
    XCTAssertEqual(host.sent.last, .modifiers(.command))
    session.setShown(false)
    XCTAssertEqual(host.sent.last, .modifiers([]))
    XCTAssertEqual(session.modifiers.held, [])
  }

  // Bug: a ⌘ latched through Screen Sharing staying down in that (still
  // open, idle) session after the Mac unlocks and the host takes over.
  func testLatchedModifierIsReleasedOnScreenSharingWhenTheHostTakesOver() {
    welcome()
    host.onEvent(.lock(true))
    sharingSignsIn()
    session.tapModifier(.command)
    XCTAssertEqual(sharing.sent.last, .modifiers(.command))
    host.onEvent(.lock(false))
    XCTAssertEqual(session.sharing, .held)
    XCTAssertEqual(sharing.sent.last, .modifiers([]))
    XCTAssertFalse(host.sent.contains(.modifiers(.command)))
  }

  // MARK: Pointer

  // Bug: every touch update sent as its own message, a backlog the Mac
  // replays late on a slow link; or a click sent ahead of the move before
  // it, landing where the pointer was a frame ago.
  func testPointerMovesGoOncePerFrameLatestFirstAndBeforeAClick() async throws {
    continueAfterFailure = true  // a failure that throws inside an async test hangs the runner
    welcome()
    let before = host.sent.count
    session.movePointer(to: CGPoint(x: 100, y: 100))
    session.movePointer(to: CGPoint(x: 110, y: 105))
    session.movePointer(to: CGPoint(x: 120, y: 110))
    XCTAssertEqual(session.pointer, CGPoint(x: 120, y: 110), "drawn at once")
    session.click(.left, at: CGPoint(x: 120, y: 110))
    XCTAssertEqual(Array(host.sent[before...]), [
      .pointer(120, 110),
      .button(.left, down: true, x: 120, y: 110),
      .button(.left, down: false, x: 120, y: 110),
    ])

    let afterClick = host.sent.count
    session.movePointer(to: CGPoint(x: 200, y: 150))
    session.movePointer(to: CGPoint(x: 210, y: 160))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(Array(host.sent[afterClick...]), [.pointer(210, 160)], "one message, the latest position")
  }

  // Bug: an edge swipe's two moves (one point short of the edge, then the
  // edge) coalesced into one, so the Mac saw no move reaching the edge and
  // a repeated swipe to the Dock revealed nothing.
  func testAnEdgeSwipeSendsTheMoveShortOfTheEdgeAndThenTheEdge() {
    welcome()  // the pointer at 864,558 on the built-in display
    let view = ScreenView(session: session)
    let before = host.sent.count
    view.jump(to: .bottom)
    session.flushPointer()
    XCTAssertEqual(Array(host.sent[before...]), [.pointer(864, 1115), .pointer(864, 1116)])
  }

  // Bug: the pointer's display link left paused in the run loop once the
  // moves stopped, with its target, after the window or the session closed.
  func testThePointerDisplayLinkEndsOnceTheMovesStop() async throws {
    continueAfterFailure = true  // a failure that throws inside an async test hangs the runner
    welcome()
    session.movePointer(to: CGPoint(x: 100, y: 100))
    XCTAssertNotNil(session.pointerFrame)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(host.sent.last, .pointer(100, 100))
    XCTAssertNil(session.pointerFrame, "no link once there is nothing to send")
  }

  // Bugs (the user's reports): the pointer not drawn at all until the Mac
  // sends a shape or when it sends none; then, floored at its size on the
  // Mac, drawn many times too big for a zoomed-out picture. It is the
  // picture's own size at every zoom.
  func testThePointerIsDrawnToThePicturesScaleAndNeverMissing() {
    welcome()
    XCTAssertEqual(session.cursor.size, CGSize(width: 16, height: 23), "the arrow before any shape")
    // As Term Screen Host sends this Mac's arrow: 64 px at 2 px per pt, hot spot 12,8 pt.
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: {
      let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
    }()).pngData { _ in UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
    host.onEvent(.cursor(ScreenWire.CursorImage(png: image, scale: 2, hotX: 12, hotY: 8)))
    XCTAssertEqual(session.cursor.drawnSize(at: 0.1), CGSize(width: 3.2, height: 3.2), "both displays fitted to a phone")
    XCTAssertEqual(session.cursor.drawnSize(at: 3), CGSize(width: 96, height: 96), "zoomed in, it grows with the picture")
    XCTAssertEqual(session.cursor.hotSpot, CGPoint(x: 12, y: 8))
    host.onEvent(.cursor(ScreenWire.CursorImage(png: Data(), scale: 1, hotX: 0, hotY: 0)))
    XCTAssertEqual(session.cursor.size, CGSize(width: 16, height: 23), "no shape: the arrow again")
  }

  // MARK: Displays

  // Bug: Built-in or the external display chosen under Screen Sharing still
  // showing the whole framebuffer (both displays), or the pointer left on
  // the one that no longer shows.
  func testOneDisplayUnderScreenSharingIsItsPartOfTheFramebuffer() {
    welcome(access: .init(screen: false, input: false))
    sharingSignsIn()
    session.showDisplay(Self.builtIn.id)
    // The built-in display at native pixels 687 px down, the external to its right at the top.
    XCTAssertEqual(session.shownDisplays.map(\.frame), [.init(x: 0, y: 687, width: 3456, height: 2234)])
    session.showDisplay(Self.external.id)
    XCTAssertEqual(session.shownDisplays.map(\.frame), [.init(x: 3456, y: 0, width: 3440, height: 1440)])
    XCTAssertTrue(CGRect(x: 3456, y: 0, width: 3440, height: 1440).contains(session.pointer), "the pointer moves onto it")
    session.flushPointer()
    guard case .pointer(let x, let y) = sharing.sent.last else { return XCTFail("the Mac's pointer was not moved") }
    XCTAssertTrue(CGRect(x: 3456, y: 0, width: 3440, height: 1440).contains(CGPoint(x: x, y: y)))
    session.showDisplay(nil)
    XCTAssertEqual(session.shownDisplays.map(\.frame), [Self.framebuffer.frame])
  }

  // Bug: Screen Sharing starting with its pointer drawn at the framebuffer's
  // middle while the Mac's is elsewhere, so the first drag jumps.
  func testScreenSharingStartsWithThePointerWhereTheHostSawIt() {
    welcome(access: .init(screen: false, input: false))  // the pointer at 864,558 pt: the built-in display's middle
    sharingSignsIn()
    XCTAssertEqual(session.pointer.x, 1728, accuracy: 0.01)
    XCTAssertEqual(session.pointer.y, 687 + 1116, accuracy: 0.01)
  }

  // MARK: Quality

  // Bug: the picked quality forgotten on the next connection, or never asked
  // of the host after its Welcome, so it streams at its default.
  func testQualityIsRememberedAndAskedOfEveryConnection() {
    welcome()
    XCTAssertEqual(host.qualities, [.adaptive])
    session.setQuality(.low)
    XCTAssertEqual(host.qualities.last, .low)
    host.onEvent(.quality(.init(mode: .low, level: .low)))
    XCTAssertEqual(session.quality, .init(mode: .low, level: .low))

    session.reconnect()
    XCTAssertNil(session.quality, "a new connection says its own")
    welcome()
    XCTAssertEqual(host.qualities, [.low])
    XCTAssertEqual(ScreenSettings.load(for: mac.id).quality, .low)
  }

  // Bug: settings saved before Quality existed failing to decode, resetting
  // the user's cursor mode, tracking speed, display and clipboard choice.
  func testSettingsSavedBeforeQualityKeepTheirValues() throws {
    let saved = #"{"cursorMode":"touch","trackingSpeed":1.5,"display":2,"sharedClipboard":false}"#
    let settings = try JSONDecoder().decode(ScreenSettings.self, from: Data(saved.utf8))
    XCTAssertEqual(settings.cursorMode, .touch)
    XCTAssertEqual(settings.trackingSpeed, 1.5)
    XCTAssertEqual(settings.display, 2)
    XCTAssertFalse(settings.sharedClipboard)
    XCTAssertEqual(settings.quality, .adaptive)
  }
}
