import Metal
import QuartzCore
import Synchronization

/// The last frame the core produced, copied so the view can redraw local
/// state (selection, cursor blink, zoom) and read cells between frames.
struct FrameSnapshot {
    var generation: UInt64 = 0
    var cols = 0
    var rows = 0
    var cursorCol = 0
    var cursorRow = 0
    var cursorVisible = false
    var cursorStyle = UInt32(TERM_CURSOR_BLOCK.rawValue)
    var cursorBlink = false
    var fg: UInt32 = 0xFFE6_E6E6
    var bg: UInt32 = 0xFF00_0000
    var cursorColor: UInt32 = 0
    var modes: UInt32 = 0
    var historyRows = 0
    var viewportOffset = 0
    var cells: [TermCell] = []
    var graphemes: [TermGrapheme] = []
    var codepoints: [UInt32] = []

    mutating func load(_ f: TermFrame) {
        generation = f.generation
        cols = Int(f.cols)
        rows = Int(f.rows)
        cursorCol = Int(f.cursor_col)
        cursorRow = Int(f.cursor_row)
        cursorVisible = f.cursor_visible != 0
        cursorStyle = UInt32(f.cursor_style)
        cursorBlink = f.cursor_blink != 0
        fg = f.fg
        bg = f.bg
        cursorColor = f.cursor_color
        modes = f.modes
        historyRows = Int(f.history_rows)
        viewportOffset = Int(f.viewport_offset)
        cells.removeAll(keepingCapacity: true)
        if let p = f.cells { cells.append(contentsOf: UnsafeBufferPointer(start: p, count: cols * rows)) }
        graphemes.removeAll(keepingCapacity: true)
        codepoints.removeAll(keepingCapacity: true)
        if f.grapheme_count > 0, let g = f.graphemes, let cps = f.codepoints {
            let gs = UnsafeBufferPointer(start: g, count: Int(f.grapheme_count))
            graphemes.append(contentsOf: gs)
            let total = gs.reduce(0) { max($0, Int($1.offset + $1.len)) }
            codepoints.append(contentsOf: UnsafeBufferPointer(start: cps, count: total))
        }
    }

    func has(_ mode: Int) -> Bool { modes & UInt32(mode) != 0 }

    /// The scalars of the cell at index i (its grapheme, or its one codepoint).
    func scalars(at i: Int) -> [UInt32] {
        let c = cells[i]
        guard c.grapheme != 0 else { return c.ch == 0 ? [] : [c.ch] }
        let g = graphemes[Int(c.grapheme) - 1]
        return Array(codepoints[Int(g.offset)..<Int(g.offset + g.len)])
    }
}

/// Cells highlighted as selected, in viewport rows (row-major stream).
struct SelectionSpan: Equatable {
    var startRow: Int, startCol: Int
    var endRow: Int, endCol: Int

    /// Inclusive column range selected in `row`, or nil.
    func columns(inRow row: Int, cols: Int) -> ClosedRange<Int>? {
        guard row >= startRow, row <= endRow else { return nil }
        let from = row == startRow ? startCol : 0
        let to = row == endRow ? endCol : cols - 1
        return from <= to ? from...to : nil
    }
}

// Layouts mirror Shaders.metal.
private struct Uniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var cell: SIMD2<Float>
    var zoomCenter: SIMD2<Float>
    var zoom: Float
    var cols: UInt32
    var rows: UInt32
    var defaultBg: UInt32
}

private struct GlyphInstance {
    var x: Int16, y: Int16
    var w: UInt16, h: UInt16
    var u: UInt16, v: UInt16
    var color: UInt32
    var flags: UInt32
}

private struct RectInstance {
    var x: Float, y: Float, w: Float, h: Float
    var color: UInt32
    var kind: UInt32
}

private enum RectStyle: UInt32 { case solid = 0, curly = 1, dotted = 2, dashed = 3 }

/// Draws frames with Metal: one full-screen pass for cell backgrounds,
/// instanced quads for glyphs from the atlases, instanced rects for
/// underlines, strikes and the cursor.
@MainActor
final class Renderer {
    struct Overlay {
        var focused = true
        var cursorOn = true         // blink phase of the cursor
        var blinkOn = true          // blink phase of SGR 5 text
        var selection: SelectionSpan?
        var selectionColor: UInt32 = 0xFF0A_84FF
    }

    struct Placement {
        var viewport: SIMD2<Float>      // drawable px
        var origin: SIMD2<Float>        // grid top-left px
        var zoom: Float = 1
        var zoomCenter: SIMD2<Float> = .zero
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private(set) var glyphs: GlyphCache
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let rectPipeline: MTLRenderPipelineState

    private final class Slot {
        var bg: MTLBuffer?
        var glyphs: MTLBuffer?
        var rects: MTLBuffer?
        var cells = 0
        var glyphCount = 0
        var rectCount = 0
        var cols = 0, rows = 0
        var defaultBg: UInt32 = 0xFF00_0000
    }
    private let slots = [Slot(), Slot(), Slot()]
    private var current = 0
    private var built = false
    private var rects: [RectInstance] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private final class GPUClock: Sendable { let nanos = Atomic<UInt64>(0) }
    private let gpuClock = GPUClock()

    /// True when the last built frame has visible SGR-blink cells.
    private(set) var hasBlinkingText = false
    /// CPU time of the last `build`, seconds.
    private(set) var lastBuildTime: Double = 0
    /// GPU time of the most recently completed frame, seconds.
    var lastGPUTime: Double { Double(gpuClock.nanos.load(ordering: .relaxed)) / 1e9 }

    init?(fonts: FontSet) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            if blend {
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let bg = pipeline("bg_vertex", "bg_fragment", blend: false),
              let glyph = pipeline("glyph_vertex", "glyph_fragment", blend: true),
              let rect = pipeline("rect_vertex", "rect_fragment", blend: true) else { return nil }
        bgPipeline = bg
        glyphPipeline = glyph
        rectPipeline = rect
        glyphs = GlyphCache(device: device, queue: queue, fonts: fonts)
    }

    var fonts: FontSet { glyphs.fonts }

    func setFonts(_ fonts: FontSet) {
        glyphs = GlyphCache(device: device, queue: queue, fonts: fonts)
        built = false
    }

    // ------------------------------------------------------------ build

    /// Turns a frame into GPU instance data for the next `encode`.
    func build(_ s: FrameSnapshot, overlay o: Overlay) {
        let start = CACurrentMediaTime()
        inFlight.wait()
        defer { inFlight.signal() }
        let slot = slots[(current + 1) % slots.count]
        var resets = glyphs.resets
        fill(slot, s, o)
        if glyphs.resets != resets {
            // The atlas filled up mid-frame and was wiped; earlier cells point at nothing.
            resets = glyphs.resets
            fill(slot, s, o)
        }
        current = (current + 1) % slots.count
        built = true
        lastBuildTime = CACurrentMediaTime() - start
    }

    private func buffer(_ b: inout MTLBuffer?, bytes: Int) -> MTLBuffer {
        if let b, b.length >= bytes { return b }
        let made = device.makeBuffer(length: max(bytes, 256), options: .storageModeShared)!
        b = made
        return made
    }

    private func fill(_ slot: Slot, _ s: FrameSnapshot, _ o: Overlay) {
        let cols = s.cols, rows = s.rows, n = cols * rows
        let bgBuf = buffer(&slot.bg, bytes: n * 4)
        let glyphBuf = buffer(&slot.glyphs, bytes: n * MemoryLayout<GlyphInstance>.stride)
        let bgOut = bgBuf.contents().bindMemory(to: UInt32.self, capacity: max(n, 1))
        let glyphOut = glyphBuf.contents().bindMemory(to: GlyphInstance.self, capacity: max(n, 1))
        rects.removeAll(keepingCapacity: true)

        let m = glyphs.fonts.metrics
        let cw = m.width, ch = m.height, t = m.stroke
        let defaultBg = s.bg | 0xFF00_0000
        let cursorColor = s.cursorColor >> 24 != 0 ? s.cursorColor : s.fg
        let showCursor = s.cursorVisible && s.cursorRow < rows && s.cursorCol < cols
            && (o.cursorOn || !o.focused || !s.cursorBlink)
        let cursorStyle: UInt32 = o.focused ? s.cursorStyle : UInt32(TERM_CURSOR_BLOCK_HOLLOW.rawValue)
        let blockCursor = showCursor && cursorStyle == UInt32(TERM_CURSOR_BLOCK.rawValue)
        let cursorIndex = s.cursorRow * cols + s.cursorCol
        let cursorWide = showCursor && n > 0 && s.cells[cursorIndex].flags & UInt16(TERM_CELL_WIDE) != 0
        let selColor = o.selectionColor
        var glyphCount = 0
        var blinking = false

        s.cells.withUnsafeBufferPointer { cells in
            for row in 0..<rows {
                let sel = o.selection?.columns(inRow: row, cols: cols)
                let y = row * ch
                for col in 0..<cols {
                    let i = row * cols + col
                    let c = cells[i]
                    let f = UInt32(c.flags)
                    var fg = c.fg
                    var bg = c.bg
                    if f & UInt32(TERM_CELL_SELECTED) != 0 || sel?.contains(col) == true {
                        bg = Renderer.mix(bg == 0 ? defaultBg : bg, selColor, 0.45)
                    }
                    if blockCursor && (i == cursorIndex || (cursorWide && i == cursorIndex + 1)) {
                        fg = bg >> 24 == 0 ? defaultBg : bg | 0xFF00_0000
                        bg = cursorColor
                    }
                    bgOut[i] = bg
                    if f & UInt32(TERM_CELL_SPACER) != 0 { continue }
                    if f & UInt32(TERM_CELL_FAINT) != 0 {
                        fg = (fg & 0x00FF_FFFF) | ((fg >> 25) << 24)
                    }
                    let blinkHidden = f & UInt32(TERM_CELL_BLINK) != 0 && !o.blinkOn
                    if f & UInt32(TERM_CELL_BLINK) != 0 { blinking = true }
                    let wide = f & UInt32(TERM_CELL_WIDE) != 0
                    let x = col * cw

                    if c.ch > 32, f & UInt32(TERM_CELL_INVISIBLE) == 0, !blinkHidden {
                        let style = Int(f & 3) | (wide ? 4 : 0)
                        let e: GlyphEntry
                        if c.grapheme != 0 {
                            let g = s.graphemes[Int(c.grapheme) - 1]
                            e = s.codepoints.withUnsafeBufferPointer {
                                glyphs.entry(cluster: UnsafeBufferPointer(rebasing: $0[Int(g.offset)..<Int(g.offset + g.len)]), style: style)
                            }
                        } else {
                            e = glyphs.entry(c.ch, style: style)
                        }
                        if e.w > 0 {
                            glyphOut[glyphCount] = GlyphInstance(
                                x: Int16(truncatingIfNeeded: x + Int(e.ox)), y: Int16(truncatingIfNeeded: y + Int(e.oy)),
                                w: e.w, h: e.h, u: e.x, v: e.y, color: fg, flags: e.color ? 1 : 0)
                            glyphCount += 1
                        }
                    }

                    // Decorations.
                    let span = Float(wide ? 2 * cw : cw)
                    var underline = (f & UInt32(TERM_CELL_UNDERLINE_MASK)) >> UInt32(TERM_CELL_UNDERLINE_SHIFT)
                    if f & UInt32(TERM_CELL_PREDICTED) != 0, underline == 0 { underline = 1 }
                    if underline != 0 {
                        let color = c.ul != 0 ? c.ul : fg
                        addUnderline(Int32(underline), x: Float(x), y: y, span: span, color: color, m: m)
                    }
                    if f & UInt32(TERM_CELL_STRIKE) != 0 {
                        rects.append(RectInstance(x: Float(x), y: Float(y + m.strikeY), w: span, h: Float(t), color: fg, kind: 0))
                    }
                    if f & UInt32(TERM_CELL_OVERLINE) != 0 {
                        rects.append(RectInstance(x: Float(x), y: Float(y), w: span, h: Float(t), color: fg, kind: 0))
                    }
                }
            }
        }

        if showCursor && !blockCursor {
            let x = Float(s.cursorCol * cw), y = Float(s.cursorRow * ch)
            let w = Float((cursorWide ? 2 : 1) * cw), h = Float(ch)
            let bar = Float(max(1, Int((1.5 * fonts.scale).rounded())))
            let line = Float(max(1, Int(fonts.scale.rounded())))
            switch cursorStyle {
            case UInt32(TERM_CURSOR_BAR.rawValue):
                rects.append(RectInstance(x: x, y: y, w: bar, h: h, color: cursorColor, kind: 0))
            case UInt32(TERM_CURSOR_UNDERLINE.rawValue):
                rects.append(RectInstance(x: x, y: y + h - bar, w: w, h: bar, color: cursorColor, kind: 0))
            default:
                rects.append(RectInstance(x: x, y: y, w: w, h: line, color: cursorColor, kind: 0))
                rects.append(RectInstance(x: x, y: y + h - line, w: w, h: line, color: cursorColor, kind: 0))
                rects.append(RectInstance(x: x, y: y + line, w: line, h: h - 2 * line, color: cursorColor, kind: 0))
                rects.append(RectInstance(x: x + w - line, y: y + line, w: line, h: h - 2 * line, color: cursorColor, kind: 0))
            }
        }

        let rectBuf = buffer(&slot.rects, bytes: rects.count * MemoryLayout<RectInstance>.stride)
        rects.withUnsafeBytes { raw in
            if let base = raw.baseAddress { rectBuf.contents().copyMemory(from: base, byteCount: raw.count) }
        }
        slot.cells = n
        slot.cols = cols
        slot.rows = rows
        slot.glyphCount = glyphCount
        slot.rectCount = rects.count
        slot.defaultBg = defaultBg
        hasBlinkingText = blinking
    }

    private func addUnderline(_ style: Int32, x: Float, y: Int, span: Float, color: UInt32, m: CellMetrics) {
        let t = m.stroke
        switch style {
        case Int32(TERM_UNDERLINE_DOUBLE.rawValue):
            var y1 = m.underlineY
            if y1 + 3 * t > m.height { y1 = m.height - 3 * t }
            rects.append(RectInstance(x: x, y: Float(y + y1), w: span, h: Float(t), color: color, kind: 0))
            rects.append(RectInstance(x: x, y: Float(y + y1 + 2 * t), w: span, h: Float(t), color: color, kind: 0))
        case Int32(TERM_UNDERLINE_CURLY.rawValue):
            let h = max(3 * t + 2, 5)
            let top = min(m.underlineY - t, m.height - h)
            rects.append(RectInstance(x: x, y: Float(y + top), w: span, h: Float(h), color: color,
                                      kind: RectStyle.curly.rawValue | UInt32(t) << 8))
        case Int32(TERM_UNDERLINE_DOTTED.rawValue):
            rects.append(RectInstance(x: x, y: Float(y + m.underlineY), w: span, h: Float(t), color: color,
                                      kind: RectStyle.dotted.rawValue | UInt32(t) << 8))
        case Int32(TERM_UNDERLINE_DASHED.rawValue):
            rects.append(RectInstance(x: x, y: Float(y + m.underlineY), w: span, h: Float(t), color: color,
                                      kind: RectStyle.dashed.rawValue | UInt32(t) << 8))
        default:
            rects.append(RectInstance(x: x, y: Float(y + m.underlineY), w: span, h: Float(t), color: color, kind: 0))
        }
    }

    /// Straight-alpha mix of two 0xAARRGGBB colors; the result is opaque.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        func ch(_ c: UInt32, _ s: UInt32) -> Float { Float((c >> s) & 0xFF) }
        func lerp(_ s: UInt32) -> UInt32 { UInt32((ch(a, s) * (1 - t) + ch(b, s) * t).rounded()) << s }
        return 0xFF00_0000 | lerp(16) | lerp(8) | lerp(0)
    }

    // ------------------------------------------------------------ encode

    /// Draws the last built frame into `texture`. Returns the command
    /// buffer, uncommitted, so the caller can present and commit it.
    func encode(into texture: MTLTexture, placement p: Placement) -> MTLCommandBuffer? {
        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return nil
        }
        let semaphore = inFlight
        let gpu = gpuClock
        cb.addCompletedHandler { cb in
            let ns = max(0, cb.gpuEndTime - cb.gpuStartTime) * 1e9
            gpu.nanos.store(UInt64(ns), ordering: .relaxed)
            semaphore.signal()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return cb }

        let slot = slots[current]
        let m = glyphs.fonts.metrics
        let grid = built ? slot.bg : nil
        var u = Uniforms(viewport: p.viewport, origin: p.origin,
                         cell: SIMD2(Float(m.width), Float(m.height)),
                         zoomCenter: p.zoomCenter, zoom: p.zoom,
                         cols: UInt32(grid != nil ? slot.cols : 0), rows: UInt32(grid != nil ? slot.rows : 0),
                         defaultBg: slot.defaultBg)
        let uSize = MemoryLayout<Uniforms>.stride

        enc.setRenderPipelineState(bgPipeline)
        enc.setFragmentBytes(&u, length: uSize, index: 0)
        if let grid {
            enc.setFragmentBuffer(grid, offset: 0, index: 1)
        } else {
            var zero: UInt32 = 0
            enc.setFragmentBytes(&zero, length: 4, index: 1)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if built, slot.glyphCount > 0, let g = slot.glyphs {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBytes(&u, length: uSize, index: 0)
            enc.setVertexBuffer(g, offset: 0, index: 1)
            enc.setFragmentTexture(glyphs.gray.texture, index: 0)
            enc.setFragmentTexture(glyphs.color.texture, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: slot.glyphCount)
        }
        if built, slot.rectCount > 0, let r = slot.rects {
            enc.setRenderPipelineState(rectPipeline)
            enc.setVertexBytes(&u, length: uSize, index: 0)
            enc.setVertexBuffer(r, offset: 0, index: 1)
            enc.setFragmentBytes(&u, length: uSize, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: slot.rectCount)
        }
        enc.endEncoding()
        return cb
    }
}
