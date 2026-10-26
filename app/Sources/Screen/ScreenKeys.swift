import UIKit

/// macOS virtual key codes (kVK_*, Carbon's HIToolbox Events.h): what a
/// KeyEvent carries. Codes name physical keys on an ANSI keyboard; the Mac
/// applies its own layout.
enum MacKey {
  static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02, f: UInt16 = 0x03, h: UInt16 = 0x04
  static let g: UInt16 = 0x05, z: UInt16 = 0x06, x: UInt16 = 0x07, c: UInt16 = 0x08, v: UInt16 = 0x09
  static let isoSection: UInt16 = 0x0A
  static let b: UInt16 = 0x0B, q: UInt16 = 0x0C, w: UInt16 = 0x0D, e: UInt16 = 0x0E, r: UInt16 = 0x0F
  static let y: UInt16 = 0x10, t: UInt16 = 0x11
  static let one: UInt16 = 0x12, two: UInt16 = 0x13, three: UInt16 = 0x14, four: UInt16 = 0x15
  static let six: UInt16 = 0x16, five: UInt16 = 0x17, equal: UInt16 = 0x18, nine: UInt16 = 0x19
  static let seven: UInt16 = 0x1A, minus: UInt16 = 0x1B, eight: UInt16 = 0x1C, zero: UInt16 = 0x1D
  static let rightBracket: UInt16 = 0x1E, o: UInt16 = 0x1F, u: UInt16 = 0x20, leftBracket: UInt16 = 0x21
  static let i: UInt16 = 0x22, p: UInt16 = 0x23, returnKey: UInt16 = 0x24, l: UInt16 = 0x25, j: UInt16 = 0x26
  static let quote: UInt16 = 0x27, k: UInt16 = 0x28, semicolon: UInt16 = 0x29, backslash: UInt16 = 0x2A
  static let comma: UInt16 = 0x2B, slash: UInt16 = 0x2C, n: UInt16 = 0x2D, m: UInt16 = 0x2E, period: UInt16 = 0x2F
  static let tab: UInt16 = 0x30, space: UInt16 = 0x31, grave: UInt16 = 0x32, delete: UInt16 = 0x33
  static let escape: UInt16 = 0x35
  static let rightCommand: UInt16 = 0x36, command: UInt16 = 0x37, shift: UInt16 = 0x38, capsLock: UInt16 = 0x39
  static let option: UInt16 = 0x3A, control: UInt16 = 0x3B, rightShift: UInt16 = 0x3C
  static let rightOption: UInt16 = 0x3D, rightControl: UInt16 = 0x3E, function: UInt16 = 0x3F
  static let keypadDecimal: UInt16 = 0x41, keypadMultiply: UInt16 = 0x43, keypadPlus: UInt16 = 0x45
  static let keypadClear: UInt16 = 0x47, keypadDivide: UInt16 = 0x4B, keypadEnter: UInt16 = 0x4C
  static let keypadMinus: UInt16 = 0x4E, keypadEquals: UInt16 = 0x51
  static let keypad: [UInt16] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
  static let jisYen: UInt16 = 0x5D, jisUnderscore: UInt16 = 0x5E, jisKeypadComma: UInt16 = 0x5F
  static let jisEisu: UInt16 = 0x66, jisKana: UInt16 = 0x68
  static let help: UInt16 = 0x72, home: UInt16 = 0x73, pageUp: UInt16 = 0x74, forwardDelete: UInt16 = 0x75
  static let end: UInt16 = 0x77, pageDown: UInt16 = 0x79
  static let leftArrow: UInt16 = 0x7B, rightArrow: UInt16 = 0x7C, downArrow: UInt16 = 0x7D, upArrow: UInt16 = 0x7E
  /// F1 to F20.
  static let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                                       0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]

  /// The key for a letter, digit or ASCII symbol on a US keyboard, with
  /// whether it needs Shift: what a toolbar shortcut (⌘ then C) presses.
  static func code(for character: Character) -> (code: UInt16, shift: Bool)? {
    guard let ascii = character.asciiValue else { return nil }
    let lower = Character(UnicodeScalar(ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii))
    if let code = unshifted[lower] { return (code, ascii >= 65 && ascii <= 90) }
    if let base = shifted[character], let code = unshifted[base] { return (code, true) }
    return nil
  }

  private static let unshifted: [Character: UInt16] = [
    "a": a, "b": b, "c": c, "d": d, "e": e, "f": f, "g": g, "h": h, "i": i, "j": j, "k": k, "l": l, "m": m,
    "n": n, "o": o, "p": p, "q": q, "r": r, "s": s, "t": t, "u": u, "v": v, "w": w, "x": x, "y": y, "z": z,
    "1": one, "2": two, "3": three, "4": four, "5": five, "6": six, "7": seven, "8": eight, "9": nine, "0": zero,
    "-": minus, "=": equal, "[": leftBracket, "]": rightBracket, "\\": backslash, ";": semicolon, "'": quote,
    ",": comma, ".": period, "/": slash, "`": grave, " ": space, "\t": tab, "\r": returnKey, "\n": returnKey,
  ]

  private static let shifted: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
  ]

  /// Fn with an arrow is Home, End, Page Up or Page Down, as on a Mac
  /// laptop; Fn with a digit is F1 to F10.
  static func withFunction(_ code: UInt16) -> UInt16 {
    switch code {
    case leftArrow: home
    case rightArrow: end
    case upArrow: pageUp
    case downArrow: pageDown
    case delete: forwardDelete
    default:
      if let digit = [one, two, three, four, five, six, seven, eight, nine, zero].firstIndex(of: code) {
        functionKeys[digit]
      } else {
        code
      }
    }
  }

  /// A hardware key's code on the Mac, by its HID usage (its place on the keyboard).
  static func code(for usage: UIKeyboardHIDUsage) -> UInt16? {
    let raw = usage.rawValue
    switch raw {
    case 0x04...0x1D: return letters[raw - 0x04]
    case 0x1E...0x27: return digits[raw - 0x1E]
    case 0x3A...0x45: return functionKeys[raw - 0x3A]
    case 0x68...0x6F: return functionKeys[12 + raw - 0x68]
    case 0x59...0x62: return keypad[(raw - 0x59 + 1) % 10]
    default: return hid[raw]
    }
  }

  /// A..Z in HID order.
  private static let letters: [UInt16] = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z]
  /// 1..9, 0 in HID order.
  private static let digits: [UInt16] = [one, two, three, four, five, six, seven, eight, nine, zero]

  private static let hid: [Int: UInt16] = [
    0x28: returnKey, 0x29: escape, 0x2A: delete, 0x2B: tab, 0x2C: space, 0x2D: minus, 0x2E: equal,
    0x2F: leftBracket, 0x30: rightBracket, 0x31: backslash, 0x32: backslash, 0x33: semicolon, 0x34: quote,
    0x35: grave, 0x36: comma, 0x37: period, 0x38: slash, 0x39: capsLock,
    0x49: help, 0x4A: home, 0x4B: pageUp, 0x4C: forwardDelete, 0x4D: end, 0x4E: pageDown,
    0x4F: rightArrow, 0x50: leftArrow, 0x51: downArrow, 0x52: upArrow,
    0x53: keypadClear, 0x54: keypadDivide, 0x55: keypadMultiply, 0x56: keypadMinus, 0x57: keypadPlus,
    0x58: keypadEnter, 0x63: keypadDecimal, 0x64: isoSection, 0x67: keypadEquals, 0x85: jisKeypadComma,
    0x87: jisUnderscore, 0x89: jisYen, 0x90: jisKana, 0x91: jisEisu,
    0xE0: control, 0xE1: shift, 0xE2: option, 0xE3: command,
    0xE4: rightControl, 0xE5: rightShift, 0xE6: rightOption, 0xE7: rightCommand,
  ]

  /// The modifier a hardware modifier key holds, if it is one.
  static func modifier(for usage: UIKeyboardHIDUsage) -> ScreenWire.Modifiers? {
    switch usage.rawValue {
    case 0xE0, 0xE4: .control
    case 0xE1, 0xE5: .shift
    case 0xE2, 0xE6: .option
    case 0xE3, 0xE7: .command
    default: nil
    }
  }

  // MARK: Screen Sharing (RFB keysyms, X11 keysymdef.h)

  /// A Mac key as the X11 keysym Screen Sharing takes: the character an
  /// unshifted US key types, or the named key's keysym.
  static func keysym(for code: UInt16) -> UInt32? {
    if let named = namedKeysyms[code] { return named }
    if let f = functionKeys.firstIndex(of: code) { return 0xFFBE + UInt32(f) }
    if let digit = keypad.firstIndex(of: code) { return 0xFFB0 + UInt32(digit) }
    if let character = unshifted.first(where: { $0.value == code && $0.key.asciiValue.map { $0 > 0x20 } == true })?.key {
      return UInt32(character.asciiValue!)
    }
    return nil
  }

  /// A typed character: Latin-1 keysyms are the code point, the rest 0x01000000 + it.
  static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
    switch scalar.value {
    case 0x0A, 0x0D: 0xFF0D
    case 0x09: 0xFF09
    case 0x20...0x7E, 0xA0...0xFF: scalar.value
    default: 0x0100_0000 | scalar.value
    }
  }

  /// The keysyms Screen Sharing holds for each modifier (Fn has none).
  static let modifierKeysyms: [(ScreenWire.Modifiers, UInt32)] = [
    (.shift, 0xFFE1), (.control, 0xFFE3), (.option, 0xFFE9), (.command, 0xFFEB),
  ]

  private static let namedKeysyms: [UInt16: UInt32] = [
    returnKey: 0xFF0D, tab: 0xFF09, space: 0x20, delete: 0xFF08, escape: 0xFF1B, forwardDelete: 0xFFFF,
    home: 0xFF50, end: 0xFF57, pageUp: 0xFF55, pageDown: 0xFF56, help: 0xFF6A,
    leftArrow: 0xFF51, upArrow: 0xFF52, rightArrow: 0xFF53, downArrow: 0xFF54,
    keypadEnter: 0xFF8D, keypadDecimal: 0xFFAE, keypadMultiply: 0xFFAA, keypadPlus: 0xFFAB,
    keypadMinus: 0xFFAD, keypadDivide: 0xFFAF, keypadEquals: 0xFFBD, keypadClear: 0xFF0B,
    shift: 0xFFE1, rightShift: 0xFFE2, control: 0xFFE3, rightControl: 0xFFE4,
    option: 0xFFE9, rightOption: 0xFFEA, command: 0xFFEB, rightCommand: 0xFFEC, capsLock: 0xFFE5,
  ]
}

/// The toolbar's modifier keys (§4): one tap holds a key for the next key,
/// click or drag; a second tap within `lockWindow` locks it down; a tap on
/// a locked key, or on an armed one later, lets it go. Keys held on a
/// hardware keyboard count too, so both stay in sync on the Mac.
struct ModifierLatch: Equatable {
  enum State: Equatable { case off, once, locked }

  static let lockWindow: TimeInterval = 0.35

  private var states: [UInt8: State] = [:]
  private var armedAt: [UInt8: TimeInterval] = [:]
  /// Held on a hardware keyboard right now.
  private(set) var hardware: ScreenWire.Modifiers = []

  func state(_ key: ScreenWire.Modifiers) -> State { states[key.rawValue] ?? .off }

  /// What the Mac holds down.
  var held: ScreenWire.Modifiers {
    var out = hardware
    for (raw, state) in states where state != .off { out.insert(ScreenWire.Modifiers(rawValue: raw)) }
    return out
  }

  mutating func tap(_ key: ScreenWire.Modifiers, at now: TimeInterval) {
    switch state(key) {
    case .off:
      states[key.rawValue] = .once
      armedAt[key.rawValue] = now
    case .once:
      let quick = now - (armedAt[key.rawValue] ?? -.infinity) <= Self.lockWindow
      states[key.rawValue] = quick ? .locked : .off
    case .locked:
      states[key.rawValue] = .off
    }
  }

  /// After a key, click or drag: the keys held once let go; locked ones stay.
  mutating func consumeOnce() {
    for (raw, state) in states where state == .once { states[raw] = .off }
  }

  mutating func hardware(_ key: ScreenWire.Modifiers, down: Bool) {
    if down { hardware.insert(key) } else { hardware.remove(key) }
  }

  /// Everything off: the connection ended, and the Mac released them.
  mutating func reset() { self = ModifierLatch() }
}
