import CoreGraphics

/// Box drawing (U+2500–257F), block elements (U+2580–259F) and Powerline
/// separators (U+E0B0–E0BF) drawn from cell metrics instead of the font,
/// so lines meet exactly at cell edges and separators fill the cell.
/// Line geometry follows Ghostty's sprite font (src/font/sprite/draw, MIT).
enum Sprites {
    static func covers(_ cp: UInt32) -> Bool {
        (0x2500...0x259F).contains(cp) || (0xE0B0...0xE0BF).contains(cp)
    }

    /// Draws `cp` as white coverage into `ctx`, a gray context cleared to
    /// black whose CTM maps one cell with y pointing down from its top.
    static func draw(_ cp: UInt32, in ctx: CGContext, metrics m: CellMetrics) {
        let c = Canvas(ctx: ctx, w: m.width, h: m.height, light: m.stroke)
        switch cp {
        case 0x2500...0x257F: c.boxDrawing(cp)
        case 0x2580...0x259F: c.block(cp)
        default: c.powerline(cp)
        }
    }

    /// Per code point from U+2500: up, right, down, left as
    /// "." none, "l" light, "h" heavy, "d" double. Empty = special case.
    private static let lines: [String] = [
        ".l.l", ".h.h", "l.l.", "h.h.", "", "", "", "", "", "", "", "", ".ll.", ".hl.", ".lh.", ".hh.",  // 2500
        "..ll", "..lh", "..hl", "..hh", "ll..", "lh..", "hl..", "hh..", "l..l", "l..h", "h..l", "h..h", "lll.", "lhl.", "hll.", "llh.",  // 2510
        "hlh.", "hhl.", "lhh.", "hhh.", "l.ll", "l.lh", "h.ll", "l.hl", "h.hl", "h.lh", "l.hh", "h.hh", ".lll", ".llh", ".hll", ".hlh",  // 2520
        ".lhl", ".lhh", ".hhl", ".hhh", "ll.l", "ll.h", "lh.l", "lh.h", "hl.l", "hl.h", "hh.l", "hh.h", "llll", "lllh", "lhll", "lhlh",  // 2530
        "hlll", "llhl", "hlhl", "hllh", "hhll", "llhh", "lhhl", "hhlh", "lhhh", "hlhh", "hhhl", "hhhh", "", "", "", "",  // 2540
        ".d.d", "d.d.", ".dl.", ".ld.", ".dd.", "..ld", "..dl", "..dd", "ld..", "dl..", "dd..", "l..d", "d..l", "d..d", "ldl.", "dld.",  // 2550
        "ddd.", "l.ld", "d.dl", "d.dd", ".dld", ".ldl", ".ddd", "ld.d", "dl.l", "dd.d", "ldld", "dldl", "dddd", "", "", "",  // 2560
        "", "", "", "", "...l", "l...", ".l..", "..l.", "...h", "h...", ".h..", "..h.", ".h.l", "l.h.", ".l.h", "h.l.",  // 2570
    ]

    private enum Style: UInt8 { case none, light, heavy, double }

    private struct Canvas {
        let ctx: CGContext
        let w: Int
        let h: Int
        let light: Int
        var heavy: Int { light * 2 }

        func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, alpha: CGFloat = 1) {
            guard x1 > x0, y1 > y0 else { return }
            ctx.setFillColor(CGColor(gray: alpha, alpha: 1))
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }

        func fillPath(_ points: [CGPoint]) {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.beginPath()
            ctx.addLines(between: points)
            ctx.closePath()
            ctx.fillPath()
        }

        func stroke(_ build: (CGMutablePath) -> Void, width: CGFloat) {
            let path = CGMutablePath()
            build(path)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(width)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.miter)
            ctx.addPath(path)
            ctx.strokePath()
        }

        // -------------------------------------------------------- box

        func boxDrawing(_ cp: UInt32) {
            let spec = Sprites.lines[Int(cp - 0x2500)]
            if !spec.isEmpty {
                let s = spec.utf8.map { b -> Style in
                    switch b {
                    case UInt8(ascii: "l"): .light
                    case UInt8(ascii: "h"): .heavy
                    case UInt8(ascii: "d"): .double
                    default: .none
                    }
                }
                lines(up: s[0], right: s[1], down: s[2], left: s[3])
                return
            }
            switch cp {
            case 0x2504: dashH(3, light)
            case 0x2505: dashH(3, heavy)
            case 0x2506: dashV(3, light)
            case 0x2507: dashV(3, heavy)
            case 0x2508: dashH(4, light)
            case 0x2509: dashH(4, heavy)
            case 0x250A: dashV(4, light)
            case 0x250B: dashV(4, heavy)
            case 0x254C: dashH(2, light)
            case 0x254D: dashH(2, heavy)
            case 0x254E: dashV(2, light)
            case 0x254F: dashV(2, heavy)
            case 0x256D: arc(down: true, right: true)
            case 0x256E: arc(down: true, right: false)
            case 0x256F: arc(down: false, right: false)
            case 0x2570: arc(down: false, right: true)
            case 0x2571: diagonal(rising: true)
            case 0x2572: diagonal(rising: false)
            case 0x2573: diagonal(rising: true); diagonal(rising: false)
            default: break
            }
        }

        private func lines(up: Style, right: Style, down: Style, left: Style) {
            let hLightTop = max(h - light, 0) / 2
            let hLightBottom = hLightTop + light
            let hHeavyTop = max(h - heavy, 0) / 2
            let hHeavyBottom = hHeavyTop + heavy
            let hDoubleTop = max(hLightTop - light, 0)
            let hDoubleBottom = hLightBottom + light
            let vLightLeft = max(w - light, 0) / 2
            let vLightRight = vLightLeft + light
            let vHeavyLeft = max(w - heavy, 0) / 2
            let vHeavyRight = vHeavyLeft + heavy
            let vDoubleLeft = max(vLightLeft - light, 0)
            let vDoubleRight = vLightRight + light

            let upBottom: Int =
                if left == .heavy || right == .heavy { hHeavyBottom }
                else if left != right || down == up { (left == .double || right == .double) ? hDoubleBottom : hLightBottom }
                else if left == .none && right == .none { hLightBottom }
                else { hLightTop }
            let downTop: Int =
                if left == .heavy || right == .heavy { hHeavyTop }
                else if left != right || up == down { (left == .double || right == .double) ? hDoubleTop : hLightTop }
                else if left == .none && right == .none { hLightTop }
                else { hLightBottom }
            let leftRight: Int =
                if up == .heavy || down == .heavy { vHeavyRight }
                else if up != down || left == right { (up == .double || down == .double) ? vDoubleRight : vLightRight }
                else if up == .none && down == .none { vLightRight }
                else { vLightLeft }
            let rightLeft: Int =
                if up == .heavy || down == .heavy { vHeavyLeft }
                else if up != down || right == left { (up == .double || down == .double) ? vDoubleLeft : vLightLeft }
                else if up == .none && down == .none { vLightLeft }
                else { vLightRight }

            switch up {
            case .none: break
            case .light: box(vLightLeft, 0, vLightRight, upBottom)
            case .heavy: box(vHeavyLeft, 0, vHeavyRight, upBottom)
            case .double:
                box(vDoubleLeft, 0, vLightLeft, left == .double ? hLightTop : upBottom)
                box(vLightRight, 0, vDoubleRight, right == .double ? hLightTop : upBottom)
            }
            switch right {
            case .none: break
            case .light: box(rightLeft, hLightTop, w, hLightBottom)
            case .heavy: box(rightLeft, hHeavyTop, w, hHeavyBottom)
            case .double:
                box(up == .double ? vLightRight : rightLeft, hDoubleTop, w, hLightTop)
                box(down == .double ? vLightRight : rightLeft, hLightBottom, w, hDoubleBottom)
            }
            switch down {
            case .none: break
            case .light: box(vLightLeft, downTop, vLightRight, h)
            case .heavy: box(vHeavyLeft, downTop, vHeavyRight, h)
            case .double:
                box(vDoubleLeft, left == .double ? hLightBottom : downTop, vLightLeft, h)
                box(vLightRight, right == .double ? hLightBottom : downTop, vDoubleRight, h)
            }
            switch left {
            case .none: break
            case .light: box(0, hLightTop, leftRight, hLightBottom)
            case .heavy: box(0, hHeavyTop, leftRight, hHeavyBottom)
            case .double:
                box(0, hDoubleTop, up == .double ? vLightLeft : leftRight, hLightTop)
                box(0, hLightBottom, down == .double ? vLightLeft : leftRight, hDoubleBottom)
            }
        }

        /// Dashes tile seamlessly: half gaps at both ends.
        private func dashH(_ count: Int, _ thick: Int) {
            let y = max(h - thick, 0) / 2
            guard w >= count * 2 else { box(0, y, w, y + thick); return }
            let gap = min(max(4, light), w / (2 * count))
            let dashTotal = w - count * gap
            let dash = dashTotal / count
            var extra = dashTotal % count
            var x = gap / 2
            for _ in 0..<count {
                var x1 = x + dash
                if extra > 0 { extra -= 1; x1 += 1 }
                box(x, y, x1, y + thick)
                x = x1 + gap
            }
        }

        /// Dashes start at the top; one full gap at the bottom.
        private func dashV(_ count: Int, _ thick: Int) {
            let x = max(w - thick, 0) / 2
            guard h >= count * 2 else { box(x, 0, x + thick, h); return }
            let gap = min(max(4, light), h / (2 * count))
            let dashTotal = h - count * gap
            let dash = dashTotal / count
            var extra = dashTotal % count
            var y = 0
            for _ in 0..<count {
                var y1 = y + dash
                if extra > 0 { extra -= 1; y1 += 1 }
                box(x, y, x + thick, y1)
                y = y1 + gap
            }
        }

        private func arc(down: Bool, right: Bool) {
            let t = CGFloat(light)
            let cx = CGFloat(max(w - light, 0) / 2) + t / 2
            let cy = CGFloat(max(h - light, 0) / 2) + t / 2
            let fw = CGFloat(w), fh = CGFloat(h)
            let r = min(fw, fh) / 2
            let s: CGFloat = 0.25
            let vy: CGFloat = down ? 1 : -1
            let hx: CGFloat = right ? 1 : -1
            stroke({ p in
                p.move(to: CGPoint(x: cx, y: down ? fh : 0))
                p.addLine(to: CGPoint(x: cx, y: cy + vy * r))
                p.addCurve(to: CGPoint(x: cx + hx * r, y: cy),
                           control1: CGPoint(x: cx, y: cy + vy * s * r),
                           control2: CGPoint(x: cx + hx * s * r, y: cy))
                p.addLine(to: CGPoint(x: right ? fw : 0, y: cy))
            }, width: t)
        }

        private func diagonal(rising: Bool) {
            let fw = CGFloat(w), fh = CGFloat(h)
            let sx = min(1, fw / fh) * 0.5
            let sy = min(1, fh / fw) * 0.5
            stroke({ p in
                if rising {
                    p.move(to: CGPoint(x: fw + sx, y: -sy))
                    p.addLine(to: CGPoint(x: -sx, y: fh + sy))
                } else {
                    p.move(to: CGPoint(x: -sx, y: -sy))
                    p.addLine(to: CGPoint(x: fw + sx, y: fh + sy))
                }
            }, width: CGFloat(light))
        }

        // -------------------------------------------------------- blocks

        func block(_ cp: UInt32) {
            let eighths: [UInt32: Int] = [0x2581: 1, 0x2582: 2, 0x2583: 3, 0x2584: 4, 0x2585: 5, 0x2586: 6, 0x2587: 7]
            let leftEighths: [UInt32: Int] = [0x2589: 7, 0x258A: 6, 0x258B: 5, 0x258C: 4, 0x258D: 3, 0x258E: 2, 0x258F: 1]
            if let n = eighths[cp] {
                let bh = Int((CGFloat(h) * CGFloat(n) / 8).rounded())
                box(0, h - bh, w, h)
                return
            }
            if let n = leftEighths[cp] {
                box(0, 0, Int((CGFloat(w) * CGFloat(n) / 8).rounded()), h)
                return
            }
            let halfW = Int((CGFloat(w) / 2).rounded())
            let halfH = Int((CGFloat(h) / 2).rounded())
            func quads(tl: Bool = false, tr: Bool = false, bl: Bool = false, br: Bool = false) {
                if tl { box(0, 0, halfW, halfH) }
                if tr { box(halfW, 0, w, halfH) }
                if bl { box(0, halfH, halfW, h) }
                if br { box(halfW, halfH, w, h) }
            }
            switch cp {
            case 0x2580: box(0, 0, w, halfH)
            case 0x2588: box(0, 0, w, h)
            case 0x2590: box(w - halfW, 0, w, h)
            case 0x2591: box(0, 0, w, h, alpha: 0.25)
            case 0x2592: box(0, 0, w, h, alpha: 0.5)
            case 0x2593: box(0, 0, w, h, alpha: 0.75)
            case 0x2594: box(0, 0, w, Int((CGFloat(h) / 8).rounded()))
            case 0x2595: box(w - Int((CGFloat(w) / 8).rounded()), 0, w, h)
            case 0x2596: quads(bl: true)
            case 0x2597: quads(br: true)
            case 0x2598: quads(tl: true)
            case 0x2599: quads(tl: true, bl: true, br: true)
            case 0x259A: quads(tl: true, br: true)
            case 0x259B: quads(tl: true, tr: true, bl: true)
            case 0x259C: quads(tl: true, tr: true, br: true)
            case 0x259D: quads(tr: true)
            case 0x259E: quads(tr: true, bl: true)
            case 0x259F: quads(tr: true, bl: true, br: true)
            default: break
            }
        }

        // -------------------------------------------------------- powerline

        func powerline(_ cp: UInt32) {
            let fw = CGFloat(w), fh = CGFloat(h)
            let t = CGFloat(light)
            switch cp {
            case 0xE0B0: fillPath([CGPoint(x: 0, y: 0), CGPoint(x: fw, y: fh / 2), CGPoint(x: 0, y: fh)])
            case 0xE0B2: fillPath([CGPoint(x: fw, y: 0), CGPoint(x: 0, y: fh / 2), CGPoint(x: fw, y: fh)])
            case 0xE0B1:
                stroke({ p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: fw - t / 2, y: fh / 2))
                    p.addLine(to: CGPoint(x: 0, y: fh))
                }, width: t)
            case 0xE0B3:
                stroke({ p in
                    p.move(to: CGPoint(x: fw, y: 0))
                    p.addLine(to: CGPoint(x: t / 2, y: fh / 2))
                    p.addLine(to: CGPoint(x: fw, y: fh))
                }, width: t)
            case 0xE0B4:
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: -fw, y: 0, width: 2 * fw, height: fh))
            case 0xE0B6:
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 2 * fw, height: fh))
            case 0xE0B5:
                stroke({ $0.addEllipse(in: CGRect(x: -fw, y: t / 2, width: 2 * fw - t / 2, height: fh - t)) }, width: t)
            case 0xE0B7:
                stroke({ $0.addEllipse(in: CGRect(x: t / 2, y: t / 2, width: 2 * fw, height: fh - t)) }, width: t)
            case 0xE0B8: fillPath([CGPoint(x: 0, y: 0), CGPoint(x: fw, y: fh), CGPoint(x: 0, y: fh)])
            case 0xE0BA: fillPath([CGPoint(x: fw, y: 0), CGPoint(x: fw, y: fh), CGPoint(x: 0, y: fh)])
            case 0xE0BC: fillPath([CGPoint(x: 0, y: 0), CGPoint(x: fw, y: 0), CGPoint(x: 0, y: fh)])
            case 0xE0BE: fillPath([CGPoint(x: 0, y: 0), CGPoint(x: fw, y: 0), CGPoint(x: fw, y: fh)])
            case 0xE0B9, 0xE0BF: diagonal(rising: false)
            case 0xE0BB, 0xE0BD: diagonal(rising: true)
            default: break
            }
        }
    }
}
