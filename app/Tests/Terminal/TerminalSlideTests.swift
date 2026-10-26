import UIKit
import XCTest
@testable import Term

/// A swiped page slides under the display's rounded corners, whose adaptation
/// of the safe area moved its text 15 pt down until it came to rest.
@MainActor
final class TerminalSlideTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() async throws {
    await MainActor.run {
      window?.isHidden = true
      window = nil
    }
  }

  func testASlidingTerminalKeepsTheGeometryItHadAtRest() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
    self.window = window
    let host = UIViewController()
    window.rootViewController = host
    let view = TerminalView(session: try XCTUnwrap(Session(localCols: 20, rows: 5)))
    view.frame = host.view.bounds
    host.view.addSubview(view)
    window.isHidden = false
    view.layoutIfNeeded()
    let atRest = view.gridOrigin
    XCTAssertNotEqual(atRest, .zero, "the view was never laid out; the test proves nothing")

    // Mid-swipe the safe area differs from the one at rest.
    view.transform = CGAffineTransform(translationX: 120, y: 0)
    host.additionalSafeAreaInsets = UIEdgeInsets(top: 15, left: 0, bottom: 0, right: 0)
    host.view.layoutIfNeeded()
    view.layoutIfNeeded()
    XCTAssertEqual(view.gridOrigin, atRest, "the sliding view moved its grid")

    // At rest it takes the safe area it has.
    view.transform = .identity
    view.setNeedsLayout()
    view.layoutIfNeeded()
    XCTAssertGreaterThanOrEqual(view.gridOrigin.y, atRest.y + 15 * view.traitCollection.displayScale, "at rest the grid never took the safe area")
  }
}
