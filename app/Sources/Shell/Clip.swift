import UIKit
import UniformTypeIdentifiers

/// The clipboard as one paste sees it. Read it inside a system paste
/// (⌘V, the edit menu's Paste, the paste control), which iOS lets through
/// without its "Allow Paste" prompt; a read anywhere else asks first.
struct Clip {
  struct Image {
    var data: Data
    var type: UTType
  }

  var text: String?
  var images: [Image] = []
  /// Anything else (files copied in Files): copied out on use.
  var files: [NSItemProvider] = []

  var isEmpty: Bool { text == nil && images.isEmpty && files.isEmpty }

  /// Image types in the order a copied item's representations are tried.
  private static let imageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .webP, .tiff, .bmp]

  @MainActor
  static func read(_ board: UIPasteboard = .general) -> Clip {
    var clip = Clip()
    if board.hasStrings, let text = board.string, !text.isEmpty { clip.text = text }
    if board.hasImages {
      clip.images = board.items.compactMap(image(in:))
    }
    if clip.text == nil, clip.images.isEmpty, board.numberOfItems > 0 {
      clip.files = board.itemProviders
    }
    return clip
  }

  /// The paste control's and drops' providers: images by their data, text
  /// unless it comes as a file, files as they are.
  @MainActor
  static func load(_ providers: [NSItemProvider]) async -> Clip {
    var clip = Clip()
    for provider in providers {
      let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
      let isFile = provider.suggestedName != nil || types.contains { $0.conforms(to: .fileURL) }
      if let type = imageTypes.first(where: { t in types.contains { $0.conforms(to: t) } })
        ?? types.first(where: { $0.conforms(to: .image) }),
        let data = await loadData(provider, type) {
        clip.images.append(Image(data: data, type: type))
      } else if !isFile, provider.canLoadObject(ofClass: String.self), let text = await loadText(provider) {
        clip.text = (clip.text.map { $0 + "\n" } ?? "") + text
      } else {
        clip.files.append(provider)
      }
    }
    return clip
  }

  private static func image(in item: [String: Any]) -> Image? {
    let keyed = item.compactMap { key, value in UTType(key).map { ($0, value) } }
    let ordered = imageTypes.compactMap { t in keyed.first { $0.0 == t } }
      + keyed.filter { $0.0.conforms(to: .image) && !imageTypes.contains($0.0) }
    for (type, value) in ordered {
      if let data = value as? Data { return Image(data: data, type: type) }
      if let image = value as? UIImage, let data = image.pngData() { return Image(data: data, type: .png) }
    }
    return nil
  }

  @MainActor
  private static func loadData(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
    }
  }

  @MainActor
  private static func loadText(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
    }
  }
}
