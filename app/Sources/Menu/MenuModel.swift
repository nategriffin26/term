import SwiftUI
import UIKit

/// The panel's tabs, in order. A new capability is a new case plus its view
/// in MenuContent; the header and the dock follow this list.
enum MenuTab: String, CaseIterable, Identifiable {
  case sessions, tmux, files, settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sessions: "Sessions"
    case .tmux: "tmux"
    case .files: "Files"
    case .settings: "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .sessions: "square.grid.2x2"
    case .tmux: "rectangle.stack"
    case .files: "folder"
    case .settings: "gearshape"
    }
  }

  /// The open tab's glyph: the filled variant.
  var selectedSymbol: String { symbol + ".fill" }
}

/// Pages of the Sessions tab.
enum SessionsPage: Equatable {
  case grid
  case new
}

/// A window's sessions as the overview shows them.
struct SessionGroup: Identifiable {
  let space: SpaceController
  let tabs: [Tab]
  var id: ObjectIdentifier { ObjectIdentifier(space) }
}

/// State the panel's SwiftUI content reads; actions go to the window's
/// SpaceController.
@MainActor @Observable
final class MenuModel {
  static let lastTabKey = "menu.lastTab"

  var tab: MenuTab {
    didSet {
      UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
      updateThumbnails()
      onChange?()
    }
  }
  var sessionsPage = SessionsPage.grid
  /// Bumped on every opening; Settings is rebuilt on it, so it starts at its root.
  private(set) var settingsGeneration = 0
  /// Every tab but Files opens at its root page; Files resumes where he left it.
  var isOpen = false {
    didSet {
      if !isOpen { tmuxTarget = nil }
      if isOpen, !oldValue { resetPages() }
      updateThumbnails()
      onChange?()
    }
  }
  /// Bumped when any window's tabs or their names change.
  var revision = 0
  /// Width over height of the focused terminal's grid: the overview's tiles
  /// take its shape, and follow it through rotation, folding and the keyboard.
  private(set) var aspect: CGFloat = 0.6

  @ObservationIgnored weak var space: SpaceController?
  /// Runs when the open tab or open state changes (the dock follows it).
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored let thumbnails = ThumbnailRenderer()
  /// Thumbnail frames in window coordinates, for the zoom in and out of a tile.
  @ObservationIgnored var tileFrames: [UUID: CGRect] = [:]
  /// The tmux tab's long-press preview of a session's screen.
  @ObservationIgnored let tmuxPreviews = ThumbnailRenderer()
  /// The host the tmux tab lists first while open (`tmux host` at the prompt).
  var tmuxTarget: String?
  /// The tmux tab shows checkboxes, to close several sessions at once.
  var tmuxSelecting = false {
    didSet { if !tmuxSelecting { tmuxSelection = [] } }
  }
  /// Rows checked while selecting, by `TmuxTab.rowID`.
  var tmuxSelection = Set<String>()
  /// Rows opening a session while its existing terminals are being checked.
  var tmuxOpening = Set<String>()

  init() {
    tab = UserDefaults.standard.string(forKey: Self.lastTabKey).flatMap(MenuTab.init(rawValue:)) ?? .sessions
    thumbnails.onTick = { [weak self] in self?.updateAspect() }
  }

  private func updateThumbnails() {
    if isOpen { updateAspect() }
    thumbnails.isActive = isOpen && tab == .sessions
    if !isOpen || tab != .tmux { tmuxSelecting = false }
  }

  /// Sub-pages from the last opening are gone before the panel shows, with
  /// no slide back to the root.
  private func resetPages() {
    var quiet = Transaction()
    quiet.disablesAnimations = true
    withTransaction(quiet) {
      sessionsPage = .grid
      settingsGeneration += 1
    }
  }

  /// The terminal resizes its session a moment after layout, so the
  /// thumbnails' tick keeps checking while the overview shows.
  private func updateAspect() {
    guard let view = space?.focusedTab?.view else { return }
    let cell = view.cellSizePoints
    let (cols, rows) = view.gridSize
    guard cols > 0, rows > 0 else { return }
    let shape = min(max(CGFloat(cols) * cell.width / (CGFloat(rows) * cell.height), 0.45), 2.2)
    if abs(shape - aspect) > 0.005 { aspect = shape }
  }

  /// This window's sessions first, then other open windows'.
  var groups: [SessionGroup] {
    _ = revision
    guard let space else { return [] }
    let others = SpaceController.live.filter { $0 !== space && $0.view.window != nil }
    return ([space] + others).map { SessionGroup(space: $0, tabs: $0.tabs) }
  }

  var currentTab: Tab? {
    _ = revision
    return space?.focusedTab
  }

  /// Every window's tabs attached to tmux session `name` on `host`'s server.
  func tabs(on host: Host, session name: String) -> [Tab] {
    _ = revision
    return SpaceController.live.flatMap(\.tabs).filter { $0.tmuxSession == name && $0.target.map { TmuxStore.shared.sameServer($0, host) } == true }
  }

  /// Files panes opened in this window, one per host, kept for its lifetime
  /// so each stays where he left it.
  @ObservationIgnored private(set) var filesPanes: [FilesPaneEntry] = []
  /// The pane the Files tab showed last.
  @ObservationIgnored private(set) var shownFilesPane: String?
  /// Each pane's browser once it has one, by pane id.
  @ObservationIgnored private var browsers: [String: FilesBrowser] = [:]

  func register(_ browser: FilesBrowser, forPane id: String) {
    browsers[id] = browser
  }

  /// The browser on screen when the Files tab is: ⌘V pastes into its folder.
  var shownBrowser: FilesBrowser? {
    shownFilesPane.flatMap { browsers[$0] }
  }

  /// The Files pane for the focused tab's host, registered on first use.
  func filesPane() -> FilesPaneEntry {
    let tab = currentTab
    let target = tab?.hostName != nil ? tab?.target : nil
    let id = target.map { "\($0.user)@\($0.knownHostsKey)" } ?? "local"
    shownFilesPane = id
    if let known = filesPanes.first(where: { $0.id == id }) { return known }
    let entry = FilesPaneEntry(id: id, spec: target.map(Tab.spec(for:)))
    filesPanes.append(entry)
    return entry
  }
}

/// One Files pane: a remote host's, or the local prompt's (where he picks a host).
struct FilesPaneEntry: Identifiable {
  /// "user@hostname:port", or "local".
  let id: String
  let spec: ConnectSpec?
}
