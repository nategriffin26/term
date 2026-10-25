import CoreText
import Foundation

/// Pixel metrics of one terminal cell; every value is a whole number of
/// device pixels so glyphs, lines and box drawing land on the pixel grid.
struct CellMetrics: Equatable {
    var width: Int
    var height: Int
    var baseline: Int           // from the cell top
    var underlineY: Int         // top of the underline stroke
    var strikeY: Int            // top of the strikethrough stroke
    var stroke: Int             // underline/strike/box-light thickness
}

/// The four faces of a bundled Nerd Font (or any installed family) at one pixel size.
@MainActor
final class FontSet {
    /// Families whose four TTFs ship in app/Resources/Fonts as `<fileStem>-<Style>.ttf`.
    struct Bundled {
        let family: String
        let fileStem: String
    }

    static let bundled = [
        Bundled(family: "JetBrainsMono Nerd Font Mono", fileStem: "JetBrainsMonoNerdFontMono"),
        Bundled(family: "Iosevka Nerd Font Mono", fileStem: "IosevkaNerdFontMono"),
    ]
    static let family = bundled[0].family
    static let defaultPointSize: CGFloat = 10
    static let pointSizeRange: ClosedRange<CGFloat> = 6...36

    let family: String
    let pointSize: CGFloat
    let scale: CGFloat
    let metrics: CellMetrics
    /// Indexed by style: bit 0 bold, bit 1 italic.
    let faces: [CTFont]

    /// `family` is a bundled Nerd Font or any installed font family;
    /// its bold/italic faces come from the family's own traits.
    init(family: String = FontSet.family, pointSize: CGFloat, scale: CGFloat) {
        self.family = family
        self.pointSize = pointSize
        self.scale = scale
        let px = pointSize * scale
        if let bundled = FontSet.bundled.first(where: { $0.family == family }) {
            let descriptors = FontSet.descriptors[bundled.fileStem] ?? [:]
            faces = ["Regular", "Bold", "Italic", "BoldItalic"].map { style in
                guard let d = descriptors[style] else {
                    preconditionFailure("\(bundled.fileStem)-\(style).ttf is not in the app bundle (app/Resources/Fonts)")
                }
                return CTFontCreateWithFontDescriptor(d, px, nil)
            }
        } else {
            let base = CTFontCreateWithFontDescriptor(
                CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary), px, nil)
            let traits: [CTFontSymbolicTraits] = [[], .traitBold, .traitItalic, [.traitBold, .traitItalic]]
            faces = traits.map { t in
                t.isEmpty ? base : CTFontCreateCopyWithSymbolicTraits(base, px, nil, t, t) ?? base
            }
        }
        metrics = FontSet.measure(faces[0])
    }

    func face(_ style: Int) -> CTFont { faces[style & 3] }

    private static func measure(_ font: CTFont) -> CellMetrics {
        var ch: UniChar = 0x4D  // "M"
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let width = max(1, Int(advance.width.rounded()))
        let height = max(1, Int((ascent + descent + leading).rounded()))
        let baseline = Int((ascent + (CGFloat(height) - ascent - descent) / 2).rounded())
        let stroke = max(1, Int(CTFontGetUnderlineThickness(font).rounded()))
        var underlineY = baseline + Int((-CTFontGetUnderlinePosition(font)).rounded()) - stroke / 2
        underlineY = min(max(underlineY, baseline + 1), height - stroke)
        let strikeY = baseline - Int((CTFontGetXHeight(font) / 2).rounded()) - stroke / 2
        return CellMetrics(width: width, height: height, baseline: baseline,
                           underlineY: underlineY, strikeY: max(0, strikeY), stroke: stroke)
    }

    // ------------------------------------------------------------ bundle

    /// Descriptors of the bundled faces: file stem -> style ("Regular", "Bold", …) -> descriptor.
    private static let descriptors: [String: [String: CTFontDescriptor]] = {
        var out: [String: [String: CTFontDescriptor]] = [:]
        for bundled in bundled {
            for url in fontURLs(stem: bundled.fileStem) {
                let name = url.deletingPathExtension().lastPathComponent
                guard let style = name.split(separator: "-").last,
                      let ds = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                      let d = ds.first else { continue }
                out[bundled.fileStem, default: [:]][String(style)] = d
            }
        }
        return out
    }()

    private static func fontURLs(stem: String) -> [URL] {
        let bundle = Bundle(for: FontSet.self)
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        return urls.filter { $0.lastPathComponent.hasPrefix(stem + "-") }
    }

    /// Registers the bundled faces process-wide so UIKit can name them
    /// (`UIFont(name: "JetBrainsMonoNFM-Regular", size:)`, family "Iosevka Nerd
    /// Font Mono"). The renderer does not need this; it loads the files directly.
    static func registerFonts() {
        _ = registered
    }

    private static let registered: Void = {
        let urls = bundled.flatMap { fontURLs(stem: $0.fileStem) }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
    }()
}
