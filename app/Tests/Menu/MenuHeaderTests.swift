import SwiftUI
import XCTest
@testable import Term

/// The panel's header (tab track, page buttons, close) at the narrowest
/// panels the app shows: it must never be wider than the panel.
@MainActor
final class MenuHeaderTests: XCTestCase {
  private var savedTextSize: TextSize?

  override func tearDown() async throws {
    if let savedTextSize { AppSettings.shared.textSize = savedTextSize }
  }

  /// Panel widths: the Duo's outer display beside the side dock (365 pt, the
  /// user's screenshot), an iPhone 18 Pro in portrait (402 - 16), and 320 for
  /// the narrowest window iOS gives an app.
  private let widths: [CGFloat] = [320, 365, 386]

  private func states() -> [(String, MenuModel)] {
    let sessions = MenuModel()
    sessions.tab = .sessions
    sessions.sessionsPage = .overview
    let selecting = MenuModel()
    selecting.tab = .tmux
    selecting.tmuxSelecting = true
    let screen = MenuModel()
    screen.tab = .screen
    let settings = MenuModel()
    settings.tab = .settings
    return [("sessions overview", sessions), ("tmux selecting", selecting), ("screen", screen), ("settings", settings)]
  }

  // Bug: on the Duo's outer display the header overflowed the panel: the
  // open tab's capsule was cut at the left edge and × sat under the right corner.
  func testHeaderFitsTheNarrowestPanelsAtEveryTextSize() {
    savedTextSize = AppSettings.shared.textSize
    for textSize in [TextSize.standard, .large] {
      AppSettings.shared.textSize = textSize
      for (state, model) in states() {
        let host = UIHostingController(rootView: MenuHeader(model: model))
        for width in widths {
          let size = host.sizeThatFits(in: CGSize(width: width, height: 200))
          XCTAssertLessThanOrEqual(size.width, width, "\(state) at \(width) pt, text \(textSize)")
        }
      }
    }
  }
}
