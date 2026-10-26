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

/// The phone's side of no-echo (§6): the pasteboard change count the Mac
/// already has, whether the phone sent it or wrote it from the Mac. Kept
/// across launches, so opening Term sends only a copy made since.
struct PasteboardEcho {
  private(set) var synced: Int?

  /// The phone's clipboard is at `count`: whether the Mac still needs it.
  mutating func needsSending(_ count: Int) -> Bool {
    guard count != synced else { return false }
    synced = count
    return true
  }

  /// The app wrote the Mac's clipboard, leaving the pasteboard at `count`.
  mutating func wrote(_ count: Int) { synced = count }
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
