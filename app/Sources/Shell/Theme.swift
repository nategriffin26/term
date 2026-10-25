import UIKit

/// A terminal color scheme. Colors are 0xRRGGBB; the core gets 0xAARRGGBB.
struct Theme: Identifiable, Hashable, Sendable {
  var name: String
  var foreground: UInt32
  var background: UInt32
  var cursor: UInt32
  /// ANSI 0-7 then bright 8-15.
  var palette: [UInt32]

  var id: String { name }

  func termTheme(boldIsBright: Bool) -> TermTheme {
    var t = TermTheme()
    t.fg = 0xFF00_0000 | foreground
    t.bg = 0xFF00_0000 | background
    t.cursor = 0xFF00_0000 | cursor
    withUnsafeMutableBytes(of: &t.palette) { raw in
      let slots = raw.bindMemory(to: UInt32.self)
      for (i, color) in palette.prefix(slots.count).enumerated() {
        slots[i] = 0xFF00_0000 | color
      }
    }
    t.bold_is_bright = boldIsBright ? 1 : 0
    return t
  }

  var backgroundColor: UIColor { UIColor(rgb: background) }
  var foregroundColor: UIColor { UIColor(rgb: foreground) }
  var isDark: Bool {
    let r = Double((background >> 16) & 0xFF), g = Double((background >> 8) & 0xFF), b = Double(background & 0xFF)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128
  }

  static func named(_ name: String) -> Theme {
    all.first { $0.name == name } ?? all[0]
  }

  static let all: [Theme] = [
    // Blink's default look: near-black, soft white text, Tango palette.
    Theme(name: "Term", foreground: 0xE6E6E6, background: 0x000000, cursor: 0xB0B0B0, palette: [
      0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
      0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    ]),
    Theme(name: "Tomorrow Night", foreground: 0xC5C8C6, background: 0x1D1F21, cursor: 0xC5C8C6, palette: [
      0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
      0x969896, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF,
    ]),
    Theme(name: "Dracula", foreground: 0xF8F8F2, background: 0x282A36, cursor: 0xF8F8F2, palette: [
      0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
      0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    ]),
    Theme(name: "Nord", foreground: 0xD8DEE9, background: 0x2E3440, cursor: 0xD8DEE9, palette: [
      0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
      0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
    ]),
    Theme(name: "Gruvbox Dark", foreground: 0xEBDBB2, background: 0x282828, cursor: 0xEBDBB2, palette: [
      0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
      0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    ]),
    Theme(name: "Catppuccin Mocha", foreground: 0xCDD6F4, background: 0x1E1E2E, cursor: 0xF5E0DC, palette: [
      0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
      0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
    ]),
    Theme(name: "Solarized Dark", foreground: 0x839496, background: 0x002B36, cursor: 0x93A1A1, palette: [
      0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
      0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]),
    Theme(name: "Solarized Light", foreground: 0x657B83, background: 0xFDF6E3, cursor: 0x586E75, palette: [
      0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
      0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]),
  ]
}

extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
              blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}
