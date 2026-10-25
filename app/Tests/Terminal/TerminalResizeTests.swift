import UIKit
import XCTest
@testable import Term

/// A keyboard or rotation animation lays the view out at several in-between
/// sizes. Each size used to reach the session as its own resize, so a remote
/// tmux redrew three or four times per keyboard show.
@MainActor
final class TerminalResizeTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() async throws {
    await MainActor.run {
      window?.isHidden = true
      window = nil
    }
  }

  func testInBetweenLayoutSizesReachTheSessionAsOneResize() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
    self.window = window
    let session = try XCTUnwrap(Session(localCols: 20, rows: 5))
    let view = TerminalView(session: session)
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))

    let fullRows = session.rows
    var sizes: [(Int, Int)] = []
    session.onGridChange = { sizes.append(($0, $1)) }
    for height in [600.0, 450.0, 520.0, 400.0] {
      view.frame.size.height = height
      view.layoutIfNeeded()
    }
    try await Task.sleep(for: .milliseconds(400))

    XCTAssertEqual(sizes.count, 1, "in-between sizes reached the session: \(sizes)")
    XCTAssertLessThan(session.rows, fullRows)
  }
}
