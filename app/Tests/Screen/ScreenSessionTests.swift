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
}
