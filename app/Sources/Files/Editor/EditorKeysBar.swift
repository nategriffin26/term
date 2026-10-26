import Runestone
import UIKit

/// Keys the software keyboard lacks for code, above it while editing: Tab
/// and outdent, caret arrows, the symbols code is made of, undo, redo, find
/// and hide keyboard.
final class EditorKeysBar: UIInputView {
  private weak var textView: TextView?
  private let onFind: () -> Void

  private static let symbols = ["{", "}", "(", ")", "[", "]", "<", ">", "=", "\"", "'", "/", "\\", "|", "&", ";", ":",
                                "_", "-", "+", "*", "$", "#", "!", "?", "~", "`", "%", "^", "@", "."]

  init(textView: TextView, onFind: @escaping () -> Void) {
    self.textView = textView
    self.onFind = onFind
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .default)
    backgroundColor = Chrome.UI.raised
    allowsSelfSizing = true

    let keys = UIStackView()
    keys.axis = .horizontal
    keys.spacing = 2
    keys.addArrangedSubview(button(symbol: "arrow.right.to.line", label: "Tab") { [weak self] in self?.textView?.insertText("\t") })
    keys.addArrangedSubview(button(symbol: "arrow.left.to.line", label: "Outdent") { [weak self] in self?.textView?.shiftLeft() })
    for (symbol, direction) in [("arrow.left", UITextLayoutDirection.left), ("arrow.right", .right), ("arrow.up", .up), ("arrow.down", .down)] {
      keys.addArrangedSubview(button(symbol: symbol, label: "\(direction)") { [weak self] in self?.move(direction) })
    }
    for s in Self.symbols {
      keys.addArrangedSubview(button(text: s) { [weak self] in self?.textView?.insertText(s) })
    }
    let scroll = UIScrollView()
    scroll.showsHorizontalScrollIndicator = false
    scroll.addSubview(keys)

    let fixed = UIStackView(arrangedSubviews: [
      button(symbol: "arrow.uturn.backward", label: "Undo") { [weak self] in self?.textView?.undoManager?.undo() },
      button(symbol: "arrow.uturn.forward", label: "Redo") { [weak self] in self?.textView?.undoManager?.redo() },
      button(symbol: "magnifyingglass", label: "Find") { [weak self] in self?.onFind() },
      button(symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard") { [weak self] in _ = self?.textView?.resignFirstResponder() },
    ])
    fixed.spacing = 2
    let hairline = UIView()
    hairline.backgroundColor = Chrome.UI.line2

    for v in [scroll, keys, fixed, hairline] { v.translatesAutoresizingMaskIntoConstraints = false }
    addSubview(scroll)
    addSubview(fixed)
    addSubview(hairline)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 44),
      hairline.topAnchor.constraint(equalTo: topAnchor),
      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
      scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.trailingAnchor.constraint(equalTo: fixed.leadingAnchor, constant: -4),
      fixed.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
      fixed.centerYAnchor.constraint(equalTo: centerYAnchor),
      keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private func move(_ direction: UITextLayoutDirection) {
    guard let textView, let range = textView.selectedTextRange,
          let to = textView.position(from: direction == .left || direction == .up ? range.start : range.end, in: direction, offset: 1)
    else { return }
    textView.selectedTextRange = textView.textRange(from: to, to: to)
  }

  private func button(text: String? = nil, symbol: String? = nil, label: String? = nil, _ action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = Chrome.UI.fg2
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    if let text {
      config.attributedTitle = AttributedString(text, attributes: AttributeContainer([.font: Chrome.uiMono(.title)]))
    }
    if let symbol {
      config.image = UIImage(systemName: symbol, withConfiguration: Chrome.uiSymbol(.control))
    }
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in
      UIDevice.current.playInputClick()
      action()
    })
    button.accessibilityLabel = label ?? text
    button.widthAnchor.constraint(equalToConstant: 38).isActive = true
    button.heightAnchor.constraint(equalToConstant: 40).isActive = true
    return button
  }
}

extension EditorKeysBar: UIInputViewAudioFeedback {
  var enableInputClicksWhenVisible: Bool { true }
}
