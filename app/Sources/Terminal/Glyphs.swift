import CoreGraphics
import CoreText
import Metal

/// Where a rasterized glyph sits in an atlas and how it lines up with its cell.
struct GlyphEntry {
    var x: UInt16, y: UInt16        // atlas position, px
    var w: UInt16, h: UInt16        // bitmap size, px (0 = nothing to draw)
    var ox: Int16, oy: Int16        // bitmap top-left relative to the cell top-left
    var color: Bool                 // lives in the color atlas

    static let empty = GlyphEntry(x: 0, y: 0, w: 0, h: 0, ox: 0, oy: 0, color: false)
    fileprivate static let missing = GlyphEntry(x: 0, y: 0, w: .max, h: 0, ox: 0, oy: 0, color: false)
}

/// A shelf-packed texture that doubles in size when full.
@MainActor
final class Atlas {
    let format: MTLPixelFormat
    let bytesPerPixel: Int
    let maxSize: Int
    private let device: MTLDevice
    private(set) var texture: MTLTexture
    private(set) var size: Int
    private var shelves: [(y: Int, height: Int, x: Int)] = []
    private var bottom = 0

    init(device: MTLDevice, format: MTLPixelFormat, bytesPerPixel: Int, size: Int, maxSize: Int) {
        self.device = device
        self.format = format
        self.bytesPerPixel = bytesPerPixel
        self.size = size
        self.maxSize = maxSize
        texture = Atlas.makeTexture(device, format, size)
    }

    private static func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat, _ size: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else {
            preconditionFailure("cannot allocate a \(size)px glyph atlas")
        }
        return t
    }

    /// Reserves w×h; grows the texture when needed. nil = full at maxSize.
    func place(w: Int, h: Int, queue: MTLCommandQueue) -> (x: Int, y: Int)? {
        while true {
            if let p = fit(w: w, h: h) { return p }
            guard size * 2 <= maxSize else { return nil }
            grow(queue: queue)
        }
    }

    private func fit(w: Int, h: Int) -> (x: Int, y: Int)? {
        guard w <= size else { return nil }
        var best = -1
        for (i, s) in shelves.enumerated() where s.height >= h && s.height <= h + h / 4 + 2 && s.x + w <= size {
            if best < 0 || s.height < shelves[best].height { best = i }
        }
        if best >= 0 {
            let p = (x: shelves[best].x, y: shelves[best].y)
            shelves[best].x += w
            return p
        }
        guard bottom + h <= size else { return nil }
        shelves.append((y: bottom, height: h, x: w))
        defer { bottom += h }
        return (x: 0, y: bottom)
    }

    private func grow(queue: MTLCommandQueue) {
        let bigger = Atlas.makeTexture(device, format, size * 2)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: size, height: size, depth: 1),
                      to: bigger, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        texture = bigger
        size *= 2
    }

    func upload(x: Int, y: Int, w: Int, h: Int, bytes: UnsafeRawPointer) {
        texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: w * bytesPerPixel)
    }

    /// Forgets every glyph. A new texture, so frames still in flight keep theirs.
    func reset() {
        texture = Atlas.makeTexture(device, format, size)
        shelves.removeAll()
        bottom = 0
    }
}

/// Rasterizes glyphs on first use into a coverage atlas (text, box
/// drawing) or a color atlas (emoji), and remembers where they went.
@MainActor
final class GlyphCache {
    let fonts: FontSet
    let gray: Atlas
    let color: Atlas
    /// Bumps when the atlases were wiped; entries handed out earlier are void.
    private(set) var resets = 0

    private let queue: MTLCommandQueue
    private var ascii: [GlyphEntry]                    // style * 128 + cp
    private var singles: [UInt64: GlyphEntry] = [:]    // cp | style << 32
    private var clusters: [[UInt32]: GlyphEntry] = [:] // scalars + [style]
    private var scratch = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 16)
    private var scratchSize = 1

    init(device: MTLDevice, queue: MTLCommandQueue, fonts: FontSet) {
        self.queue = queue
        self.fonts = fonts
        let m = fonts.metrics
        let start = m.width * m.height > 1500 ? 2048 : 1024
        gray = Atlas(device: device, format: .r8Unorm, bytesPerPixel: 1, size: start, maxSize: 8192)
        color = Atlas(device: device, format: .bgra8Unorm, bytesPerPixel: 4, size: 512, maxSize: 4096)
        ascii = Array(repeating: .missing, count: 8 * 128)
    }

    isolated deinit {
        scratch.deallocate()
    }

    /// `style`: bit 0 bold, bit 1 italic, bit 2 wide (two cells).
    @inline(__always)
    func entry(_ cp: UInt32, style: Int) -> GlyphEntry {
        if cp < 128 {
            let e = ascii[style << 7 | Int(cp)]
            if e.w != .max { return e }
            let made = rasterize(single: cp, style: style)
            ascii[style << 7 | Int(cp)] = made
            return made
        }
        let key = UInt64(cp) | UInt64(style) << 32
        if let e = singles[key] { return e }
        let made = rasterize(single: cp, style: style)
        singles[key] = made
        return made
    }

    /// A multi-codepoint grapheme (emoji sequences, combining marks).
    func entry(cluster: UnsafeBufferPointer<UInt32>, style: Int) -> GlyphEntry {
        var key = Array(cluster)
        key.append(UInt32(style))
        if let e = clusters[key] { return e }
        let made = rasterize(text: String(String.UnicodeScalarView(cluster.compactMap(Unicode.Scalar.init))), style: style)
        clusters[key] = made
        return made
    }

    // ------------------------------------------------------------ raster

    private func rasterize(single cp: UInt32, style: Int) -> GlyphEntry {
        if Sprites.covers(cp) { return sprite(cp) }
        guard let scalar = Unicode.Scalar(cp) else { return .empty }
        let font = fonts.face(style)
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 {
            return glyph(glyphs[0], font: font, span: style & 4 != 0 ? 2 : 1)
        }
        return rasterize(text: String(scalar), style: style)
    }

    /// A glyph of the bundled font, on the baseline, centered in its span.
    private func glyph(_ g: CGGlyph, font: CTFont, span: Int) -> GlyphEntry {
        var g = g
        let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, nil, 1)
        guard !ink.isEmpty, !ink.isNull else { return .empty }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        let m = fonts.metrics
        let shift = advance.width < CGFloat(span * m.width)
            ? ((CGFloat(span * m.width) - advance.width) / 2).rounded() : 0
        let left = Int(ink.minX.rounded(.down)) - 1, right = Int(ink.maxX.rounded(.up)) + 1
        let bottom = Int(ink.minY.rounded(.down)) - 1, top = Int(ink.maxY.rounded(.up)) + 1
        return store(w: right - left, h: top - bottom, color: false,
                     ox: left + Int(shift), oy: m.baseline - top) { ctx in
            var pos = CGPoint(x: CGFloat(-left), y: CGFloat(-bottom))
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
        }
    }

    /// Text CoreText has to shape or find in a fallback font (CJK, emoji,
    /// combining marks). Color glyphs are scaled to fit their cells and
    /// centered; others keep the baseline and shrink only if too wide.
    private func rasterize(text: String, style: Int) -> GlyphEntry {
        guard !text.isEmpty else { return .empty }
        let font = fonts.face(style)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as [CFString: Any]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return .empty }
        let line = CTLineCreateWithAttributedString(attributed)
        let m = fonts.metrics
        let boxW = CGFloat((style & 4 != 0 ? 2 : 1) * m.width)
        let boxH = CGFloat(m.height)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let isColor = runs.contains { run in
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            guard let f = runAttrs[kCTFontAttributeName as String] else { return false }
            return CTFontGetSymbolicTraits(f as! CTFont).contains(.traitColorGlyphs)
        }

        if isColor {
            let height = ascent + descent
            guard advance > 0, height > 0 else { return .empty }
            let s = min(1, boxW / advance, boxH / height)
            let dw = advance * s, dh = height * s
            let w = Int(dw.rounded(.up)) + 2, h = Int(dh.rounded(.up)) + 2
            return store(w: w, h: h, color: true,
                         ox: Int(((boxW - dw) / 2).rounded(.down)) - 1,
                         oy: Int(((boxH - dh) / 2).rounded(.down)) - 1) { ctx in
                ctx.translateBy(x: 1, y: 1)
                ctx.scaleBy(x: s, y: s)
                ctx.textPosition = CGPoint(x: 0, y: descent)
                CTLineDraw(line, ctx)
            }
        }

        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isEmpty, !ink.isNull else { return .empty }
        let s = advance > boxW * 1.05 ? boxW / advance : 1
        let shift = advance * s < boxW ? ((boxW - advance * s) / 2).rounded() : 0
        let left = Int((ink.minX * s).rounded(.down)) - 1, right = Int((ink.maxX * s).rounded(.up)) + 1
        let bottom = Int((ink.minY * s).rounded(.down)) - 1, top = Int((ink.maxY * s).rounded(.up)) + 1
        return store(w: right - left, h: top - bottom, color: false,
                     ox: left + Int(shift), oy: m.baseline - top) { ctx in
            ctx.translateBy(x: CGFloat(-left), y: CGFloat(-bottom))
            ctx.scaleBy(x: s, y: s)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
        }
    }

    private func sprite(_ cp: UInt32) -> GlyphEntry {
        let m = fonts.metrics
        return store(w: m.width + 2, h: m.height + 2, color: false, ox: -1, oy: -1) { ctx in
            ctx.translateBy(x: 1, y: CGFloat(m.height + 1))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(true)
            Sprites.draw(cp, in: ctx, metrics: m)
        }
    }

    /// Draws into a cleared bitmap of w×h (1 px empty border expected),
    /// then copies it into the right atlas.
    private func store(w: Int, h: Int, color: Bool, ox: Int, oy: Int, draw: (CGContext) -> Void) -> GlyphEntry {
        guard w > 0, h > 0, w < 4096, h < 4096 else { return .empty }
        let atlas = color ? self.color : gray
        let bytesPerRow = w * atlas.bytesPerPixel
        if bytesPerRow * h > scratchSize {
            scratch.deallocate()
            scratchSize = bytesPerRow * h
            scratch = .allocate(byteCount: scratchSize, alignment: 16)
        }
        memset(scratch, 0, bytesPerRow * h)
        let ctx: CGContext?
        if color {
            ctx = CGContext(data: scratch, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        } else {
            ctx = CGContext(data: scratch, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
        }
        guard let ctx else { return .empty }
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setShouldSubpixelPositionFonts(true)
        draw(ctx)

        guard let p = atlas.place(w: w, h: h, queue: queue) else {
            wipe()
            return store(w: w, h: h, color: color, ox: ox, oy: oy, draw: draw)
        }
        atlas.upload(x: p.x, y: p.y, w: w, h: h, bytes: scratch)
        return GlyphEntry(x: UInt16(p.x), y: UInt16(p.y), w: UInt16(w), h: UInt16(h),
                          ox: Int16(clamping: ox), oy: Int16(clamping: oy), color: color)
    }

    /// Both atlases are full at their largest size: start over.
    private func wipe() {
        gray.reset()
        color.reset()
        ascii = Array(repeating: .missing, count: 8 * 128)
        singles.removeAll()
        clusters.removeAll()
        resets += 1
    }
}
