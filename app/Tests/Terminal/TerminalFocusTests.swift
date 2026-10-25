import UIKit
import XCTest
@testable import Term

/// Two Term windows (Duo inner display, side by side): only the terminal that
/// last took the keyboard may look focused. Each window keeps its own first
/// responder, so the other window's terminal kept its solid cursor and Smart
/// Keys bar while the keys went elsewhere.
@MainActor
final class TerminalFocusTests: XCTestCase {
  private var windows: [UIWindow] = []

  override func tearDown() async throws {
    await MainActor.run {
      for w in windows { w.isHidden = true }
      windows = []
    }
  }

  private func terminal() throws -> TerminalView {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
    let view = TerminalView(session: try XCTUnwrap(Session(localCols: 20, rows: 5)))
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    windows.append(window)
    return view
  }

  func testTakingTheKeyboardUnfocusesTheTerminalInAnotherWindow() throws {
    let a = try terminal(), b = try terminal()
    XCTAssertTrue(a.becomeFirstResponder())
    XCTAssertTrue(b.becomeFirstResponder())
    XCTAssertTrue(b.isFirstResponder)
    XCTAssertFalse(a.isFirstResponder, "the other window's terminal still holds the keyboard")
    XCTAssertTrue(a.becomeFirstResponder())
    XCTAssertFalse(b.isFirstResponder)
  }
}
