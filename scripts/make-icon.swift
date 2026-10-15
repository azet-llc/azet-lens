// Renders the app icon and writes App/Assets.xcassets/AppIcon.appiconset.
//   swift scripts/make-icon.swift
import AppKit
import CoreText

let S: CGFloat = 1024
func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) in CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

    // macOS icon grid: 824 pt body, centred, continuous corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.28))
    ctx.addPath(shape); ctx.setFillColor(rgb(240, 80, 90, 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let warm = CGGradient(colorsSpace: nil, colors: [rgb(255, 160, 72, 1), rgb(246, 96, 92, 1), rgb(226, 58, 120, 1)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 160, y: 940), end: CGPoint(x: 880, y: 90), options: [])
    // Soft light from the top-left.
    let glow = CGGradient(colorsSpace: nil, colors: [rgb(255, 240, 210, 0.55), rgb(255, 240, 210, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 860), startRadius: 0, endCenter: CGPoint(x: 300, y: 860), endRadius: 560, options: [])
    ctx.restoreGState()

    // Speech bubble with a tail, lower-left.
    let bubble = CGMutablePath()
    let b = CGRect(x: 190, y: 330, width: 644, height: 420)
    bubble.addPath(CGPath(roundedRect: b, cornerWidth: 150, cornerHeight: 150, transform: nil))
    bubble.move(to: CGPoint(x: 300, y: 360))
    bubble.addQuadCurve(to: CGPoint(x: 236, y: 226), control: CGPoint(x: 300, y: 270))
    bubble.addQuadCurve(to: CGPoint(x: 430, y: 340), control: CGPoint(x: 360, y: 250))
    bubble.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(120, 20, 50, 0.35))
    ctx.addPath(bubble); ctx.setFillColor(rgb(255, 255, 255, 1)); ctx.fillPath()
    ctx.restoreGState()

    // "뭐여?" in the bubble.
    let font = CTFontCreateWithName("AppleSDGothicNeo-Heavy" as CFString, 236, nil)
    let ink = CGGradient(colorsSpace: nil, colors: [rgb(250, 110, 70, 1), rgb(220, 50, 110, 1)] as CFArray, locations: [0, 1])!
    let attr = NSAttributedString(string: "뭐여?", attributes: [.font: font, .kern: -6])
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let origin = CGPoint(x: b.midX - bounds.width / 2 - bounds.minX, y: b.midY - bounds.height / 2 - bounds.minY + 6)
    // Glyph outlines as a clip so the text takes the gradient.
    let glyphs = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var gs = [CGGlyph](repeating: 0, count: n), ps = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &gs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &ps)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<n {
            if let p = CTFontCreatePathForGlyph(runFont, gs[i], nil) {
                glyphs.addPath(p, transform: CGAffineTransform(translationX: origin.x + ps[i].x, y: origin.y + ps[i].y))
            }
        }
    }
    ctx.saveGState()
    ctx.addPath(glyphs); ctx.clip()
    ctx.drawLinearGradient(ink, start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

let dir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let master = render()
var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))
try #"{"info":{"version":1,"author":"xcode"}}"#.write(to: dir.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(dir.path)")
