import UIKit

/// The Screen's keyboard focus: the software keyboard's text and keys, and
/// every hardware key by its place on the keyboard (spec §4–§5). It is also
/// the target of the Edit row's Paste control.
///
/// Like the terminal, it presents a padded document before the caret so the
/// software keyboard repeats a held delete, and keeps composed text (kana
/// becoming kanji) until it is committed, then sends it.
@MainActor
final class ScreenKeyInput: UIView, UITextInput {
  weak var session: ScreenSession?
  private var markedText = ""
  private let deletePacer = HeldDeletePacer()
  private let repeater = KeyRepeater()
  /// Hardware keys down, with the Mac key each went down as.
  private var down: [UIKeyboardHIDUsage: UInt16] = [:]
  private var repeating: UIKeyboardHIDUsage?

  override init(frame: CGRect) {
    super.init(frame: frame)
    alpha = 0.01
    isUserInteractionEnabled = false
    pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: ScreenClipboard.pasteTypes)
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in self.updateKeyboardAppearance() }
    updateKeyboardAppearance()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var canBecomeFirstResponder: Bool { true }

  override func resignFirstResponder() -> Bool {
    releaseHardwareKeys()
    return super.resignFirstResponder()
  }

  // MARK: Traits

  var autocorrectionType: UITextAutocorrectionType = .no
  var autocapitalizationType: UITextAutocapitalizationType = .none
  var spellCheckingType: UITextSpellCheckingType = .no
  var smartQuotesType: UITextSmartQuotesType = .no
  var smartDashesType: UITextSmartDashesType = .no
  var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
  var inlinePredictionType: UITextInlinePredictionType = .no
  var keyboardType: UIKeyboardType = .default
  var keyboardAppearance: UIKeyboardAppearance = .dark
  var returnKeyType: UIReturnKeyType = .default

  private func updateKeyboardAppearance() {
    let appearance: UIKeyboardAppearance = traitCollection[AppThemeTrait.self].isDark ? .dark : .light
    guard appearance != keyboardAppearance else { return }
    keyboardAppearance = appearance
    if isFirstResponder { reloadInputViews() }
  }

  // MARK: Software keyboard

  var hasText: Bool { true }

  func insertText(_ text: String) {
    deletePacer.reset()
    session?.type(text)
  }

  func deleteBackward() {
    deletePacer.call { [weak self] in self?.session?.press(MacKey.delete) }
  }

  // MARK: Hardware keyboard

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var rest = Set<UIPress>()
    for press in presses {
      guard let key = press.key, let session else { rest.insert(press); continue }
      if let modifier = MacKey.modifier(for: key.keyCode) {
        session.hardwareModifier(modifier, down: true)
      } else if let code = MacKey.code(for: key.keyCode) {
        down[key.keyCode] = code
        session.keyDown(code)
        // The Mac repeats only keys its own keyboard holds: a held key here repeats its key down.
        if !key.modifierFlags.contains(.command) {
          repeating = key.keyCode
          repeater.start { [weak self] in self?.session?.keyDown(code) }
        }
      } else {
        rest.insert(press)
      }
    }
    if !rest.isEmpty { super.pressesBegan(rest, with: event) }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let rest = lift(presses)
    if !rest.isEmpty { super.pressesEnded(rest, with: event) }
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let rest = lift(presses)
    if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
  }

  /// Lets go of the Mac keys these presses held; returns the presses that were not the Mac's.
  private func lift(_ presses: Set<UIPress>) -> Set<UIPress> {
    var rest = Set<UIPress>()
    for press in presses {
      guard let key = press.key, let session else { rest.insert(press); continue }
      if let modifier = MacKey.modifier(for: key.keyCode) {
        session.hardwareModifier(modifier, down: false)
      } else if let code = down.removeValue(forKey: key.keyCode) {
        if repeating == key.keyCode { repeater.stop(); repeating = nil }
        session.keyUp(code)
        session.consumeOnce()
      } else {
        rest.insert(press)
      }
    }
    return rest
  }

  /// Focus left while keys were down: the Mac must not keep them pressed.
  private func releaseHardwareKeys() {
    repeater.stop()
    repeating = nil
    for code in down.values { session?.keyUp(code) }
    down = [:]
    for modifier in [ScreenWire.Modifiers.shift, .control, .option, .command] {
      session?.hardwareModifier(modifier, down: false)
    }
  }

  // MARK: Paste control

  override func paste(itemProviders: [NSItemProvider]) {
    session?.paste(itemProviders)
  }

  // MARK: UITextInput (a padded document with the composed text at its end)

  private static let padding = String(repeating: " ", count: 256)
  private var document: String { Self.padding + markedText }
  private var caret: Int { document.utf16.count }

  var selectedTextRange: UITextRange? {
    get { TextRange(caret, caret) }
    set {}
  }
  var markedTextRange: UITextRange? { markedText.isEmpty ? nil : TextRange(Self.padding.utf16.count, caret) }
  var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }
  weak var inputDelegate: UITextInputDelegate?

  var beginningOfDocument: UITextPosition { TextPosition(0) }
  var endOfDocument: UITextPosition { TextPosition(caret) }
  var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

  func text(in range: UITextRange) -> String? {
    guard let r = range as? TextRange else { return nil }
    let units = Array(document.utf16)
    let lo = min(r.from.offset, units.count), hi = min(r.to.offset, units.count)
    return String(utf16CodeUnits: Array(units[lo..<hi]), count: hi - lo)
  }

  func replace(_ range: UITextRange, withText text: String) {
    markedText = ""
    insertText(text)
  }

  func setMarkedText(_ text: String?, selectedRange: NSRange) {
    markedText = text ?? ""
  }

  func unmarkText() {
    let text = markedText
    markedText = ""
    if !text.isEmpty { insertText(text) }
  }

  func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
    guard let a = from as? TextPosition, let b = to as? TextPosition else { return nil }
    return TextRange(a.offset, b.offset)
  }

  func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
    guard let p = position as? TextPosition else { return nil }
    let n = p.offset + offset
    return n >= 0 && n <= caret ? TextPosition(n) : nil
  }

  func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
    self.position(from: position, offset: offset)
  }

  func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
    let a = (position as? TextPosition)?.offset ?? 0, b = (other as? TextPosition)?.offset ?? 0
    return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
  }

  func offset(from: UITextPosition, to: UITextPosition) -> Int {
    ((to as? TextPosition)?.offset ?? 0) - ((from as? TextPosition)?.offset ?? 0)
  }

  func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
    guard let r = range as? TextRange else { return nil }
    return direction == .left || direction == .up ? r.from : r.to
  }

  func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
    guard let p = position as? TextPosition else { return nil }
    return TextRange(p.offset, p.offset)
  }

  func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
  func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

  func firstRect(for range: UITextRange) -> CGRect { caretRect(for: endOfDocument) }
  func caretRect(for position: UITextPosition) -> CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
  func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
  func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
  func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
  func characterRange(at point: CGPoint) -> UITextRange? { nil }
}
