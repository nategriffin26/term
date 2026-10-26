import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Term

final class AttachmentsTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!
  // 2026-10-25 14:30:12 UTC
  private let date = Date(timeIntervalSince1970: 1_792_938_612)

  private func name(_ original: String?, _ ext: String, taken: inout Set<String>) -> String {
    Attachments.name(for: original, ext: ext, at: date, timeZone: utc, taken: &taken)
  }

  /// Catches a stamp in local time or the wrong field order (paths must sort by time).
  func testNameIsStampThenStem() {
    var taken = Set<String>()
    XCTAssertEqual(name("IMG_1234.HEIC", "jpg", taken: &taken), "20261025-143012-IMG_1234.jpg")
    XCTAssertEqual(name(nil, "png", taken: &taken), "20261025-143012.png")
  }

  /// Catches names that need shell quoting (spaces, quotes, non-ASCII) reaching the agent's prompt.
  func testNameKeepsOnlySafeCharacters() {
    var taken = Set<String>()
    XCTAssertEqual(name("My Report (final)'s.PDF", "pdf", taken: &taken), "20261025-143012-My-Report-final-s.pdf")
    XCTAssertEqual(name("café ünïcode.txt", "txt", taken: &taken), "20261025-143012-caf-n-code.txt")
    XCTAssertEqual(name("   .png", "png", taken: &taken), "20261025-143012.png")
    XCTAssertEqual(name(String(repeating: "a", count: 60) + ".md", "md", taken: &taken),
                   "20261025-143012-" + String(repeating: "a", count: 40) + ".md")
  }

  /// Catches two picks in the same second overwriting each other on the host.
  func testSameSecondNamesDiffer() {
    var taken = Set<String>()
    XCTAssertEqual(name("a.png", "png", taken: &taken), "20261025-143012-a.png")
    XCTAssertEqual(name("a.png", "png", taken: &taken), "20261025-143012-a-2.png")
    XCTAssertEqual(name("a.png", "png", taken: &taken), "20261025-143012-a-3.png")
  }

  /// Catches a typed path that a shell would split or a newline that would run it.
  func testTypedPathsQuotedOnlyWhenNeeded() {
    XCTAssertEqual(Attachments.typed(["/Users/me/.term/uploads/a.png"]), "/Users/me/.term/uploads/a.png")
    XCTAssertEqual(Attachments.typed(["/Users/my name/a.png", "/b.jpg"]), "'/Users/my name/a.png' /b.jpg")
    XCTAssertFalse(Attachments.typed(["/a", "/b"]).contains("\n"))
  }

  /// Catches HEIC (unreadable by most agents) kept, screenshots turned lossy, or no downscale above the cap.
  func testPlans() {
    typealias P = Attachments.ImagePlan
    XCTAssertNil(Attachments.plan(for: .png, longEdge: 2048, hasAlpha: true, maxEdge: 2048))
    XCTAssertEqual(Attachments.plan(for: .png, longEdge: 2049, hasAlpha: false, maxEdge: 2048), P(format: .png, maxEdge: 2048))
    XCTAssertNil(Attachments.plan(for: .jpeg, longEdge: 1000, hasAlpha: false, maxEdge: 2048))
    XCTAssertEqual(Attachments.plan(for: .jpeg, longEdge: 4032, hasAlpha: false, maxEdge: 2048), P(format: .jpeg, maxEdge: 2048))
    XCTAssertEqual(Attachments.plan(for: .heic, longEdge: 1000, hasAlpha: false, maxEdge: 2048), P(format: .jpeg, maxEdge: nil))
    XCTAssertEqual(Attachments.plan(for: .heic, longEdge: 4032, hasAlpha: false, maxEdge: 2048), P(format: .jpeg, maxEdge: 2048))
    XCTAssertEqual(Attachments.plan(for: .tiff, longEdge: 100, hasAlpha: true, maxEdge: 2048), P(format: .png, maxEdge: nil))
    XCTAssertNil(Attachments.plan(for: .gif, longEdge: 5000, hasAlpha: false, maxEdge: 2048))
    XCTAssertNil(Attachments.plan(for: .webP, longEdge: 2000, hasAlpha: false, maxEdge: 2048))
    // Files' paste keeps size (no cap) but still converts HEIC.
    XCTAssertNil(Attachments.plan(for: .png, longEdge: 9000, hasAlpha: false, maxEdge: nil))
    XCTAssertEqual(Attachments.plan(for: .heic, longEdge: 9000, hasAlpha: false, maxEdge: nil), P(format: .jpeg, maxEdge: nil))
  }

  private func image(_ w: Int, _ h: Int, as type: UTType) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let ui = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
      UIColor.red.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ui.cgImage!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return out as Data
  }

  private func size(_ data: Data) -> (Int, Int, String?) {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int, CGImageSourceGetType(src) as String?)
  }

  /// Catches the downscale skipped or the wrong format written for real image bytes.
  func testNormalizeShrinksAndConverts() throws {
    let big = try XCTUnwrap(Attachments.normalize(image(3000, 2000, as: .png), type: .png, maxEdge: 2048))
    XCTAssertEqual(big.ext, "png")
    let (w, h, t) = size(big.data)
    XCTAssertEqual([w, h], [2048, 1365])
    XCTAssertEqual(t, UTType.png.identifier)

    let tiff = try XCTUnwrap(Attachments.normalize(image(300, 200, as: .tiff), type: .tiff, maxEdge: 2048))
    XCTAssertTrue(["jpg", "png"].contains(tiff.ext))
    XCTAssertNotEqual(size(tiff.data).2, UTType.tiff.identifier)

    let small = image(300, 200, as: .jpeg)
    let kept = try XCTUnwrap(Attachments.normalize(small, type: .jpeg, maxEdge: 2048))
    XCTAssertEqual(kept.data, small)
    XCTAssertEqual(kept.ext, "jpg")

    XCTAssertNil(Attachments.normalize(Data("not an image".utf8), type: .png, maxEdge: 2048))
  }

  // MARK: - Videos

  /// Catches HEVC or H.264 re-encoded for nothing, a 4K clip sent whole, and a portrait clip
  /// judged by width alone (1080×1920 is within bounds, 1080×1921 and 1081×1920 are not).
  func testVideoPlanBoundaries() {
    func plan(_ codec: Attachments.VideoCodec, _ w: Int, _ h: Int) -> Attachments.VideoPlan {
      Attachments.videoPlan(codec: codec, width: w, height: h)
    }
    XCTAssertEqual(plan(.hevc, 1920, 1080), .keep)
    XCTAssertEqual(plan(.h264, 1920, 1080), .keep)
    XCTAssertEqual(plan(.hevc, 1080, 1920), .keep)
    XCTAssertEqual(plan(.h264, 1440, 1080), .keep)
    XCTAssertEqual(plan(.h264, 640, 360), .keep)
    XCTAssertEqual(plan(.hevc, 1921, 1080), .fit1080)
    XCTAssertEqual(plan(.hevc, 1920, 1081), .fit1080)
    XCTAssertEqual(plan(.hevc, 1080, 1921), .fit1080)
    XCTAssertEqual(plan(.hevc, 1081, 1920), .fit1080)
    XCTAssertEqual(plan(.h264, 3840, 2160), .fit1080)
    XCTAssertEqual(plan(.hevc, 2160, 3840), .fit1080)
    XCTAssertEqual(plan(.h264, 1920, 1440), .fit1080)
  }

  /// Catches ProRes (huge, rarely readable by an agent's ffmpeg build) kept as is when small, and shrunk only by size.
  func testVideoPlanReencodesOtherCodecs() {
    XCTAssertEqual(Attachments.videoPlan(codec: .other, width: 1280, height: 720), .transcode)
    XCTAssertEqual(Attachments.videoPlan(codec: .other, width: 1920, height: 1080), .transcode)
    XCTAssertEqual(Attachments.videoPlan(codec: .other, width: 3840, height: 2160), .fit1080)
  }

  /// Catches the FourCC table wrong: iPhone HEVC is "hvc1" (HDR Dolby Vision "dvh1"), camera H.264 "avc1".
  func testVideoCodecFromFourCC() {
    func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    XCTAssertEqual(Attachments.VideoCodec(fourCC: code("hvc1")), .hevc)
    XCTAssertEqual(Attachments.VideoCodec(fourCC: code("hev1")), .hevc)
    XCTAssertEqual(Attachments.VideoCodec(fourCC: code("dvh1")), .hevc)
    XCTAssertEqual(Attachments.VideoCodec(fourCC: code("avc1")), .h264)
    XCTAssertEqual(Attachments.VideoCodec(fourCC: code("ap4h")), .other)
    XCTAssertEqual(Attachments.VideoCodec(fourCC: code("apcn")), .other)
  }

  /// A fixture copied to a scratch folder (prepare writes beside its input).
  private func fixture(_ name: String, _ ext: String) throws -> URL {
    let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "missing fixture \(name).\(ext)")
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appending(path: "\(name).\(ext)")
    try FileManager.default.copyItem(at: src, to: copy)
    return copy
  }

  private struct Shape {
    var codec: Attachments.VideoCodec
    var shown: CGSize
    var audioTracks: Int
  }

  private func shape(_ url: URL) async throws -> Shape {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let video = try XCTUnwrap(tracks.first)
    let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
    let shown = CGRect(origin: .zero, size: size).applying(transform)
    let probed = await VideoExport.probe(url)
    let info = try XCTUnwrap(probed)
    return Shape(codec: info.codec, shown: CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded()),
                 audioTracks: try await asset.loadTracks(withMediaType: .audio).count)
  }

  private func prepared(_ file: URL) async throws -> (file: URL, name: String) {
    var taken = Set<String>()
    return try await Attachments.prepare(file, at: date, taken: &taken)
  }

  /// Catches a 4K clip uploaded whole, the sound dropped, or the result no longer H.264/HEVC.
  func testPrepareShrinksUHDVideoKeepingAudio() async throws {
    let source = try fixture("uhd-h264", "mp4")
    let out = try await prepared(source)
    XCTAssertNotEqual(out.file, source)
    XCTAssertTrue(out.name.hasSuffix("-uhd-h264.mov"), out.name)
    let result = try await shape(out.file)
    XCTAssertEqual(result.shown, CGSize(width: 1920, height: 1080))
    XCTAssertEqual(result.audioTracks, 1)
    XCTAssertTrue([.hevc, .h264].contains(result.codec))
  }

  /// Catches a phone-held (rotated) 4K clip coming out sideways or squashed instead of 1080×1920.
  func testPrepareKeepsRotationOfPortraitVideo() async throws {
    let source = try fixture("uhd-hevc-rotated", "mov")
    let result = try await shape(try await prepared(source).file)
    XCTAssertEqual(result.shown, CGSize(width: 1080, height: 1920))
    XCTAssertEqual(result.audioTracks, 1)
  }

  /// Catches a 1080p HEVC file re-encoded (lossy, slow) when it should be sent byte for byte under its own extension.
  func testPrepareKeepsVideoWithinBounds() async throws {
    let source = try fixture("hd-hevc", "mp4")
    let out = try await prepared(source)
    XCTAssertEqual(out.file, source)
    XCTAssertTrue(out.name.hasSuffix("-hd-hevc.mp4"), out.name)
  }

  /// Catches ProRes failing the upload where the device has no encoder for it (it is then sent as recorded),
  /// and a 720p ProRes frame resized or stripped of sound where it does.
  func testPrepareTranscodesProResOrSendsItAsRecorded() async throws {
    let source = try fixture("prores-720p", "mov")
    let out = try await prepared(source)
    XCTAssertTrue(out.name.hasSuffix("-prores-720p.mov"), out.name)
    if out.file == source { return }
    let result = try await shape(out.file)
    XCTAssertEqual(result.shown, CGSize(width: 1280, height: 720))
    XCTAssertEqual(result.audioTracks, 1)
    XCTAssertTrue([.hevc, .h264].contains(result.codec))
  }

  /// Catches Cancel during compression letting the export run on (and hand its file to the upload) or leaving a
  /// half-written movie behind.
  func testCancelledExportStopsAndLeavesNoFile() async throws {
    let source = try fixture("uhd-h264", "mp4")
    let out = source.deletingLastPathComponent().appending(path: "out.mov")
    let export = Task { try await VideoExport.export(source, plan: .fit1080, to: out) { _ in } }
    export.cancel()
    do {
      try await export.value
      XCTFail("a cancelled export finished")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: out.path(percentEncoded: false)))
  }

  /// Catches an unreadable "video" failing the whole upload instead of being sent as it is.
  func testPrepareSendsUnreadableVideoAsItIs() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let broken = dir.appending(path: "clip.mov")
    try Data("not a movie".utf8).write(to: broken)
    let out = try await prepared(broken)
    XCTAssertEqual(out.file, broken)
    XCTAssertTrue(out.name.hasSuffix("-clip.mov"), out.name)
  }
}
