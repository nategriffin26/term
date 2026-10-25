import Foundation
import Observation

/// A text file open in the editor: what the host had when it was read (the
/// baseline and its mtime) and how to write it back the same way. The text
/// being edited lives in the editor; this decides whether it differs.
@MainActor @Observable
final class TextDocument {
  /// Canonical path on the host (symlinks resolved, so saving keeps the link).
  let path: String
  let language: SourceLanguage?
  let indentation: Indentation
  let lineBreak: LineBreak
  /// Why it cannot be edited, shown in one line; nil = editable.
  let readOnlyReason: String?
  private let hasBOM: Bool

  private(set) var baseline: String
  /// The host's mtime when `baseline` was read; saving fails if it moved.
  private(set) var mtime: Date
  /// Bumps when the baseline is replaced from the host (Reload), so the
  /// editor shows the new text.
  private(set) var revision = 0
  var isDirty = false

  init(path: String, text: String, hasBOM: Bool, mtime: Date, language: SourceLanguage?, readOnlyReason: String?) {
    self.path = path
    self.language = language
    self.hasBOM = hasBOM
    self.readOnlyReason = readOnlyReason
    baseline = text
    self.mtime = mtime
    lineBreak = LineBreak.detect(text)
    indentation = Indentation.detect(text) ?? Self.defaultIndentation(language, name: (path as NSString).lastPathComponent)
  }

  /// The bytes to write: UTF-8, with the byte-order mark the file had.
  func encoded(_ text: String) -> Data {
    var data = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
    data.append(contentsOf: text.utf8)
    return data
  }

  func saved(_ text: String, mtime: Date) {
    baseline = text
    self.mtime = mtime
  }

  func reloaded(_ text: String, mtime: Date) {
    baseline = text
    self.mtime = mtime
    isDirty = false
    revision += 1
  }

  /// For files with no indented line yet: the language's usual style.
  private static func defaultIndentation(_ language: SourceLanguage?, name: String) -> Indentation {
    if language == .go || ["Makefile", "makefile", "GNUmakefile"].contains(name) || name.hasSuffix(".mk") { return .tabs }
    switch language {
    case .javascript, .typescript, .tsx, .json, .yaml, .ruby, .lua, .html, .css, .scss, .markdown: return .spaces(2)
    default: return .spaces(4)
    }
  }
}
