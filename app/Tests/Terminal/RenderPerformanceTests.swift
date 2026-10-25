import Metal
import QuartzCore
import XCTest
@testable import Term

/// Times the path a frame takes from VT bytes to pixels for a dense 200x60
/// screen where every cell has its own colors: parse (core), copy out of the
/// core, GPU instance build, and a real render pass into an offscreen texture.
@MainActor
final class RenderPerformanceTests: XCTestCase {
  static let cols = 200, rows = 60

  /// A full screen of random glyphs, each cell with its own true-color
  /// foreground and background, with bold/italic/underline mixed in.
  static func denseScreen(_ rng: inout SeededRandom) -> String {
    let glyphs = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789{}[]()<>=+-*/\\|;:,.!?@#$%^&_~")
      + ["┃", "━", "█", "▒", "\u{e0b0}", "\u{f121}", "é", "ß"]
    var out = "\u{1b}[H"
    for row in 0..<rows {
      for _ in 0..<cols {
        let r = rng.next()
        let fg = (r & 0xFF, (r >> 8) & 0xFF, (r >> 16) & 0xFF)
        let bg = ((r >> 24) & 0xFF, (r >> 32) & 0xFF, (r >> 40) & 0xFF)
        var attrs = ""
        if r >> 56 & 7 == 0 { attrs += "1;" }
        if r >> 56 & 7 == 1 { attrs += "3;" }
        if r >> 56 & 7 == 2 { attrs += "4;" }
        out += "\u{1b}[\(attrs)38;2;\(fg.0);\(fg.1);\(fg.2);48;2;\(bg.0);\(bg.1);\(bg.2)m"
        out.append(glyphs[Int((r >> 59) &+ (r >> 3)) % glyphs.count])
      }
      out += row == rows - 1 ? "" : "\u{1b}[0m\r\n"
    }
    return out
  }

  func testFullDenseColoredFrameRender() throws {
    FontSet.registerFonts()
    let session = try XCTUnwrap(Session(localCols: Self.cols, rows: Self.rows))
    let fonts = FontSet(pointSize: 10, scale: 3)
    let renderer = try XCTUnwrap(Renderer(fonts: fonts))
    let m = fonts.metrics
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: m.width * Self.cols,
                                                        height: m.height * Self.rows, mipmapped: false)
    desc.usage = .renderTarget
    desc.storageMode = .private
    let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: desc))
    let placement = Renderer.Placement(viewport: SIMD2(Float(target.width), Float(target.height)), origin: .zero)

    var rng = SeededRandom(seed: 42)
    var snapshot = FrameSnapshot()
    var feed: [Double] = [], copy: [Double] = [], build: [Double] = [], gpu: [Double] = [], total: [Double] = []
    var bytes = 0
    let frames = 61

    for i in 0..<frames {
      let screen = Self.denseScreen(&rng)
      bytes = screen.utf8.count

      let t0 = CACurrentMediaTime()
      session.feed(screen)
      let t1 = CACurrentMediaTime()
      var frame = TermFrame()
      XCTAssertTrue(session.frame(after: snapshot.generation == 0 ? .max : snapshot.generation, into: &frame))
      snapshot.load(frame)
      let t2 = CACurrentMediaTime()
      renderer.build(snapshot, overlay: Renderer.Overlay())
      let t3 = CACurrentMediaTime()
      let cb = try XCTUnwrap(renderer.encode(into: target, placement: placement))
      cb.commit()
      cb.waitUntilCompleted()
      let t4 = CACurrentMediaTime()
      XCTAssertNil(cb.error)

      if i == 0 {
        XCTAssertEqual(snapshot.cols, Self.cols)
        XCTAssertEqual(snapshot.rows, Self.rows)
        XCTAssertEqual(snapshot.cells.count, Self.cols * Self.rows)
        continue  // the first frame fills the glyph atlas; measured separately
      }
      feed.append(t1 - t0)
      copy.append(t2 - t1)
      build.append(renderer.lastBuildTime)
      gpu.append(cb.gpuEndTime - cb.gpuStartTime)
      total.append(t4 - t0)
    }

    func ms(_ xs: [Double]) -> String {
      let s = xs.sorted()
      return String(format: "mean %.2f  p50 %.2f  p95 %.2f  max %.2f", xs.reduce(0, +) / Double(xs.count) * 1e3,
                    s[s.count / 2] * 1e3, s[Int(Double(s.count) * 0.95)] * 1e3, s.last! * 1e3)
    }
    let report = """
    PERF 200x60 dense true-color frame (\(bytes) bytes of VT, cell \(m.width)x\(m.height) px), \(feed.count) frames, ms:
    PERF   core parse (feed)  \(ms(feed))
    PERF   copy out of core   \(ms(copy))
    PERF   build instances    \(ms(build))
    PERF   GPU pass           \(ms(gpu))
    PERF   total to pixels    \(ms(total))
    """
    print(report)
    XCTContext.runActivity(named: "200x60 frame timing") { activity in
      let a = XCTAttachment(string: report)
      a.lifetime = .keepAlways
      activity.add(a)
    }

    // Budget for one display refresh at 120 Hz is 8.3 ms; this is a tripwire
    // for a regression to something visibly slow, not a promise.
    let p95 = total.sorted()[Int(Double(total.count) * 0.95)]
    XCTAssertLessThan(p95, 0.050, "dense frame took \(p95 * 1e3) ms at p95")
  }
}
