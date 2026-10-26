import SwiftUI
import UIKit

/// Term's design system. Every surface of the app's chrome (menu panel,
/// docks, Settings, Files, Smart Keys, banners, HUD, history) takes its
/// colours, type, symbols, spacing, corners, material and motion from here
/// and its controls from Controls.swift. A surface that needs something new
/// adds it here first, never a literal in place.
///
/// - Colour: `AppTheme`, derived from the terminal theme (Match Terminal, on
///   by default) or Dusk's (Match off). Text by importance: fg, fg2,
///   muted, faint. Washes and hairlines are the text colour at fixed
///   opacities (fill < fill2 < fill3; line, line2), so light themes work
///   with no extra code. No literal colours, no white or black, no system blue.
///   Swipe actions fill with `swipeBad` and `swipeAccent`: their labels are always white.
/// - State: `needsYou` (the accent) is the one loud signal: a filled pill on
///   a row and the count on the dock and the tmux tab. `done` is the accent
///   as a check and a word, `working` a ring in fg, `failed` is bad. The
///   accent marks nothing else but the open tab's icon and switches that
///   are on. `folder` (ANSI blue) marks folders in Files.
/// - Type: SF Pro for words, SF Mono for machine facts (session, host and
///   file names, paths, commands, sizes, keys). Four steps: title 17 (page
///   titles), body 15 (rows, tabs, buttons), secondary 13 (second lines,
///   section labels, values, ages, states), caption 11 (badges, fine print),
///   at Text Size Default; Small and Large move each step 1 and 2 points
///   (caption stays 11 at Small). Keys (Smart Keys, the editor's bar) and
///   the fixed-size dock and switch HUD pin Default, like the system
///   keyboard. Weights: regular; medium for
///   controls; semibold for titles, group heads and the chosen item.
/// - Symbols: one weight (medium) at four sizes: inline 13, control 17,
///   dock 20, hero 34; inline and control follow Text Size. Outline glyphs;
///   the `.fill` variant only for the chosen tab and folders in Files.
/// - Space: 4, 8, 12, 16, 24. Rows are 50 tall, controls 36, circle buttons
///   40, and every target at least 44.
/// - Corners: capsules for controls and pills; groups 22, tiles 16, file
///   thumbnails 6, the panel 32 (concentric with the screen where it nears its corners).
/// - Material: the panel and the docks are Liquid Glass tinted with the
///   theme's ground (`glass`, `GlassView`), Tinted or Clear per the Glass
///   setting. Nothing on glass is glass again:
///   controls on it use fills. Lists are inset groups of `fill` whose rows
///   are split by `line` from the text's leading edge.
/// - Motion: `spring` for panels, pages, selection and layout; `quick` for
///   presses and checks; `fade` for content that swaps in place.
enum Chrome {
  // MARK: Colour. Read inside a SwiftUI body, they redraw it when the app theme changes.

  @MainActor static var bg: Color { theme.bg.color }
  @MainActor static var raised: Color { theme.raised.color }
  @MainActor static var fg: Color { theme.fg.color }
  @MainActor static var fg2: Color { theme.fg2.color }
  @MainActor static var muted: Color { theme.muted.color }
  @MainActor static var faint: Color { theme.faint.color }
  @MainActor static var fill: Color { theme.fill.color }
  @MainActor static var fill2: Color { theme.fill2.color }
  @MainActor static var fill3: Color { theme.fill3.color }
  @MainActor static var line: Color { theme.line.color }
  @MainActor static var line2: Color { theme.line2.color }
  @MainActor static var accent: Color { theme.accent.color }
  @MainActor static var onAccent: Color { theme.onAccent.color }
  @MainActor static var ok: Color { theme.ok.color }
  @MainActor static var warn: Color { theme.warn.color }
  @MainActor static var bad: Color { theme.bad.color }
  @MainActor static var overlay: Color { theme.overlay.color }
  @MainActor static var folder: Color { theme.folder.color }

  // States.
  @MainActor static var needsYou: Color { accent }
  @MainActor static var done: Color { accent }
  @MainActor static var working: Color { fg }
  @MainActor static var failed: Color { bad }

  // Swipe actions: white labels on every theme (see AppTheme.swipeBad).
  @MainActor static var swipeBad: Color { theme.swipeBad.color }
  @MainActor static var swipeAccent: Color { theme.swipeAccent.color }

  /// Whether system controls (switches, keyboards, bars) should be dark.
  @MainActor static var isDark: Bool { theme.isDark }
  @MainActor static var colorScheme: ColorScheme { theme.isDark ? .dark : .light }

  @MainActor private static var theme: AppTheme { AppSettings.shared.appTheme }

  /// UIKit twins of the colours above: dynamic, resolved against the
  /// window scene's AppThemeTrait, so views refresh when it changes. A
  /// CGColor taken from them (layer borders) must be re-taken on that trait's change.
  enum UI {
    static var bg: UIColor { tone(\.bg) }
    static var raised: UIColor { tone(\.raised) }
    static var fg: UIColor { tone(\.fg) }
    static var fg2: UIColor { tone(\.fg2) }
    static var muted: UIColor { tone(\.muted) }
    static var faint: UIColor { tone(\.faint) }
    static var fill2: UIColor { tone(\.fill2) }
    static var fill3: UIColor { tone(\.fill3) }
    static var line: UIColor { tone(\.line) }
    static var line2: UIColor { tone(\.line2) }
    static var accent: UIColor { tone(\.accent) }
    static var onAccent: UIColor { tone(\.onAccent) }
    static var bad: UIColor { tone(\.bad) }
    static var overlay: UIColor { tone(\.overlay) }

    private static func tone(_ key: KeyPath<AppTheme, AppTheme.Tone> & Sendable) -> UIColor {
      UIColor { traits in traits[AppThemeTrait.self][keyPath: key].uiColor }
    }
  }

  // MARK: Type

  enum TextStep: CGFloat {
    case title = 17, body = 15, secondary = 13, caption = 11

    /// The step's size at a Text Size setting: Small and Large move every
    /// step by 1 and 2 points, but caption never goes under 11.
    func size(in textSize: TextSize) -> CGFloat {
      switch textSize {
      case .small: max(rawValue - 1, TextStep.caption.rawValue)
      case .standard: rawValue
      case .large: rawValue + 2
      }
    }
  }

  /// SF Pro, for words, at the Text Size setting.
  @MainActor static func font(_ step: TextStep, _ weight: Font.Weight = .regular) -> Font {
    .system(size: step.size(in: textSize), weight: weight)
  }

  /// SF Mono, for machine facts, at the Text Size setting.
  @MainActor static func mono(_ step: TextStep, _ weight: Font.Weight = .regular) -> Font {
    .system(size: step.size(in: textSize), weight: weight, design: .monospaced)
  }

  /// `size` pins a size for keys, which stay put like the system keyboard's.
  @MainActor static func uiFont(_ step: TextStep, _ weight: UIFont.Weight = .regular, size: TextSize? = nil) -> UIFont {
    .systemFont(ofSize: step.size(in: size ?? textSize), weight: weight)
  }

  @MainActor static func uiMono(_ step: TextStep, _ weight: UIFont.Weight = .regular, size: TextSize? = nil) -> UIFont {
    .monospacedSystemFont(ofSize: step.size(in: size ?? textSize), weight: weight)
  }

  @MainActor private static var textSize: TextSize { AppSettings.shared.textSize }

  // MARK: Symbols

  enum SymbolStep: CGFloat {
    case inline = 13, control = 17, dock = 20, hero = 34

    /// Inline and control symbols sit beside text and follow its size; dock and hero stay.
    func size(in textSize: TextSize) -> CGFloat {
      guard self == .inline || self == .control else { return rawValue }
      return switch textSize {
      case .small: rawValue - 1
      case .standard: rawValue
      case .large: rawValue + 2
      }
    }
  }

  @MainActor static func symbol(_ step: SymbolStep) -> Font { .system(size: step.size(in: textSize), weight: .medium) }

  @MainActor static func uiSymbol(_ step: SymbolStep, size: TextSize? = nil) -> UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(pointSize: step.size(in: size ?? textSize), weight: .medium)
  }

  // MARK: Space, sizes, corners

  enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
  }

  enum Size {
    static let row: CGFloat = 50
    static let control: CGFloat = 36
    static let circle: CGFloat = 40
    static let target: CGFloat = 44
  }

  enum Radius {
    static let group: CGFloat = 22
    static let tile: CGFloat = 16
    static let panel: CGFloat = 32
    static let thumb: CGFloat = 6
  }

  // MARK: Material

  /// How much of the theme's ground tints glass. Tinted: enough that text on
  /// it reads over a busy terminal, little enough that the terminal still
  /// shows (c-glass). Clear: the terminal shows through, text still reads.
  static func glassTint(_ style: GlassStyle) -> CGFloat {
    switch style {
    case .clear: 0.35
    case .tinted: 0.75
    }
  }

  /// Liquid Glass tinted with the theme's ground, for SwiftUI's `glassEffect`.
  @MainActor static var glass: Glass {
    let style = AppSettings.shared.glassStyle
    return (style == .clear ? Glass.clear : .regular).tint(theme.bg.color.opacity(glassTint(style)))
  }

  // MARK: Motion

  static let spring = Animation.spring(duration: 0.4, bounce: 0.12)
  static let quick = Animation.snappy(duration: 0.22)
  static let fade = Animation.easeOut(duration: 0.2)

  /// UIKit's twin of `spring`, for UIViewPropertyAnimator(duration: springDuration, timingParameters:).
  static let springDuration: TimeInterval = 0.42
  @MainActor static var springTiming: UISpringTimingParameters { UISpringTimingParameters(duration: springDuration, bounce: 0.12) }
  /// UIKit's twin of `fade`'s curve; the duration is the caller's.
  @MainActor static var fadeTiming: UICubicTimingParameters { UICubicTimingParameters(animationCurve: .easeOut) }
}

/// Liquid Glass tinted with the theme's ground of its window scene, for
/// UIKit surfaces (the panel, the dock). Its content goes in `contentView`.
final class GlassView: UIVisualEffectView {
  init() {
    super.init(effect: nil)
    registerForTraitChanges([AppThemeTrait.self, ChromeStyleTrait.self]) { (self: Self, _) in
      if self.effect != nil { self.effect = self.glass() }
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Shows or hides the glass; inside an animation block it materializes or dissolves.
  var isGlassShown: Bool {
    get { effect != nil }
    set { effect = newValue ? glass() : nil }
  }

  private func glass() -> UIGlassEffect {
    let theme = traitCollection[AppThemeTrait.self]
    let style = traitCollection[ChromeStyleTrait.self].glass
    let effect = UIGlassEffect(style: style == .clear ? .clear : .regular)
    effect.tintColor = theme.bg.uiColor.withAlphaComponent(Chrome.glassTint(style))
    return effect
  }
}

/// The chrome's Glass and Text Size settings, handed to each window scene's
/// UIKit views beside AppThemeTrait: glass and fonts set once re-take on its change.
struct ChromeStyle: Hashable, Sendable {
  var glass: GlassStyle = .tinted
  var textSize: TextSize = .standard
}

struct ChromeStyleTrait: UITraitDefinition {
  static let defaultValue = ChromeStyle()
  static let affectsColorAppearance = false
}

extension Color {
  init(hex: UInt32) {
    self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}
