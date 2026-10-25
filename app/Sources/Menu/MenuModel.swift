import SwiftUI
import UIKit

/// The panel's tabs, in order. A new capability is a new case plus its view
/// in MenuContent; the header and the dock follow this list.
enum MenuTab: String, CaseIterable, Identifiable {
  case sessions, files, settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sessions: "Sessions"
    case .files: "Files"
    case .settings: "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .sessions: "square.grid.2x2"
    case .files: "folder"
    case .settings: "gearshape"
    }
  }
}

/// Pages of the Sessions tab.
enum SessionsPage: Equatable {
  case grid
  case new
  case tmux(Host)
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
  var isOpen = false {
    didSet {
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

  init() {
    tab = UserDefaults.standard.string(forKey: Self.lastTabKey).flatMap(MenuTab.init(rawValue:)) ?? .sessions
    thumbnails.onTick = { [weak self] in self?.updateAspect() }
  }

  private func updateThumbnails() {
    if isOpen { updateAspect() }
    thumbnails.isActive = isOpen && tab == .sessions
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

  /// Files panes opened in this window, one per host, kept for its lifetime
  /// so each stays where he left it.
  @ObservationIgnored private(set) var filesPanes: [FilesPaneEntry] = []
  /// The pane the Files tab showed last.
  @ObservationIgnored private(set) var shownFilesPane: String?

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
