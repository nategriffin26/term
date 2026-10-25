import UIKit

/// The software keyboard repeats a held delete key only when the text input
/// has text before the caret, and only a UITextInput says so (measured on
/// iOS 27: a bare UIKeyInput, or a UITextInput whose document is empty, gets
/// one `deleteBackward` per press). The terminal has no document, so this
/// presents `padding` before the caret, followed by whatever is being
/// composed; composed text is typed into the session when it is committed.
final class TextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class TextRange: UITextRange {
    let from: TextPosition
    let to: TextPosition
    init(_ from: Int, _ to: Int) {
        self.from = TextPosition(min(from, to))
        self.to = TextPosition(max(from, to))
    }
    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.offset == to.offset }
}

extension TerminalView: UITextInput {
    static let padding = String(repeating: " ", count: 256)
    private var document: String { Self.padding + markedText }
    private var caret: Int { document.utf16.count }

    var selectedTextRange: UITextRange? {
        get { TextRange(caret, caret) }
        set {}
    }
    var markedTextRange: UITextRange? { markedText.isEmpty ? nil : TextRange(Self.padding.utf16.count, caret) }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }

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
        return n >= 0 && n <= document.utf16.count ? TextPosition(n) : nil
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
        switch direction {
        case .left, .up: return r.from
        default: return r.to
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? TextPosition else { return nil }
        return TextRange(p.offset, p.offset)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: endOfDocument) }
    func caretRect(for position: UITextPosition) -> CGRect { rect(col: snapshot.cursorCol, row: snapshot.cursorRow) }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }
}
