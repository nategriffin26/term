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
}

