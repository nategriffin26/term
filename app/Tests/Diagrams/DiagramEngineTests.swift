import UIKit
import XCTest
@testable import Term

/// Every diagram type Pele 1.10.0 draws (Fixtures/pele-samples.json, one
/// sample per type) goes through the app's engine: term-pele.js's flatten()
/// leans on Pele's private CSS variables, and resvg has no CSS engine, so a
/// variable left over draws black or nothing.
@MainActor
final class DiagramEngineTests: XCTestCase {
  func samples() throws -> [String: String] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pele-samples", withExtension: "json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
  }

  let style = DiagramEngine.Style(
    family: FontSet.family, fontSize: 13, foreground: 0xD8DEE9, background: 0x1B1D23, cursor: 0x88C0D0,
    palette: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
              0x4C566A, 0xD08770, 0xA3BE8C, 0xEBCB8B, 0x5E81AC, 0xB48EAD, 0x8FBCBB, 0xECEFF4],
    scale: 2)

  func testEveryPeleTypeFlattensAndRasterizes() async throws {
    let samples = try samples()
    XCTAssertEqual(samples.count, 33)
    for (type, source) in samples.sorted(by: { $0.key < $1.key }) {
      let request = DiagramEngine.Request(hash: type, maxWidth: 400, style: style)
      let laid = await DiagramEngine.shared.svg(request, source: source)
      let svg = try XCTUnwrap(laid, "\(type): no layout")
      for leftover in ["var(", "color-mix", "--_"] {
        XCTAssertFalse(svg.contains(leftover), "\(type) keeps \(leftover)")
      }
      let image = await DiagramEngine.shared.draw(request, source: source)
      XCTAssertNotNil(image, "\(type): resvg failed")
      XCTAssertGreaterThan(image?.size.height ?? 0, 0, type)
      XCTAssertLessThanOrEqual(image?.size.width ?? .infinity, 400, type)
    }
  }

  /// A source Pele can't parse leaves the ASCII: no image, and no crash.
  func testASyntaxErrorDrawsNothing() async {
    let request = DiagramEngine.Request(hash: "bad", maxWidth: 400, style: style)
    let image = await DiagramEngine.shared.draw(request, source: "flowchart TD\n  A -->")
    XCTAssertNil(image)
  }

  func testCacheSeparatesSourceWidthAndEveryStyleField() async throws {
    let engine = DiagramEngine()
    let request = DiagramEngine.Request(hash: "same-published-id", maxWidth: 400, style: style)
    let first = "flowchart TD\n A[alpha] --> B[beta]"
    let second = "flowchart TD\n A[alpha] --> B[beta] --> C[gamma] --> D[delta]"
    func cached(_ request: DiagramEngine.Request, _ source: String) async throws -> UIImage {
      for _ in 0..<100 {
        if let image = engine.image(request, source: source, ready: {}) { return image }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw XCTUnwrapError()
    }
    let a = try await cached(request, first)
    let b = try await cached(request, second)
    XCTAssertFalse(a === b, "The cache must not reuse pixels from a different source")
    let same = try await cached(request, first)
    XCTAssertTrue(a === same)
    var requests: [DiagramEngine.Request] = []
    var narrow = request; narrow.maxWidth = 200; requests.append(narrow)
    var font = request; font.style.fontSize += 1; requests.append(font)
    var family = request; family.style.family = "Menlo"; requests.append(family)
    var fg = request; fg.style.foreground ^= 0xFFFFFF; requests.append(fg)
    var bg = request; bg.style.background ^= 0xFFFFFF; requests.append(bg)
    var cursor = request; cursor.style.cursor ^= 0xFFFFFF; requests.append(cursor)
    var palette = request; palette.style.palette[4] ^= 0xFFFFFF; requests.append(palette)
    var scale = request; scale.style.scale = 3; requests.append(scale)
    for other in requests {
      let image = try await cached(other, first)
      XCTAssertFalse(a === image, "Width and every rendering style field belong in the cache key")
    }
  }

  private struct XCTUnwrapError: Error {}
}

