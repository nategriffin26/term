import UIKit
import XCTest
@testable import Term

/// Keys, modifiers and scrolling as the Mac receives them.
final class ScreenInputTests: XCTestCase {
  // MARK: Modifier latch (spec §4)

  // Bug: a second tap locking the key however late it comes, or a quick one not locking it.
  func testSecondTapWithinTheWindowLocksLaterOneReleases() {
    var latch = ModifierLatch()
    latch.tap(.command, at: 10)
    XCTAssertEqual(latch.state(.command), .once)
    XCTAssertEqual(latch.held, .command)
    latch.tap(.command, at: 10.35)
    XCTAssertEqual(latch.state(.command), .locked, "at the window's edge")
    latch.tap(.command, at: 11)
    XCTAssertEqual(latch.state(.command), .off)
    XCTAssertEqual(latch.held, [])

    latch.tap(.option, at: 20)
    latch.tap(.option, at: 20.36)
    XCTAssertEqual(latch.state(.option), .off, "just past the window: a second tap lets go")
  }

  // Bug: a one-shot ⌘ staying down after the click that used it, or a locked one let go.
  func testConsumingLetsGoOfOneShotKeysOnly() {
    var latch = ModifierLatch()
    latch.tap(.shift, at: 0)
    latch.tap(.control, at: 0)
    latch.tap(.control, at: 0.1)
    latch.consumeOnce()
    XCTAssertEqual(latch.state(.shift), .off)
    XCTAssertEqual(latch.state(.control), .locked)
    XCTAssertEqual(latch.held, .control)
  }

  // Bug: a hardware ⌘ release dropping the toolbar's locked ⌘ (or the reverse), out of sync on the Mac.
  func testHardwareAndToolbarModifiersCombine() {
    var latch = ModifierLatch()
    latch.tap(.command, at: 0)
    latch.tap(.command, at: 0.1)
    latch.hardware(.option, down: true)
    latch.hardware(.command, down: true)
    XCTAssertEqual(latch.held, [.command, .option])
    latch.hardware(.command, down: false)
    latch.hardware(.option, down: false)
    XCTAssertEqual(latch.held, .command)
    latch.consumeOnce()
    XCTAssertEqual(latch.held, .command)
  }

  // MARK: Key codes (kVK_*, HIToolbox Events.h)

  // Bug: a hardware key arriving on the Mac as another key (macOS key codes are not HID order).
  func testHardwareKeysMapToMacKeyCodes() {
    let expected: [Int: UInt16] = [
      0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x10: 0x2E, 0x1D: 0x06,  // A B C M Z
      0x1E: 0x12, 0x22: 0x17, 0x23: 0x16, 0x26: 0x19, 0x27: 0x1D,  // 1 5 6 9 0
      0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31,  // Return Escape Delete Tab Space
      0x35: 0x32, 0x64: 0x0A,                                      // ` and the ISO key
      0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,  // Home PgUp FwdDel End PgDn
      0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,              // → ← ↓ ↑
      0x3A: 0x7A, 0x3D: 0x76, 0x45: 0x6F, 0x68: 0x69, 0x6F: 0x5A,  // F1 F4 F12 F13 F20
      0x59: 0x53, 0x61: 0x5C, 0x62: 0x52, 0x58: 0x4C,              // keypad 1 9 0 Enter
      0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37, 0xE7: 0x36,  // ⌃ ⇧ ⌥ ⌘ right ⌘
    ]
    for (usage, code) in expected {
      XCTAssertEqual(MacKey.code(for: UIKeyboardHIDUsage(rawValue: usage)!), code, "HID 0x\(String(usage, radix: 16))")
    }
    XCTAssertEqual(MacKey.modifier(for: .keyboardRightAlt), .option)
    XCTAssertEqual(MacKey.modifier(for: .keyboardLeftGUI), .command)
    XCTAssertNil(MacKey.modifier(for: .keyboardA))
  }

  // Bug: ⌘ then a capital or a shifted symbol sent without Shift, or as the wrong key.
  func testCharactersMapToKeysWithShift() {
    XCTAssertEqual(MacKey.code(for: "c")?.code, 0x08)
    XCTAssertEqual(MacKey.code(for: "c")?.shift, false)
    XCTAssertEqual(MacKey.code(for: "C")?.code, 0x08)
    XCTAssertEqual(MacKey.code(for: "C")?.shift, true)
    XCTAssertEqual(MacKey.code(for: "!")?.code, 0x12)
    XCTAssertEqual(MacKey.code(for: "!")?.shift, true)
    XCTAssertEqual(MacKey.code(for: "/")?.code, 0x2C)
    XCTAssertNil(MacKey.code(for: "é"), "no key types it: it goes as text")
  }

  // Bug: Fn with an arrow or a digit sending the arrow or the digit (the Mac's own fn
  // mapping happens in its keyboard, not for posted events).
  func testFunctionTurnsArrowsDigitsAndDelete() {
    XCTAssertEqual(MacKey.withFunction(MacKey.leftArrow), 0x73)   // Home
    XCTAssertEqual(MacKey.withFunction(MacKey.rightArrow), 0x77)  // End
    XCTAssertEqual(MacKey.withFunction(MacKey.upArrow), 0x74)     // Page Up
    XCTAssertEqual(MacKey.withFunction(MacKey.downArrow), 0x79)   // Page Down
    XCTAssertEqual(MacKey.withFunction(MacKey.one), 0x7A)         // F1
    XCTAssertEqual(MacKey.withFunction(MacKey.zero), 0x6D)        // F10
    XCTAssertEqual(MacKey.withFunction(MacKey.delete), 0x75)      // Forward Delete
    XCTAssertEqual(MacKey.withFunction(MacKey.a), MacKey.a)
  }

  // Bug: a key reaching the locked Mac's Screen Sharing as the wrong keysym (the
  // password typed into the login window going wrong, or Return not submitting).
  func testScreenSharingKeysymsForKeysAndText() {
    XCTAssertEqual(MacKey.keysym(for: MacKey.returnKey), 0xFF0D)
    XCTAssertEqual(MacKey.keysym(for: MacKey.delete), 0xFF08)
    XCTAssertEqual(MacKey.keysym(for: MacKey.forwardDelete), 0xFFFF)
    XCTAssertEqual(MacKey.keysym(for: MacKey.leftArrow), 0xFF51)
    XCTAssertEqual(MacKey.keysym(for: MacKey.upArrow), 0xFF52)
    XCTAssertEqual(MacKey.keysym(for: MacKey.functionKeys[0]), 0xFFBE)   // F1
    XCTAssertEqual(MacKey.keysym(for: MacKey.functionKeys[11]), 0xFFC9)  // F12
    XCTAssertEqual(MacKey.keysym(for: MacKey.keypad[0]), 0xFFB0)
    XCTAssertEqual(MacKey.keysym(for: MacKey.c), 0x63)
    XCTAssertEqual(MacKey.keysym(for: MacKey.slash), 0x2F)
    XCTAssertEqual(MacKey.keysym(for: MacKey.command), 0xFFEB)
    XCTAssertEqual(MacKey.keysym(for: "é"), 0xE9, "Latin-1 is its own keysym")
    XCTAssertEqual(MacKey.keysym(for: "日"), 0x0100_65E5)
    XCTAssertEqual(MacKey.keysym(for: "\n"), 0xFF0D)
    XCTAssertEqual(MacKey.keysym(for: "A"), 0x41)
  }

  // MARK: Scrolling (ledger: continuous phases, then momentum on lift)

  // Bug: phases out of order (no began, no ended) so Mac apps never rubber-band or settle.
  func testAGestureIsBeganChangedEnded() {
    var phaser = ScrollPhaser()
    let events = phaser.move(CGVector(dx: 0, dy: 5)) + phaser.move(CGVector(dx: 0, dy: 7)) + phaser.lift(velocity: .zero)
    XCTAssertEqual(events.map(\.phase), [.began, .changed, .ended])
    XCTAssertEqual(events.map(\.momentum), [.none, .none, .none])
    XCTAssertEqual(events.map(\.dy), [5, 7, 0])
    XCTAssertTrue(phaser.tick(1 / 60).isEmpty, "too slow for momentum")
  }

  // Bug: momentum that never ends, never decays, or carries a gesture phase.
  func testMomentumDecaysAndEndsOnce() {
    var phaser = ScrollPhaser()
    _ = phaser.move(CGVector(dx: 0, dy: -20))
    _ = phaser.lift(velocity: CGVector(dx: 0, dy: -1000))
    var momentum: [ScreenWire.ScrollEvent] = []
    for _ in 0..<2000 { momentum += phaser.tick(1 / 120) }
    XCTAssertEqual(momentum.first?.momentum, .began)
    XCTAssertEqual(momentum.last?.momentum, .ended)
    XCTAssertEqual(momentum.last?.dy, 0)
    XCTAssertEqual(momentum.filter { $0.momentum == .ended }.count, 1)
    XCTAssertTrue(momentum.allSatisfy { $0.phase == .none })
    let moving = momentum.dropLast().map(\.dy)
    XCTAssertTrue(zip(moving, moving.dropFirst()).allSatisfy { $0 < 0 && $1 < 0 && abs($1) < abs($0) }, "decaying, same direction")
    // UIScrollView's normal rate from 1000 pt/s coasts 1000 / (1000 × -ln 0.998) ≈ 499.5 pt,
    // less the tail under the 12 pt/s stop (≈ 6 pt).
    XCTAssertEqual(moving.reduce(0, +), -493.5, accuracy: 2)
    XCTAssertFalse(phaser.inMomentum)
  }

  // Bug: a touch during momentum leaving the Mac mid-momentum, or a new gesture without its own began.
  func testATouchEndsMomentumBeforeTheNextGesture() {
    var phaser = ScrollPhaser()
    _ = phaser.move(CGVector(dx: 10, dy: 0))
    _ = phaser.lift(velocity: CGVector(dx: 800, dy: 0))
    XCTAssertEqual(phaser.tick(1 / 60).first?.momentum, .began)
    let next = phaser.move(CGVector(dx: 3, dy: 0))
    XCTAssertEqual(next.map(\.momentum), [.ended, .none])
    XCTAssertEqual(next.map(\.phase), [.none, .began])
    XCTAssertTrue(phaser.interrupt().isEmpty, "ended once")
  }

  // Bug: a pinch that took over a scroll leaving the gesture open, or coasting on.
  func testCancelledGestureHasNoMomentum() {
    var phaser = ScrollPhaser()
    _ = phaser.move(CGVector(dx: 0, dy: 30))
    XCTAssertEqual(phaser.cancel().map(\.phase), [.cancelled])
    XCTAssertTrue(phaser.tick(1 / 60).isEmpty)
    XCTAssertTrue(phaser.lift(velocity: CGVector(dx: 0, dy: 900)).isEmpty)
  }
}
