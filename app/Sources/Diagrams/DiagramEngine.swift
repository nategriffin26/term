import CoreText
import JavaScriptCore
import UIKit

/// Draws Mermaid sources as images in the terminal's theme and font
/// (local/diagrams/design.md §2): Pele lays them out in JavaScriptCore with
/// labels measured by CoreText, the core's resvg rasterizes them over the
/// terminal background. One context, on one serial queue, for the app.
@MainActor
final class DiagramEngine {
  static let shared = DiagramEngine()

  /// How a diagram looks: the terminal's font and colours (0xRRGGBB).
  struct Style: Hashable, Sendable {
    var family: String
    var fontSize: Double
    var foreground: UInt32
    var background: UInt32
    var cursor: UInt32
    /// ANSI 0-15.
    var palette: [UInt32]
    var scale: Double
  }

  struct Request: Hashable, Sendable {
    var hash: String
    /// Widest the diagram may be, in points.
    var maxWidth: Int
    var style: Style
  }

  /// Images kept, least recently used dropped first (a phone diagram is ~3 MB).
  static let capacity = 12

  private let worker = Worker()
  private var images: [Request: UIImage] = [:]
  private var order: [Request] = []
  private var waiting: [Request: [() -> Void]] = [:]
  /// Pele or resvg could not draw these; their ASCII stays.
  private var failed: Set<Request> = []

  /// The image when drawn, else nil; a request not yet drawn starts drawing
  /// and calls `ready` when its image (or its failure) is known.
  func image(_ request: Request, source: String, ready: @escaping () -> Void) -> UIImage? {
    if let image = images[request] {
      order.removeAll { $0 == request }
      order.append(request)
      return image
    }
    guard !failed.contains(request) else { return nil }
    if waiting[request] != nil {
      waiting[request]!.append(ready)
      return nil
    }
    waiting[request] = [ready]
    FontSet.registerFonts()
    let worker = worker
    worker.queue.async {
      let image = worker.render(source, request)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.finish(request, image) }
      }
    }
    return nil
  }

  private func finish(_ request: Request, _ image: UIImage?) {
    if let image {
      images[request] = image
      order.append(request)
      while order.count > Self.capacity { images[order.removeFirst()] = nil }
    } else {
      failed.insert(request)
    }
    for ready in waiting.removeValue(forKey: request) ?? [] { ready() }
  }
}

/// Owns the JavaScriptCore context and the fonts resvg draws with; touched
/// only on `queue`.
private final class Worker: @unchecked Sendable {
  let queue = DispatchQueue(label: "term.diagrams", qos: .userInitiated)
  private var context: JSContext?
  /// The terminal family the faces below and resvg's fonts were made for.
  private var family: String?
  /// The family's name as the font files give it, for the SVG.
  private var familyName = ""
  /// Regular and bold, at `measureSize`.
  private var faces: [CTFont] = []
  private static let measureSize: CGFloat = 100

  func render(_ source: String, _ request: DiagramEngine.Request) -> UIImage? {
    dispatchPrecondition(condition: .onQueue(queue))
    let style = request.style
    guard let context = loadedContext(), useFonts(style.family) else { return nil }
    let theme: [String: Any] = [
      "fg": style.foreground, "bg": style.background, "cursor": style.cursor,
      "palette": style.palette, "font": familyName, "fontSize": style.fontSize,
    ]
    guard let result = context.objectForKeyedSubscript("termRender")?
      .call(withArguments: [source, request.maxWidth, theme]),
      let svg = result.objectForKeyedSubscript("svg"), svg.isString,
      let width = result.objectForKeyedSubscript("width")?.toDouble(), width > 0
    else { return nil }
    let shown = min(width, Double(request.maxWidth))
    return Self.rasterize(svg.toString(), widthPx: UInt32((shown * style.scale).rounded()),
                          background: 0xFF00_0000 | style.background, scale: style.scale)
  }

  private func loadedContext() -> JSContext? {
    if let context { return context }
    guard let ctx = JSContext() else { return nil }
    for name in ["pele.global", "term-pele"] {
      guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Diagrams"),
            let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      ctx.evaluateScript(script, withSourceURL: url)
      if ctx.exception != nil { return nil }
    }
    let measure: @convention(block) (String, Double, Int) -> Double = { [unowned self] text, size, style in
      measureWidth(text, size: size, bold: style & 1 != 0)
    }
    ctx.setObject(measure, forKeyedSubscript: "termMeasure" as NSString)
    context = ctx
    return ctx
  }

  private func measureWidth(_ text: String, size: Double, bold: Bool) -> Double {
    guard let font = bold ? faces.last : faces.first else { return 0 }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    return CTLineGetTypographicBounds(line, nil, nil, nil) * size / Self.measureSize
  }

  /// CoreText measures and resvg draws the same files: the family's regular
  /// and bold faces.
  private func useFonts(_ family: String) -> Bool {
    if family == self.family { return true }
    let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
    let regular = CTFontCreateWithFontDescriptor(descriptor, Self.measureSize, nil)
    let bold = CTFontCreateCopyWithSymbolicTraits(regular, Self.measureSize, nil, .traitBold, .traitBold) ?? regular
    var paths: [String] = []
    for font in [regular, bold] {
      guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { continue }
      if !paths.contains(url.path) { paths.append(url.path) }
    }
    let loaded = withCStrings(paths) { term_svg_fonts($0, UInt32(paths.count)) }
    guard loaded > 0 else { return false }
    self.family = family
    familyName = CTFontCopyFamilyName(regular) as String
    faces = [regular, bold]
    return true
  }

  private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    let pointers = copies.map { UnsafePointer($0) }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
  }

  private static func rasterize(_ svg: String, widthPx: UInt32, background: UInt32, scale: Double) -> UIImage? {
    let bytes = Array(svg.utf8)
    var out = TermSvgImage()
    let status = bytes.withUnsafeBufferPointer { term_svg_render($0.baseAddress, $0.count, widthPx, background, &out) }
    guard status == Int32(TERM_SVG_OK.rawValue), let pixels = out.pixels else { return nil }
    let width = Int(out.width), height = Int(out.height)
    let data = Data(bytes: pixels, count: width * height * 4)
    term_svg_free(&out)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return UIImage(cgImage: image, scale: scale, orientation: .up)
  }
}
