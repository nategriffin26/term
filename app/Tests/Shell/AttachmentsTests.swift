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
}
