import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photos and files sent from the phone to the host for an agent to read:
/// where they land, what they are called, and the form images take.
enum Attachments {
  /// Under the host's home, made on first use.
  static let folder = ".term/uploads"

  /// Long edge an image is scaled down to. Models gain nothing above it,
  /// and Claude refuses images over 5 MB, which a full-size photo can be.
  static let maxEdge = 2048

  /// "IMG_1234.HEIC" sent as JPEG at 2026-10-25 14:30:12 →
  /// "20261025-143012-IMG_1234.jpg". Only [A-Za-z0-9._-] survive, so the
  /// typed path needs no quoting; `taken` holds the batch's names so far.
  static func name(for original: String?, ext: String, at date: Date, timeZone: TimeZone = .current,
                   taken: inout Set<String>) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
    let stamp = "\(c.year ?? 0)\(two(c.month))\(two(c.day))-\(two(c.hour))\(two(c.minute))\(two(c.second))"
    let stem = original.map(safeStem) ?? ""
    let base = stem.isEmpty ? stamp : "\(stamp)-\(stem)"
    let clean = safeStem(ext).lowercased()
    let dotExt = clean.isEmpty ? "" : "." + clean
    var name = base + dotExt
    var n = 2
    while taken.contains(name) {
      name = "\(base)-\(n)\(dotExt)"
      n += 1
    }
    taken.insert(name)
    return name
  }

  /// The name without its extension, each run of other characters made
  /// one "-", at most 40 characters.
  private static func safeStem(_ name: String) -> String {
    let leaf = name.split(separator: "/").last.map(String.init) ?? ""
    let stem = FilePath.ext(leaf).isEmpty ? leaf : String(leaf.dropLast(FilePath.ext(leaf).count + 1))
    var out = ""
    for scalar in stem.unicodeScalars {
      if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar) {
        out.unicodeScalars.append(scalar)
      } else if !out.hasSuffix("-") {
        out += "-"
      }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return String(trimmed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
  }

  /// The paths as typed at the cursor: shell-quoted, space-separated, no newline.
  static func typed(_ paths: [String]) -> String {
    paths.map(Command.shellQuote).joined(separator: " ")
  }

  // MARK: - Images

  struct ImagePlan: Equatable {
    enum Format: Equatable {
      case png, jpeg
      var type: UTType { self == .png ? .png : .jpeg }
      var ext: String { self == .png ? "png" : "jpg" }
    }
    var format: Format
    /// Scale so the long edge is at most this; nil keeps the size.
    var maxEdge: Int?
  }

  /// What an image becomes, nil to keep its bytes: PNG and JPEG stay
  /// themselves, GIF stays (it may move), WebP stays unless it must
  /// shrink; anything else (HEIC, TIFF, …) becomes JPEG, or PNG when it
  /// has alpha. With `maxEdge`, a larger image is scaled down to it.
  static func plan(for type: UTType, longEdge: Int, hasAlpha: Bool, maxEdge: Int?) -> ImagePlan? {
    let shrink = maxEdge.flatMap { longEdge > $0 ? $0 : nil }
    let flat = ImagePlan.Format.jpeg
    let lossless = ImagePlan.Format.png
    if type.conforms(to: .png) { return shrink.map { ImagePlan(format: .png, maxEdge: $0) } }
    if type.conforms(to: .jpeg) { return shrink.map { ImagePlan(format: .jpeg, maxEdge: $0) } }
    if type.conforms(to: .gif) { return nil }
    if type.conforms(to: .webP) { return shrink.map { ImagePlan(format: hasAlpha ? lossless : flat, maxEdge: $0) } }
    return ImagePlan(format: hasAlpha ? lossless : flat, maxEdge: shrink)
  }

  /// The image as it should be sent, with its extension; nil when `data`
  /// is not an image this device can decode (it is then sent as it is).
  /// Re-encoding applies the photo's orientation and drops its metadata.
  static func normalize(_ data: Data, type: UTType, maxEdge: Int?) -> (data: Data, ext: String)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
    guard let plan = plan(for: type, longEdge: max(width, height), hasAlpha: hasAlpha, maxEdge: maxEdge) else {
      let ext = type.conforms(to: .jpeg) ? "jpg" : type.preferredFilenameExtension ?? "img"
      return (data, ext)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: plan.maxEdge ?? max(width, height),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, plan.format.type.identifier as CFString, 1, nil) else { return nil }
    let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
    CGImageDestinationAddImage(dest, image, plan.format == .jpeg ? quality as CFDictionary : nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return (out as Data, plan.format.ext)
  }

  // MARK: - Videos

  /// Largest frame a video is sent at, in either orientation. Beyond it
  /// a clip is re-encoded: agents read a frame grid, and a 4K minute is
  /// hundreds of megabytes over a phone's uplink.
  static let maxVideoLongEdge = 1920
  static let maxVideoShortEdge = 1080

  enum VideoCodec: Equatable {
    case hevc, h264, other

    /// From a format description's media subtype (the four characters of
    /// the sample entry: "hvc1", "avc1", …).
    init(fourCC: UInt32) {
      switch fourCC {
      case 0x6876_6331, 0x6865_7631, 0x6476_6831, 0x6476_6865: self = .hevc  // hvc1 hev1 dvh1 dvhe
      case 0x6176_6331, 0x6176_6333: self = .h264  // avc1 avc3
      default: self = .other
      }
    }
  }

  enum VideoPlan: Equatable {
    /// Send the file as it is.
    case keep
    /// Re-encode as HEVC no larger than 1920×1080 (portrait included).
    case fit1080
    /// Re-encode as HEVC at the size it has: a codec agents' ffmpeg may
    /// not read or that is far too big (ProRes) in a frame that is not.
    case transcode
  }

  /// HEVC and H.264 within 1080p are sent as recorded, and everything
  /// else is brought to what the host and the uplink handle. Either
  /// orientation: only the long and the short edge count.
  static func videoPlan(codec: VideoCodec, width: Int, height: Int) -> VideoPlan {
    let fits = max(width, height) <= maxVideoLongEdge && min(width, height) <= maxVideoShortEdge
    if !fits { return .fit1080 }
    return codec == .other ? .transcode : .keep
  }

  /// A local file ready to send under its upload name: an image
  /// normalized, a video re-encoded when its plan says so (both written
  /// beside it), anything else as it is, as is a video this device cannot
  /// re-encode. `progress` (0...1) reports a re-encode.
  @concurrent static func prepare(_ file: URL, at date: Date, taken: inout Set<String>,
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (file: URL, name: String) {
    let original = file.lastPathComponent
    let ext = FilePath.ext(original)
    let type = UTType(filenameExtension: ext)
    if let type, type.conforms(to: .image),
       let image = normalize(try Data(contentsOf: file), type: type, maxEdge: maxEdge) {
      let name = self.name(for: original, ext: image.ext, at: date, taken: &taken)
      let out = file.deletingLastPathComponent().appending(path: name)
      try image.data.write(to: out)
      return (out, name)
    }
    if let type, type.conforms(to: .movie), let info = await VideoExport.probe(file) {
      let plan = videoPlan(codec: info.codec, width: info.width, height: info.height)
      if plan != .keep {
        let name = self.name(for: original, ext: "mov", at: date, taken: &taken)
        let out = file.deletingLastPathComponent().appending(path: name)
        do {
          try await VideoExport.export(file, plan: plan, to: out, progress: progress)
          return (out, name)
        } catch VideoExport.ExportError.unsupported {
          taken.remove(name)
        }
      }
    }
    return (file, name(for: original, ext: ext, at: date, taken: &taken))
  }
}
