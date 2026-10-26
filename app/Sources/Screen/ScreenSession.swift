import LocalAuthentication
import UIKit

/// How the Screen drives one Mac, remembered per host.
struct ScreenSettings: Codable, Equatable {
  enum CursorMode: String, Codable, CaseIterable { case trackpad, touch }

  var cursorMode = CursorMode.trackpad
  /// Pointer travel per finger travel in Trackpad Mode.
  var trackingSpeed = 1.0
  /// The display shown alone; nil shows them all.
  var display: UInt32?
  var sharedClipboard = true

  static let speeds = [0.5, 0.75, 1.0, 1.5, 2.0]

  static func load(for host: UUID) -> ScreenSettings {
    UserDefaults.standard.data(forKey: key(host)).flatMap { try? JSONDecoder().decode(ScreenSettings.self, from: $0) }
      ?? ScreenSettings()
  }

  func save(for host: UUID) {
    UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(host))
  }

  private static func key(_ host: UUID) -> String { "screen.settings.\(host.uuidString)" }
}

/// The toolbar's second rows.
enum ScreenRow: Equatable {
  case displays, modifiers, navigation, edit
}

/// The Mac's pointer as drawn: its picture at its size in Mac points.
struct ScreenCursor {
  let image: CGImage
  let size: CGSize
  let hotSpot: CGPoint
}

/// What the Screen's view does for the session.
@MainActor
protocol ScreenSurface: AnyObject {
  /// The Mac moved its pointer, or a connection placed it.
  func pointerMoved()
  func cursorChanged()
  /// Lets go of the hardware keys held down, through the session, while it still sends to the engine that got them.
  func releaseKeys()
}

/// Makes the engines a session drives; tests hand in fakes.
@MainActor
struct ScreenEngines {
  var host: (Host, @escaping (ScreenEvent) -> Void) -> ScreenEngine
  /// Screen Sharing, signed in with the Mac password.
  var sharing: (Host, String, @escaping (ScreenEvent) -> Void) -> ScreenEngine

  static let live = ScreenEngines(
    host: { host, onEvent in ScreenHostEngine(spec: Tab.spec(for: host), onEvent: onEvent) },
    sharing: { host, password, onEvent in
      ScreenVNCEngine(spec: Tab.spec(for: host), user: host.user, password: password, onEvent: onEvent)
    })
}

/// The menu's Screen tab for one window: which Mac, the connection to it,
/// and everything that survives the panel closing and the tab switching
/// (the view state lives here, the view only draws it).
@MainActor @Observable
final class ScreenSession {
  enum Phase: Equatable {
    case connecting
    case live
    /// Term Screen Host is missing, stopped or another version.
    case hostNotRunning
    /// SSH failed before reaching the host.
    case unreachable(String)
    /// A live connection ended.
    case lost(String)
  }

  /// Screen Sharing (VNC) while Term Screen Host can't show or drive the Mac:
  /// the Mac is locked, the host is missing, or it lacks its privacy grants.
  enum Sharing: Equatable {
    case off
    /// No Mac password saved yet.
    case needsPassword
    case signingIn
    case live
    /// Open but idle after the Mac unlocked: macOS locks again when the
    /// Screen Sharing session that unlocked it ends, so it stays until the
    /// Screen's session does (Disconnect, another Mac, the app in the background).
    case held
    case failed(String)
  }

  enum PasswordPrompt: Equatable {
    /// Type User Password; Return after it or not.
    case type(withReturn: Bool)
    /// Sign in to Screen Sharing on the locked Mac.
    case signIn
  }

  private(set) var host: Host?
  private(set) var phase = Phase.connecting
  private(set) var macName = ""
  /// The Mac's displays as Term Screen Host reports them.
  private(set) var hostDisplays: [ScreenWire.Display] = []
  private(set) var sharing = Sharing.off
  /// Screen Sharing's one framebuffer, in pixels.
  private(set) var sharingDisplays: [ScreenWire.Display] = []
  private(set) var locked = false
  private(set) var access = ScreenWire.Access(screen: true, input: true)
  /// Something the host wants read; it goes after a few seconds.
  private(set) var notice: String?
  private(set) var settings = ScreenSettings()
  private(set) var modifiers = ModifierLatch()
  /// The Mac's clipboard as last copied there (Get Clipboard).
  private(set) var macClipboard: ScreenWire.Clipboard?
  /// The Screen's tab is open in the open panel.
  private(set) var isShown = false
  var openRow: ScreenRow?
  /// Two-finger double-tap: the toolbar and the panel's header hide.
  var fullscreen = false
  /// The software keyboard is asked for.
  var keyboardUp = false
  /// Asks for the Mac's password, then does what it was asked for.
  var passwordPrompt: PasswordPrompt?

  /// The pointer in the Mac's space, drawn locally at once.
  @ObservationIgnored var pointer = CGPoint.zero
  @ObservationIgnored var viewport: ScreenViewport?
  var cursor: ScreenCursor? { sharing == .live ? sharingCursor : hostCursor }
  @ObservationIgnored private var hostCursor: ScreenCursor?
  @ObservationIgnored private var sharingCursor: ScreenCursor?
  /// Where the host last put the pointer while Screen Sharing drove it.
  @ObservationIgnored private var hostPointer = CGPoint.zero
  @ObservationIgnored weak var surface: ScreenSurface?
  /// A held drag's button and where it went down: released before any disconnect.
  @ObservationIgnored var heldButton: ScreenWire.MouseButton?

  @ObservationIgnored private let engines: ScreenEngines
  @ObservationIgnored private var engine: ScreenEngine?
  @ObservationIgnored private var vnc: ScreenEngine?
  @ObservationIgnored private var echo = PasteboardEcho()
  @ObservationIgnored private var pasteboardTimer: Timer?
  @ObservationIgnored private var noticeTimer: Timer?
  @ObservationIgnored private var hostRetryTimer: Timer?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  private static let hostKey = "screen.host"
  private static let syncedKey = "screen.pasteboardSynced"

  init(engines: ScreenEngines = .live) {
    self.engines = engines
    if let id = UserDefaults.standard.string(forKey: Self.hostKey).flatMap(UUID.init(uuidString:)) {
      host = ConfigStore.shared.hosts.first { $0.id == id }
      if let host { settings = ScreenSettings.load(for: host.id) }
    }
    if UserDefaults.standard.object(forKey: Self.syncedKey) != nil {
      echo.wrote(UserDefaults.standard.integer(forKey: Self.syncedKey))
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.enteredBackground() }
    })
    observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.becameActive() }
    })
  }

  // MARK: - Which Mac

  /// The host picked on the pick page: remembered, then connected.
  func choose(_ host: Host) {
    stopSharing()
    self.host = host
    UserDefaults.standard.set(host.id.uuidString, forKey: Self.hostKey)
    settings = ScreenSettings.load(for: host.id)
    viewport = nil
    connect()
  }

  /// Actions › Disconnect: back to the pick page.
  func disconnect() {
    endConnection()
    host = nil
    UserDefaults.standard.removeObject(forKey: Self.hostKey)
    hostDisplays = []
    macName = ""
    viewport = nil
    fullscreen = false
    keyboardUp = false
    openRow = nil
  }

  func reconnect() { connect() }

  /// A fresh host connection; a held Screen Sharing session stays open.
  private func connect() {
    releaseHeldButton()
    if sharing != .held { stopSharing() }
    engine?.close()
    engine = nil
    stopPasteboardWatch()
    guard let host else { return }
    phase = .connecting
    modifiers.reset()
    engine = engines.host(host) { [weak self] event in self?.handle(event) }
  }

  /// Lets go of a held button first: a release must never be lost.
  private func endConnection() {
    releaseHeldButton()
    stopSharing()
    engine?.close()
    engine = nil
    stopPasteboardWatch()
  }

  /// The Screen is on screen (its tab open in the open panel) or not.
  func setShown(_ shown: Bool) {
    guard shown != isShown else { return }
    isShown = shown
    if shown {
      if engine == nil, host != nil, UIApplication.shared.applicationState != .background { connect() }
      watchShown()
      startPasteboardWatch()
    } else {
      releaseInput()
      engine?.watch([])
      stopPasteboardWatch()
      keyboardUp = false
    }
    updateSharing()
  }

  private func enteredBackground() {
    guard engine != nil || vnc != nil else { return }
    endConnection()
    phase = .connecting
  }

  private func becameActive() {
    guard isShown, host != nil else { return }
    if engine == nil { connect() }
    checkPasteboard()
  }

  // MARK: - Displays

  /// What the picture holds: Screen Sharing's framebuffer while it drives the
  /// locked Mac, the host's displays otherwise.
  var displays: [ScreenWire.Display] { sharing == .live ? sharingDisplays : hostDisplays }

  /// The displays on show: the chosen one alone, else all of them.
  var shownDisplays: [ScreenWire.Display] {
    if sharing != .live, let id = settings.display, let one = hostDisplays.first(where: { $0.id == id }) { return [one] }
    return displays
  }

  /// One tap in the Displays row or Actions › Display; nil is All.
  func showDisplay(_ id: UInt32?) {
    guard id != settings.display else { return }
    updateSettings { $0.display = id }
    viewport = nil
    watchShown()
  }

  /// The host streams the shown displays, or nothing while Screen Sharing shows the locked Mac.
  private func watchShown() {
    guard isShown, phase == .live else { return }
    engine?.watch(sharing == .live ? [] : shownDisplays.map(\.id))
  }

  func layer(for display: UInt32) -> CALayer? { activeEngine?.layer(for: display) }

  /// Who takes input and draws the picture.
  private var activeEngine: ScreenEngine? { sharing == .live ? vnc : engine }

  /// The picture can be driven: Screen Sharing is live, or the host is, with the Mac unlocked and its grants.
  var drivable: Bool { sharing == .live || (phase == .live && !locked && !needsAccess) }

  /// Term Screen Host lacks a privacy grant: it can't show the Mac, or can't drive it.
  var needsAccess: Bool { !access.screen || !access.input }

  // MARK: - Screen Sharing

  /// Runs Screen Sharing while the Screen shows and the host can't: the Mac
  /// is locked, Term Screen Host isn't running on it, or it lacks a privacy
  /// grant (Screen Sharing lets the user approve it in System Settings).
  private func updateSharing() {
    guard isShown, (phase == .live && (locked || needsAccess)) || phase == .hostNotRunning else {
      if sharing == .live { holdSharing() } else if sharing != .held { stopSharing() }
      return
    }
    switch sharing {
    case .off: startSharing()
    case .held:
      vnc?.watch([ScreenVNCEngine.display])
      enterSharing()
    default: break
    }
  }

  /// While the host is missing, looks for it again every few seconds, so
  /// the picture goes back to the host's video once it runs.
  private func scheduleHostRetry() {
    hostRetryTimer?.invalidate()
    hostRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isShown, self.phase == .hostNotRunning, self.engine == nil, let host = self.host else { return }
        self.engine = self.engines.host(host) { [weak self] event in self?.handle(event) }
      }
    }
  }

  /// Signs in with the saved Mac password, or asks for it.
  func startSharing() {
    guard let host else { return }
    vnc?.close()
    guard let password = Keychain.macPassword(for: host.id) else {
      sharing = .needsPassword
      return
    }
    sharing = .signingIn
    vnc = engines.sharing(host, password) { [weak self] event in self?.handleSharing(event) }
  }

  private func stopSharing() {
    guard sharing != .off || vnc != nil else { return }
    let wasLive = sharing == .live
    if wasLive { releaseInput() }
    vnc?.close()
    vnc = nil
    sharing = .off
    if wasLive { leaveSharing() }
  }

  /// Back to the host's picture: its pointer, its displays, fresh key frames.
  private func leaveSharing() {
    pointer = hostPointer
    viewport = nil
    surface?.cursorChanged()
    watchShown()
  }

  /// Screen Sharing goes idle, still open, and the host's picture comes back.
  private func holdSharing() {
    releaseInput()
    vnc?.watch([])
    sharing = .held
    leaveSharing()
  }

  /// Screen Sharing's picture and input take over from the host's.
  private func enterSharing() {
    releaseInput()
    hostPointer = pointer
    sharing = .live
    viewport = nil
    if let frame = sharingDisplays.first?.frame { pointer = CGPoint(x: frame.width / 2, y: frame.height / 2) }
    watchShown()
    surface?.cursorChanged()
    surface?.pointerMoved()
  }

  private func handleSharing(_ event: ScreenEvent) {
    switch event {
    case .displays(let list):
      sharingDisplays = list
      if sharing == .signingIn { enterSharing() }
      if sharing == .live {
        viewport = nil
        surface?.pointerMoved()
      }
    case .cursor(let image):
      sharingCursor = Self.cursor(from: image)
      surface?.cursorChanged()
    case .closed(.ended(let reason)):
      let was = sharing
      if was == .live { heldButton = nil }
      vnc = nil
      // An idle session ending is no failure; if the Mac locks again, the host says so.
      sharing = was == .held ? .off : .failed(reason)
      if was == .live { leaveSharing() }
    default:
      break
    }
  }

  // MARK: - Settings

  func setCursorMode(_ mode: ScreenSettings.CursorMode) { updateSettings { $0.cursorMode = mode } }
  func setTrackingSpeed(_ speed: Double) { updateSettings { $0.trackingSpeed = speed } }
  func setSharedClipboard(_ on: Bool) {
    updateSettings { $0.sharedClipboard = on }
    if on { checkPasteboard() }
  }

  private func updateSettings(_ change: (inout ScreenSettings) -> Void) {
    change(&settings)
    if let host { settings.save(for: host.id) }
  }

  // MARK: - Engine events

  private func handle(_ event: ScreenEvent) {
    switch event {
    case .welcome(let welcome):
      macName = welcome.name
      hostDisplays = welcome.displays
      locked = welcome.locked
      access = welcome.access
      pointer = CGPoint(x: welcome.pointer.x, y: welcome.pointer.y)
      hostPointer = pointer
      phase = .live
      watchShown()
      updateSharing()
      surface?.pointerMoved()
      checkPasteboard()
    case .displays(let list):
      let before = shownDisplays.map(\.id)
      hostDisplays = list
      if shownDisplays.map(\.id) != before {
        viewport = nil
        watchShown()
      }
    case .cursor(let image):
      hostCursor = Self.cursor(from: image)
      surface?.cursorChanged()
    case .pointerMoved(let point):
      hostPointer = point
      guard heldButton == nil, sharing != .live else { return }
      pointer = point
      surface?.pointerMoved()
    case .clipboard(let clipboard):
      macClipboard = clipboard
      if settings.sharedClipboard { writePasteboard(clipboard) }
    case .lock(let isLocked):
      locked = isLocked
      updateSharing()
    case .access(let granted):
      access = granted
      updateSharing()
    case .failure(let message):
      show(notice: message)
    case .closed(let closure):
      engine = nil
      if sharing != .live { heldButton = nil }
      stopPasteboardWatch()
      switch closure {
      case .hostNotRunning:
        phase = .hostNotRunning
        scheduleHostRetry()
      case .unreachable(let reason): phase = .unreachable(reason)
      // Approving Screen Recording on the Mac restarts the host (Quit & Reopen):
      // the picture stays on Screen Sharing until it answers again.
      case .ended where needsAccess:
        phase = .hostNotRunning
        scheduleHostRetry()
      case .ended(let reason): phase = .lost(reason)
      }
      updateSharing()
    }
  }

  private func show(notice message: String) {
    notice = message
    noticeTimer?.invalidate()
    noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.notice = nil }
    }
  }

  private static func cursor(from image: ScreenWire.CursorImage) -> ScreenCursor? {
    guard let ui = UIImage(data: image.png), let cg = ui.cgImage, image.scale > 0 else { return nil }
    return ScreenCursor(image: cg,
                        size: CGSize(width: CGFloat(cg.width) / image.scale, height: CGFloat(cg.height) / image.scale),
                        hotSpot: CGPoint(x: image.hotX, y: image.hotY))
  }

  // MARK: - Pointer

  private func send(_ input: ScreenInput) {
    guard drivable else { return }
    activeEngine?.send(input)
  }

  /// The pointer to `point` (a drag while a button is held).
  func movePointer(to point: CGPoint) {
    pointer = point
    send(.pointer(point))
  }

  /// A click of `clicks` (2 for a double-click's second click) at `point`.
  func click(_ button: ScreenWire.MouseButton, at point: CGPoint, clicks: Int = 1) {
    pointer = point
    send(.button(button, down: true, at: point, clicks: clicks))
    send(.button(button, down: false, at: point, clicks: clicks))
    consumeOnce()
  }

  func pressButton(_ button: ScreenWire.MouseButton, at point: CGPoint) {
    heldButton = button
    pointer = point
    send(.button(button, down: true, at: point, clicks: 1))
  }

  /// Ends a held drag at the pointer's last place.
  func releaseHeldButton() {
    guard let button = heldButton else { return }
    heldButton = nil
    send(.button(button, down: false, at: pointer, clicks: 1))
    consumeOnce()
  }

  /// Lets the Mac go before the engine with the input stops having it (the
  /// Screen hides, or Screen Sharing takes over or hands back): the held
  /// button, the hardware keys, then every modifier the toolbar latched.
  private func releaseInput() {
    releaseHeldButton()
    surface?.releaseKeys()
    let held = modifiers.held
    modifiers.reset()
    if !held.isEmpty { send(.modifiers([])) }
  }

  func scroll(_ events: [ScreenWire.ScrollEvent]) {
    for event in events { send(.scroll(event)) }
  }

  // MARK: - Keys

  func tapModifier(_ key: ScreenWire.Modifiers) {
    let before = modifiers.held
    modifiers.tap(key, at: CACurrentMediaTime())
    if modifiers.state(key) == .locked { Haptics.firm() } else { Haptics.keyDown() }
    if modifiers.held != before { send(.modifiers(modifiers.held)) }
  }

  func hardwareModifier(_ key: ScreenWire.Modifiers, down: Bool) {
    let before = modifiers.held
    modifiers.hardware(key, down: down)
    if modifiers.held != before { send(.modifiers(modifiers.held)) }
  }

  /// One-shot modifiers let go after the key, click or drag that used them.
  func consumeOnce() {
    let before = modifiers.held
    modifiers.consumeOnce()
    if modifiers.held != before { send(.modifiers(modifiers.held)) }
  }

  /// A key down and up with the held modifiers plus `extra` (a shortcut
  /// from the Edit row or the Commands menu). Fn turns arrows into Home,
  /// End and the pages, digits into F-keys, Delete into Forward Delete.
  func press(_ code: UInt16, with extra: ScreenWire.Modifiers = [], consume: Bool = true) {
    keyDown(code, with: extra)
    keyUp(code, with: extra)
    if consume { consumeOnce() }
  }

  func keyDown(_ code: UInt16, with extra: ScreenWire.Modifiers = []) {
    let held = modifiers.held
    if !held.isSuperset(of: extra) { send(.modifiers(held.union(extra))) }
    send(.key(held.contains(.function) ? MacKey.withFunction(code) : code, down: true))
  }

  func keyUp(_ code: UInt16, with extra: ScreenWire.Modifiers = []) {
    let held = modifiers.held
    send(.key(held.contains(.function) ? MacKey.withFunction(code) : code, down: false))
    if !held.isSuperset(of: extra) { send(.modifiers(held)) }
  }

  /// Text from the software keyboard. With a modifier held, characters a
  /// key can type go as keys (⌘ then C is a real ⌘C); otherwise as text, so
  /// the phone's keyboard language need not match the Mac's.
  func type(_ text: String) {
    switch text {
    case "\n", "\r": press(MacKey.returnKey); return
    case "\t": press(MacKey.tab); return
    default: break
    }
    guard !modifiers.held.isEmpty else {
      send(.text(text))
      return
    }
    for character in text {
      if let (code, shift) = MacKey.code(for: character) {
        press(code, with: shift ? .shift : [], consume: false)
      } else {
        send(.text(String(character)))
      }
    }
    consumeOnce()
  }

  /// Type User Password: the saved Mac password after Face ID, or ask for it first.
  func typePassword(withReturn: Bool) {
    guard let host else { return }
    guard let password = Keychain.macPassword(for: host.id) else {
      passwordPrompt = .type(withReturn: withReturn)
      return
    }
    let context = LAContext()
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Type your Mac password") { [weak self] ok, _ in
      guard ok else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          // Only for the Mac it was asked for: Face ID can take a while.
          guard let self, self.host?.id == host.id else { return }
          self.typeSecret(password, withReturn: withReturn)
        }
      }
    }
  }

  /// The password sheet's answer, kept in the Keychain for this Mac: typed,
  /// or used to sign in to Screen Sharing.
  func savePassword(_ password: String, for prompt: PasswordPrompt) {
    guard let host, !password.isEmpty else { return }
    Keychain.setMacPassword(password, for: host.id)
    switch prompt {
    case .type(let withReturn): typeSecret(password, withReturn: withReturn)
    case .signIn: startSharing()
    }
  }

  private func typeSecret(_ password: String, withReturn: Bool) {
    guard locked, sharing == .live else {
      sendSecret(password, withReturn: withReturn)
      return
    }
    // The login window's password field takes keys only once clicked, and
    // keeps what an earlier attempt left: click, then ⌘A and Delete clear it.
    click(.left, at: sharingFocusPoint)
    surface?.pointerMoved()
    let target = vnc
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      // The same Screen Sharing session, or the password goes nowhere.
      guard let self, self.sharing == .live, self.vnc === target else { return }
      self.press(MacKey.a, with: .command, consume: false)
      self.press(MacKey.delete, consume: false)
      self.sendSecret(password, withReturn: withReturn)
    }
  }

  private func sendSecret(_ password: String, withReturn: Bool) {
    send(.text(password))
    if withReturn { press(MacKey.returnKey) }
  }

  /// The main display's middle in Screen Sharing's framebuffer, where the
  /// login window's password field takes a click; the framebuffer's middle
  /// when the host never said.
  private var sharingFocusPoint: CGPoint {
    let framebuffer = sharingDisplays.first?.frame.cg ?? .zero
    let layout = Self.sharingLayout(hostDisplays)
    let bounds = layout.values.reduce(CGRect.null) { $0.union($1) }
    guard let main = (hostDisplays.first(where: \.isMain) ?? hostDisplays.first).flatMap({ layout[$0.id] }),
          !bounds.isEmpty else {
      return CGPoint(x: framebuffer.midX, y: framebuffer.midY)
    }
    return CGPoint(x: (main.midX - bounds.minX) * (framebuffer.width / bounds.width),
                   y: (main.midY - bounds.minY) * (framebuffer.height / bounds.height))
  }

  /// Where Screen Sharing draws each display in its framebuffer: at native
  /// pixels, each at its point origin in its own pixels, pushed clear of a
  /// display it would overlap on the side it sits on in the arrangement. A
  /// 2x built-in with a 1x display to its right and 687 pt above composes
  /// to 6896x2921 px, the built-in 687 px down, as Screen Sharing sends it.
  private static func sharingLayout(_ displays: [ScreenWire.Display]) -> [UInt32: CGRect] {
    var placed: [(points: CGRect, pixels: CGRect)] = []
    var layout: [UInt32: CGRect] = [:]
    for display in displays.sorted(by: { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }) {
      let points = display.frame.cg
      let scale = points.width > 0 ? CGFloat(display.pixelWidth) / points.width : 1
      var pixels = CGRect(x: points.minX * scale, y: points.minY * scale,
                          width: CGFloat(display.pixelWidth), height: CGFloat(display.pixelHeight))
      for other in placed where pixels.intersects(other.pixels) {
        if points.minX >= other.points.maxX {
          pixels.origin.x = other.pixels.maxX
        } else if points.minY >= other.points.maxY {
          pixels.origin.y = other.pixels.maxY
        } else if points.maxY <= other.points.minY {
          pixels.origin.y = other.pixels.minY - pixels.height
        }
      }
      placed.append((points, pixels))
      layout[display.id] = pixels
    }
    return layout
  }

  // MARK: - Clipboard

  /// While the Screen shows, a copy on the phone goes to the Mac (Paste
  /// from Other Apps is set to Allow, so reading raises no prompt).
  private func startPasteboardWatch() {
    guard isShown, phase == .live, pasteboardTimer == nil else { return }
    pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkPasteboard() }
    }
  }

  private func stopPasteboardWatch() {
    pasteboardTimer?.invalidate()
    pasteboardTimer = nil
  }

  private func checkPasteboard() {
    guard isShown, phase == .live, settings.sharedClipboard else { return }
    startPasteboardWatch()
    guard echo.needsSending(UIPasteboard.general.changeCount) else { return }
    rememberSynced()
    sendPasteboard()
  }

  private func sendPasteboard() {
    guard let item = UIPasteboard.general.items.first else { return }
    let clipboard = ScreenClipboard.clipboard(from: item)
    guard !clipboard.items.isEmpty else { return }
    engine?.setClipboard(clipboard)
  }

  /// Actions › Clipboard › Send Clipboard.
  func sendClipboard() {
    _ = echo.needsSending(UIPasteboard.general.changeCount)
    rememberSynced()
    sendPasteboard()
  }

  /// Actions › Clipboard › Get Clipboard: the Mac's last copy onto the phone.
  func getClipboard() {
    if let macClipboard { writePasteboard(macClipboard) }
  }

  /// The Edit row's Paste: the phone's clipboard becomes the Mac's, then ⌘V.
  func paste(_ providers: [NSItemProvider]) {
    Task {
      let clipboard = await ScreenClipboard.clipboard(from: providers)
      guard !clipboard.items.isEmpty, phase == .live else { return }
      _ = echo.needsSending(UIPasteboard.general.changeCount)
      rememberSynced()
      engine?.setClipboard(clipboard)
      press(MacKey.v, with: .command)
    }
  }

  private func writePasteboard(_ clipboard: ScreenWire.Clipboard) {
    let item = ScreenClipboard.pasteboardItem(from: clipboard)
    guard !item.isEmpty else { return }
    UIPasteboard.general.setItems([item])
    echo.wrote(UIPasteboard.general.changeCount)
    rememberSynced()
  }

  private func rememberSynced() {
    if let synced = echo.synced { UserDefaults.standard.set(synced, forKey: Self.syncedKey) }
  }
}
