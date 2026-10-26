import UIKit

/// Keeps UIKit's accessory attached while focus passes between terminals.
/// Each terminal retains its own modifiers, paste target and dictation controls.
@MainActor
final class TerminalInputAccessory: UIInputView {
  private(set) var bar: SmartKeysBar?

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: SmartKeysBar.height), inputViewStyle: .default)
    allowsSelfSizing = true
    backgroundColor = .clear
    registerForTraitChanges([UITraitVerticalSizeClass.self]) { (view: TerminalInputAccessory, _) in
      view.invalidateIntrinsicContentSize()
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func show(_ bar: SmartKeysBar) {
    guard self.bar !== bar else { return }
    let previous = self.bar
    self.bar = bar
    bar.frame = bounds
    addSubview(bar)
    previous?.removeFromSuperview()
    invalidateIntrinsicContentSize()
  }

  func remove(_ bar: SmartKeysBar) {
    guard self.bar === bar else { return }
    bar.removeFromSuperview()
    self.bar = nil
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: SmartKeysBar.height(for: traitCollection))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    bar?.frame = bounds
  }
}
