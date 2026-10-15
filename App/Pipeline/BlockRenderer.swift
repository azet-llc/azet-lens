import AppKit
import CoreText
import MwoyeaCore

/// Draws a translated block into an image the size of the block (device pixels).
enum BlockRenderer {
    enum Background {
        /// Original pixels with the source text erased.
        case erased(RGBAImage)
        /// A rounded box in the background colour (fast mode).
        case box(RGBA, opacity: Double)
    }

    struct Input {
        var size: CGSize            // pixels
        var text: String
        var background: Background
        var appearance: TextAppearance
        /// Height of one original text line in pixels — the starting point for the font size.
        var lineHeight: CGFloat
        var originalLineCount: Int
        var fontStyle: FontStyleChoice
        var targetLanguage: String
        var scale: CGFloat
    }

    static func render(_ input: Input) -> CGImage? {
        let w = Int(input.size.width.rounded(.up)), h = Int(input.size.height.rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)

        switch input.background {
        case let .erased(img):
            if let cg = img.cgImage { ctx.draw(cg, in: bounds) }
        case let .box(color, opacity):
            let radius = min(CGFloat(h) * 0.22, 6 * input.scale)
            ctx.setFillColor(color.cgColor.copy(alpha: opacity) ?? color.cgColor)
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        let padX = max(1, input.lineHeight * 0.08), padY = max(0, input.lineHeight * 0.02)
        let box = bounds.insetBy(dx: padX, dy: padY)
        let textColor = legibleTextColor(input.appearance)
        let weight = fontWeight(coverage: input.appearance.coverage)

        // Glyphs fill ~75% of a recognized line box; start there and shrink to fit.
        let maxSize = max(6 * input.scale, input.lineHeight * 0.78)
        let minSize = min(maxSize, max(7 * input.scale, input.lineHeight * 0.45))
        let size = TextFitter.fitFontSize(in: box.size, minSize: minSize, maxSize: maxSize) { s in
            TextFitter.measure(attributed(input.text, size: s, weight: weight, style: input.fontStyle, color: textColor,
                                          language: input.targetLanguage), width: box.width)
        }
        let string = attributed(input.text, size: size, weight: weight, style: input.fontStyle, color: textColor,
                                language: input.targetLanguage)
        let measured = TextFitter.measure(string, width: box.width)

        // Vertically centre; CoreText draws in a y-up space, which matches CGContext's default.
        let textRect = CGRect(x: box.minX, y: box.midY - measured.height / 2, width: box.width, height: measured.height)
        if !input.appearance.isFlatBackground, case .erased = input.background {
            // Busy background: a soft halo in the background colour keeps text readable.
            ctx.setShadow(offset: .zero, blur: size * 0.25, color: input.appearance.backgroundColor.cgColor)
        }
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: textRect.insetBy(dx: 0, dy: -2), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    private static func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight, style: FontStyleChoice,
                                   color: CGColor, language: String) -> NSAttributedString {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        switch style {
        case .system: break
        case .rounded:
            if let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
        case .serif:
            if let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
            // Korean has no serif system design; prefer a Myeongjo face when installed.
            if language.hasPrefix("ko"), let f = NSFont(name: "AppleMyungjo", size: size) { font = f }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineBreakStrategy = .standard
        para.lineHeightMultiple = 0.95
        return NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: para,
            NSAttributedString.Key(kCTLanguageAttributeName as String): language,
        ])
    }

    /// Stroke density stands in for font weight: bold text covers more of its line box.
    private static func fontWeight(coverage: Double) -> NSFont.Weight {
        switch coverage {
        case ..<0.18: .regular
        case ..<0.28: .medium
        case ..<0.95: .semibold
        default: .regular // whole-box fallback mask, weight unknown
        }
    }

    /// The detected text colour, nudged away from the background if they ended up too close.
    private static func legibleTextColor(_ a: TextAppearance) -> CGColor {
        let fg = a.textColor, bg = a.backgroundColor
        if abs(fg.luma - bg.luma) >= 70 { return fg.cgColor }
        return bg.luma > 140 ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
    }
}
