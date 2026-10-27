import CryptoKit
import UIKit
import UniformTypeIdentifiers

/// The clipboard between the phone and the Mac (§6): every representation
/// of one copied thing that both sides understand, and no echo either way.
enum ScreenClipboard {
  static let text = "public.utf8-plain-text"
  static let rtf = "public.rtf"
  static let html = "public.html"
  static let png = "public.png"
  static let url = "public.url"

  /// Types the Edit row's Paste button accepts.
  static let pasteTypes = [UTType.utf8PlainText, .plainText, .rtf, .html, .png, .jpeg, .heic, .tiff, .image, .url]
    .map(\.identifier)

  /// A UIPasteboard item (type identifier -> value) as the Mac's clipboard.
  /// Text in any encoding becomes UTF-8; any image becomes PNG.
  static func clipboard(from item: [String: Any]) -> ScreenWire.Clipboard {
    var out: [ScreenWire.ClipboardItem] = []
    func add(_ type: String, _ data: Data?) {
      guard let data, !out.contains(where: { $0.type == type }) else { return }
      out.append(ScreenWire.ClipboardItem(type: type, data: data))
    }
    for type in [UTType.utf8PlainText, .plainText, .text].map(\.identifier) {
      if let value = item[type] { add(text, utf8(value)) }
    }
    add(rtf, item[rtf].flatMap(data))
    add(html, item[html].flatMap(data))
    if let url = item[url] {
      add(Self.url, (url as? URL).map { Data($0.absoluteString.utf8) } ?? utf8(url))
    }
    if let png = item[png].flatMap(data) {
      add(Self.png, png)
    } else if let image = item.first(where: { UTType($0.key)?.conforms(to: .image) == true })?.value {
      add(png, (image as? UIImage ?? data(image).flatMap(UIImage.init(data:)))?.pngData())
    }
    return ScreenWire.Clipboard(items: out)
  }

  /// The Mac's clipboard as one UIPasteboard item.
  static func pasteboardItem(from clipboard: ScreenWire.Clipboard) -> [String: Any] {
    var item: [String: Any] = [:]
    for entry in clipboard.items {
      switch entry.type {
      case text: item[text] = String(decoding: entry.data, as: UTF8.self)
      case url: item[url] = URL(string: String(decoding: entry.data, as: UTF8.self))
      default: item[entry.type] = entry.data
      }
    }
    return item
  }

  /// Reads what the Edit row's Paste control handed over.
  @MainActor static func clipboard(from providers: [NSItemProvider]) async -> ScreenWire.Clipboard {
    guard let provider = providers.first else { return ScreenWire.Clipboard(items: []) }
    var item: [String: Any] = [:]
    for type in provider.registeredTypeIdentifiers {
      if let data = try? await provider.loadData(type) { item[type] = data }
    }
    return clipboard(from: item)
  }

  /// What a clipboard is, for telling one copy from another: its text, else
  /// its URL, image, HTML or RTF. Other representations may be rebuilt on the
  /// way (an image re-encoded, rich text regenerated) without being a new copy.
  static func identity(of clipboard: ScreenWire.Clipboard) -> Data? {
    for type in [text, url, png, html, rtf] {
      if let entry = clipboard.items.first(where: { $0.type == type }) {
        return Data(SHA256.hash(data: Data(type.utf8) + entry.data))
      }
    }
    return nil
  }

  private static func data(_ value: Any) -> Data? {
    if let data = value as? Data { return data }
    if let string = value as? String { return Data(string.utf8) }
    return nil
  }

  private static func utf8(_ value: Any) -> Data? {
    if let string = value as? String { return Data(string.utf8) }
    guard let data = value as? Data else { return nil }
    // Plain text from the pasteboard may be UTF-16 (with a byte-order mark) rather than UTF-8.
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16).map { Data($0.utf8) }
    }
    return data
  }
}

/// The phone's side of the clipboard sync (§6). A paired phone's system
/// mirrors the Mac's clipboard onto its own pasteboard, so whatever crosses
/// comes straight back as a new change; content the two sides already agree
/// on is never sent or written again. Each pasteboard change is read at most
/// once, and a read Paste from Other Apps refuses stops automatic reads until
/// the app returns to the foreground: each read would ask again.
struct ClipboardSync {
  /// The pasteboard change count already read or written. Kept across
  /// launches, so opening Term sends only a copy made since.
  private(set) var synced: Int?
  /// The content the phone and the Mac last agreed on, sent or received.
  private var agreed: Data?
  /// Paste from Other Apps refused a read.
  private(set) var paused = false

  init(synced: Int? = nil) { self.synced = synced }

  /// The pasteboard is at `count`: whether to read it now.
  mutating func shouldRead(_ count: Int) -> Bool {
    guard !paused, count != synced else { return false }
    synced = count
    return true
  }

  /// What an automatic read found: the clipboard the Mac still needs, or nil.
  /// Nothing read while the pasteboard `offered` text, an image or a URL is
  /// a refused read; that change is read again once reads resume.
  mutating func read(_ clipboard: ScreenWire.Clipboard, offered: Bool) -> ScreenWire.Clipboard? {
    guard !clipboard.items.isEmpty else {
      if offered {
        paused = true
        synced = nil
      }
      return nil
    }
    guard isNew(clipboard) else { return nil }
    agreed = ScreenClipboard.identity(of: clipboard)
    return clipboard
  }

  /// Whether `clipboard` differs from what the two sides agree on.
  func isNew(_ clipboard: ScreenWire.Clipboard) -> Bool {
    ScreenClipboard.identity(of: clipboard) != agreed
  }

  /// Both sides now hold `clipboard` (written onto the pasteboard or sent on
  /// request), the pasteboard at `count`.
  mutating func agree(on clipboard: ScreenWire.Clipboard, at count: Int) {
    agreed = ScreenClipboard.identity(of: clipboard)
    synced = count
  }

  /// The app is back in the foreground: Paste from Other Apps may have changed.
  mutating func resume() { paused = false }
}

/// The phone's general pasteboard as the clipboard sync uses it.
@MainActor
protocol ScreenPasteboard: AnyObject {
  var changeCount: Int { get }
  /// Whether it holds text, an image or a URL; asking raises no paste prompt.
  var offersContent: Bool { get }
  /// Its first item. Reading another app's copy asks Paste from Other Apps;
  /// a refused read finds nothing.
  func firstItem() -> [String: Any]?
  func write(_ item: [String: Any])
}

final class SystemPasteboard: ScreenPasteboard {
  var changeCount: Int { UIPasteboard.general.changeCount }
  var offersContent: Bool {
    let board = UIPasteboard.general
    return board.hasStrings || board.hasImages || board.hasURLs
  }
  func firstItem() -> [String: Any]? { UIPasteboard.general.items.first }
  func write(_ item: [String: Any]) { UIPasteboard.general.setItems([item]) }
}

extension NSItemProvider {
  @MainActor fileprivate func loadData(_ type: String) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
      }
    }
  }
}
