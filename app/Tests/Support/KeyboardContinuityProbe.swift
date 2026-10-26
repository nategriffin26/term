import UIKit
import XCTest
@testable import Term

/// UIKit posts WillShow when handing an already-visible keyboard between
/// responders, even with the same accessory instance. Measure visibility and
/// geometry instead: no hide, and no displaced keyboard or Smart Keys frame.
@MainActor
final class KeyboardContinuityProbe: NSObject {
  private struct Geometry: Equatable {
    var keyboard: CGRect
    var accessory: CGRect?
    var foreground: Bool
  }
  private weak var space: SpaceController?
  private var link: CADisplayLink?
  private let expected: Geometry
  private var gridObservers: [(Session, ((Int, Int) -> Void)?)] = []
  private var gridChanges: [String] = []
  private(set) var frames = 0
  private(set) var changes: [String] = []
  private(set) var hides = 0
  private(set) var shows = 0

  init(_ space: SpaceController, expectsSoftwareKeyboard: Bool = true, tracksGridChanges: Bool = true,
       file: StaticString = #filePath, line: UInt = #line) {
    self.space = space
    expected = Self.geometry(space)
    super.init()
    XCTAssertTrue(expected.foreground, "the measured scene must be in the foreground", file: file, line: line)
    if expectsSoftwareKeyboard {
      XCTAssertGreaterThan(expected.keyboard.height, SmartKeysBar.height + 80,
                           "this check requires the software keyboard", file: file, line: line)
      XCTAssertNotNil(expected.accessory, "Smart Keys must be attached before measuring", file: file, line: line)
    } else {
      XCTAssertLessThan(expected.keyboard.height, SmartKeysBar.height + 80,
                        "the software keyboard must be down before measuring", file: file, line: line)
      XCTAssertNil(expected.accessory, "Smart Keys must be detached with the keyboard down", file: file, line: line)
    }
    for (index, tab) in space.tabs.enumerated() where tracksGridChanges {
      let session = tab.current
      let previous = session.onGridChange
      gridObservers.append((session, previous))
      session.onGridChange = { [weak self] cols, rows in
        previous?(cols, rows)
        self?.gridChanges.append("tab\(index + 1):\(cols)x\(rows)")
      }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
    let link = CADisplayLink(target: self, selector: #selector(sample))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private static func geometry(_ space: SpaceController) -> Geometry {
    let terminal = space.focusedTab?.view
    let bar = terminal?.isFirstResponder == true ? terminal?.smartKeys : nil
    return Geometry(keyboard: space.view.keyboardLayoutGuide.layoutFrame,
                    accessory: bar?.window == nil ? nil : bar.map { $0.convert($0.bounds, to: space.view) },
                    foreground: space.view.window?.windowScene?.activationState == .foregroundActive)
  }

  @objc private func sample() {
    guard let space else { return }
    frames += 1
    let now = Self.geometry(space)
    if now != expected { changes.append("\(now)") }
  }

  @objc private func keyboardChanged(_ note: Notification) {
    if note.name == UIResponder.keyboardWillHideNotification { hides += 1 } else { shows += 1 }
  }

  func stop(file: StaticString = #filePath, line: UInt = #line) {
    sample()
    link?.invalidate()
    link = nil
    NotificationCenter.default.removeObserver(self)
    for (session, previous) in gridObservers { session.onGridChange = previous }
    gridObservers.removeAll()
    XCTAssertEqual(gridChanges, [], "a terminal resized during the transition", file: file, line: line)
    XCTAssertGreaterThan(frames, 1, "no display frames were observed", file: file, line: line)
    XCTAssertEqual(hides, 0, "the keyboard was dismissed", file: file, line: line)
    XCTAssertEqual(changes, [], "keyboard or Smart Keys moved during the transition", file: file, line: line)
  }
}
