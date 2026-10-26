import UIKit

/// The app's haptics, few and light, for a finger working without looking:
/// a tap when a Smart Key goes down, a firm one when a held key takes effect
/// or a swipe action runs, a tick when a capsule switch changes. Settings ›
/// Appearance › App › Haptics turns them all off.
@MainActor enum Haptics {
  static func keyDown() { if on { light.impactOccurred(intensity: 0.7) } }
  static func firm() { if on { medium.impactOccurred() } }
  static func selection() { if on { selector.selectionChanged() } }

  private static var on: Bool { AppSettings.shared.haptics }
  private static let light = UIImpactFeedbackGenerator(style: .light)
  private static let medium = UIImpactFeedbackGenerator(style: .medium)
  private static let selector = UISelectionFeedbackGenerator()
}
