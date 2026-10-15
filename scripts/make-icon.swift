// Renders the app icon and writes App/Assets.xcassets/AppIcon.appiconset.
//   swift scripts/make-icon.swift
import AppKit

let S: CGFloat = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func canvas() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let spectrum = [rgb(255, 158, 10), rgb(255, 56, 94), rgb(191, 90, 242), rgb(94, 92, 230), rgb(100, 210, 255), rgb(255, 158, 10)]

// The lens: a rounded rectangle on the icon grid.
let lens = CGRect(x: 236, y: 300, width: 552, height: 424)
let lensPath = CGPath(roundedRect: lens, cornerWidth: 86, cornerHeight: 86, transform: nil)

/// Strokes the lens with the spectrum swept around its centre (a conic gradient, in thin wedges).
func strokeSpectrum(_ ctx: CGContext, width: CGFloat) {
    ctx.saveGState()
    ctx.addPath(lensPath); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
    let c = CGPoint(x: lens.midX, y: lens.midY), n = 720
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n)
        let seg = t * CGFloat(spectrum.count - 1), k = min(Int(seg), spectrum.count - 2), f = seg - CGFloat(k)
        let a = spectrum[k].components!, b = spectrum[k + 1].components!
        ctx.setFillColor(CGColor(srgbRed: a[0] + (b[0] - a[0]) * f, green: a[1] + (b[1] - a[1]) * f, blue: a[2] + (b[2] - a[2]) * f, alpha: 1))
        let a0 = t * 2 * .pi + .pi / 4, a1 = a0 + 2 * .pi / CGFloat(n) + 0.003
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x + 900 * cos(a0), y: c.y + 900 * sin(a0)))
        ctx.addLine(to: CGPoint(x: c.x + 900 * cos(a1), y: c.y + 900 * sin(a1)))
        ctx.closePath(); ctx.fillPath()
    }
    ctx.restoreGState()
}

func render() -> CGImage {
    let ctx = canvas()
    // macOS icon grid: 824 pt body, centred, continuous corners. Deep graphite, lit from the top.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(24, 25, 30)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let base = CGGradient(colorsSpace: sRGB, colors: [rgb(50, 52, 62), rgb(24, 25, 30), rgb(14, 14, 18)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Text lines run under the lens: dim outside (the original), bright inside (read, in your language).
    let lines: [(y: CGFloat, x0: CGFloat, x1: CGFloat)] = [(832, 196, 700), (600, 168, 856), (512, 168, 790), (424, 168, 870),
                                                           (192, 196, 760)]
    let inside: [(y: CGFloat, x0: CGFloat, x1: CGFloat)] = [(600, 300, 724), (512, 300, 690), (424, 300, 560)]
    func drawLines(_ color: CGColor, _ set: [(y: CGFloat, x0: CGFloat, x1: CGFloat)] = lines) {
        ctx.setFillColor(color)
        for l in set {
            ctx.addPath(CGPath(roundedRect: CGRect(x: l.x0, y: l.y - 17, width: l.x1 - l.x0, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
        }
        ctx.fillPath()
    }
    drawLines(rgb(255, 255, 255, 0.12))

    // Glow: the ring, wide and blurred.
    let ring = canvas()
    strokeSpectrum(ring, width: 44)
    let blurred = CIImage(cgImage: ring.makeImage()!).applyingGaussianBlur(sigma: 30).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
    let glow = CIContext().createCGImage(blurred, from: CGRect(x: 0, y: 0, width: S, height: S))!
    ctx.setAlpha(0.8)
    ctx.draw(glow, in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.setAlpha(1)

    ctx.saveGState()
    ctx.addPath(lensPath); ctx.clip()
    ctx.setFillColor(rgb(15, 15, 19, 0.92)); ctx.fill(lens)
    drawLines(rgb(255, 255, 255, 0.96), inside)
    ctx.restoreGState()
    ctx.restoreGState()
    strokeSpectrum(ctx, width: 20)
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
