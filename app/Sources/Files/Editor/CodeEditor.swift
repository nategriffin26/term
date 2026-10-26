import Runestone
import SwiftUI
import UIKit

/// Lets the viewer's header reach the editor: its text, find, dirty state.
@MainActor
final class EditorHandle {
  weak var controller: CodeEditorController?

  var text: String? { controller?.textView.text }
  func find() { controller?.find() }
  /// After a save: the text may have changed while it was being written.
  func refreshDirty() { controller?.updateDirty() }
}

/// The Runestone editor for a TextDocument: highlighted, numbered, in the
/// terminal's font and colours. Read-only until `editing`.
struct CodeEditor: UIViewControllerRepresentable {
  let document: TextDocument
  var editing: Bool
  var wrap: Bool
  /// 1-based line to show and mark on open (a search hit).
  var line: Int?
  let handle: EditorHandle
  var onSave: () -> Void

  func makeUIViewController(context: Context) -> CodeEditorController {
    let controller = CodeEditorController(document: document, line: line)
    handle.controller = controller
    return controller
  }

  func updateUIViewController(_ controller: CodeEditorController, context: Context) {
    controller.onSave = onSave
    controller.setEditing(editing)
    controller.textView.isLineWrappingEnabled = wrap
    controller.reloadIfNeeded()
  }
}

// Runestone predates Swift concurrency; it calls its delegate on the main thread.
final class CodeEditorController: UIViewController, @preconcurrency TextViewDelegate {
  let textView = TextView()
  var onSave: () -> Void = {}
  private let document: TextDocument
  private var line: Int?
  private var shownRevision = -1
  /// Our own replacements pass through the delegate again; let them.
  private var applying = false
  private var fontSize: CGFloat
  private var pinchStartSize: CGFloat = 0
  /// The opened-at line is tinted until the first edit.
  private var lineMarked = false

  private static let fontSizeKey = "editorFontSize"

  init(document: TextDocument, line: Int?) {
    self.document = document
    self.line = line
    let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
    fontSize = saved > 0 ? saved : AppSettings.shared.fontSize
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func loadView() {
    view = textView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let theme = makeTheme()
    textView.theme = theme
    textView.backgroundColor = theme.background
    textView.editorDelegate = self
    textView.isEditable = false
    // Line numbers come with the text: an empty editor numbered "1" reads as
    // an empty file while a large one parses.
    textView.showLineNumbers = false
    textView.lineSelectionDisplayType = .line
    textView.gutterLeadingPadding = 10
    textView.gutterTrailingPadding = 8
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 2, bottom: 10, right: 10)
    textView.verticalOverscrollFactor = 0.3
    textView.autocorrectionType = .no
    textView.autocapitalizationType = .none
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.spellCheckingType = .no
    // The editor is drawn in the terminal theme, so the keyboard follows it.
    textView.keyboardAppearance = AppSettings.shared.theme.isDark ? .dark : .light
    textView.characterPairs = [Pair("{", "}"), Pair("[", "]"), Pair("(", ")")]
    textView.characterPairTrailingComponentDeletionMode = .immediatelyFollowingLeadingComponent
    textView.isFindInteractionEnabled = true
    textView.indentStrategy = switch document.indentation {
    case .tabs: .tab(length: 4)
    case .spaces(let n): .space(length: n)
    }
    textView.lineEndings = document.lineBreak == .crlf ? .crlf : .lf
    textView.inputAccessoryView = EditorKeysBar(textView: textView, onFind: { [weak self] in self?.find() })
    textView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
    reloadIfNeeded()
  }

  /// Shows the document's baseline when it is new or was reloaded from the host.
  func reloadIfNeeded() {
    guard isViewLoaded, shownRevision != document.revision else { return }
    shownRevision = document.revision
    let box = StateBox(text: document.baseline, theme: textView.theme,
                       language: document.language.flatMap { EditorLanguages.shared.language($0) })
    let revision = shownRevision
    // Parsing a few MB takes a moment; keep it off the main thread.
    DispatchQueue.global(qos: .userInitiated).async {
      box.build()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.shownRevision == revision, let state = box.state else { return }
        self.textView.setState(state)
        self.textView.showLineNumbers = true
        self.updateDirty()
        if let line = self.line {
          self.line = nil
          self.mark(line: line)
        }
      }
    }
  }

  func setEditing(_ editing: Bool) {
    let editable = editing && document.readOnlyReason == nil
    guard textView.isEditable != editable else { return }
    textView.isEditable = editable
    if editable {
      textView.becomeFirstResponder()
    } else if textView.isFirstResponder {
      textView.resignFirstResponder()
    }
  }

  func find() {
    textView.findInteraction?.presentFindNavigator(showingReplace: textView.isEditable)
  }

  /// Dirty when the text differs from the baseline; equal lengths are compared
  /// in full, so undoing back to the saved text clears it.
  func updateDirty() {
    let text = textView.text
    let baseline = document.baseline
    let dirty = text.utf16.count != baseline.utf16.count || text != baseline
    if document.isDirty != dirty { document.isDirty = dirty }
  }

  private func mark(line: Int) {
    let index = max(0, line - 1)
    guard let start = textView.location(at: TextLocation(lineNumber: index, column: 0)) else { return }
    let end = textView.location(at: TextLocation(lineNumber: index + 1, column: 0)) ?? (textView.text as NSString).length
    _ = textView.goToLine(index)
    textView.highlightedRanges = [HighlightedRange(range: NSRange(location: start, length: end - start),
                                                    color: Chrome.UI.accent.withAlphaComponent(0.2))]
    lineMarked = true
  }

  private func makeTheme() -> EditorTheme {
    FontSet.registerFonts()
    let family = AppSettings.shared.fontFamily
    let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
    return EditorTheme(theme: AppSettings.shared.theme, font: UIFont(descriptor: descriptor, size: fontSize))
  }

  @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
    switch gesture.state {
    case .began:
      pinchStartSize = fontSize
    case .changed, .ended:
      let size = min(max((pinchStartSize * gesture.scale).rounded(), 8), 28)
      guard size != fontSize else { return }
      fontSize = size
      textView.theme = makeTheme()
      if gesture.state == .ended { UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey) }
    default:
      break
    }
  }

  // MARK: - Keys

  override var keyCommands: [UIKeyCommand]? {
    func key(_ input: String, _ mods: UIKeyModifierFlags, _ action: Selector, _ title: String) -> UIKeyCommand {
      let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: mods)
      command.wantsPriorityOverSystemBehavior = true
      return command
    }
    return [
      key("s", .command, #selector(saveCommand), "Save"),
      key("f", .command, #selector(findCommand), "Find"),
      key("z", .command, #selector(undoCommand), "Undo"),
      key("z", [.command, .shift], #selector(redoCommand), "Redo"),
      key("]", .command, #selector(indentCommand), "Indent"),
      key("[", .command, #selector(outdentCommand), "Outdent"),
      key("\t", .shift, #selector(outdentCommand), "Outdent"),
    ]
  }

  @objc private func saveCommand() { onSave() }
  @objc private func findCommand() { find() }
  @objc private func undoCommand() { textView.undoManager?.undo() }
  @objc private func redoCommand() { textView.undoManager?.redo() }
  @objc private func indentCommand() { if textView.isEditable { textView.shiftRight() } }
  @objc private func outdentCommand() { if textView.isEditable { textView.shiftLeft() } }

  // MARK: - TextViewDelegate

  func textViewDidChange(_ textView: TextView) {
    updateDirty()
    if lineMarked {
      lineMarked = false
      textView.highlightedRanges = []
    }
  }

  func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    guard !applying else { return true }
    switch text {
    case "\t": return insertTab(in: range)
    case "\n", "\r\n", "\r": return insertLineBreak(in: range)
    case "}", "]", ")": return insertCloser(text, in: range)
    default: return true
    }
  }

  private func apply(_ text: String, in range: NSRange) {
    applying = true
    textView.replace(range, withText: text)
    applying = false
  }

  /// Text on the caret's line before `location`, and after `end`.
  private func lineText(around location: Int, end: Int) -> (before: String, after: String) {
    let column = textView.textLocation(at: location)?.column ?? 0
    let before = textView.text(in: NSRange(location: location - column, length: column)) ?? ""
    let length = (textView.text as NSString).length
    let tail = textView.text(in: NSRange(location: end, length: min(240, length - end))) ?? ""
    return (before, String(tail.prefix { $0 != "\n" && $0 != "\r" && $0 != "\r\n" }))
  }

  private func insertTab(in range: NSRange) -> Bool {
    let selected = textView.text(in: range) ?? ""
    if selected.contains(where: \.isNewline) {
      textView.shiftRight()
      return false
    }
    guard case .spaces(let width) = document.indentation else { return true }
    let column = lineText(around: range.location, end: range.location).before.count
    apply(String(repeating: " ", count: width - column % width), in: range)
    return false
  }

  private func insertLineBreak(in range: NSRange) -> Bool {
    let (before, after) = lineText(around: range.location, end: range.upperBound)
    let colonOpens = document.language == .python || document.language == .yaml
    let (text, caret) = AutoIndent.lineBreak(before: before, after: after, unit: document.indentation.unit,
                                             newline: textView.lineEndings.symbol, colonOpens: colonOpens)
    apply(text, in: range)
    textView.selectedRange = NSRange(location: range.location + caret, length: 0)
    return false
  }

  private func insertCloser(_ closer: String, in range: NSRange) -> Bool {
    guard range.length == 0 else { return true }
    let before = lineText(around: range.location, end: range.location).before
    guard let replacement = AutoIndent.closer(closer, before: before, unit: document.indentation.unit) else { return true }
    let lineStart = range.location - before.utf16.count
    apply(replacement, in: NSRange(location: lineStart, length: before.utf16.count))
    return false
  }
}

private struct Pair: CharacterPair {
  let leading: String
  let trailing: String
  init(_ leading: String, _ trailing: String) {
    self.leading = leading
    self.trailing = trailing
  }
}

/// Builds a TextViewState (parsing included) on a background queue.
private final class StateBox: @unchecked Sendable {
  private let text: String
  private let theme: Runestone.Theme
  private let language: TreeSitterLanguage?
  private(set) var state: TextViewState?

  init(text: String, theme: Runestone.Theme, language: TreeSitterLanguage?) {
    self.text = text
    self.theme = theme
    self.language = language
  }

  func build() {
    state = if let language {
      TextViewState(text: text, theme: theme, language: language, languageProvider: EditorLanguages.shared)
    } else {
      TextViewState(text: text, theme: theme)
    }
  }
}
