// swiftc -O quality.swift -o quality && ./quality models/MIGAN_512.mlpackage out
import CoreML
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Foundation

let path = CommandLine.arguments[1], outDir = CommandLine.arguments[2]
let res = path.hasSuffix("256.mlpackage") ? 256 : 512
let tag = "\(res)"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let cs = CGColorSpaceCreateDeviceRGB()
func ctx() -> CGContext { CGContext(data: nil, width: res, height: res, bitsPerComponent: 8, bytesPerRow: res * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)! }
func save(_ c: CGContext, _ name: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name)_\(tag).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
}
func drawText(_ c: CGContext, _ color: CGColor) {
    let f = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(res) / 7, nil)
    for (i, s) in ["Hello World", "Translate me"].enumerated() {
        let a = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        c.textPosition = CGPoint(x: CGFloat(res) * 0.08, y: CGFloat(res) * (0.62 - 0.28 * CGFloat(i)))
        CTLineDraw(CTLineCreateWithAttributedString(a), c)
    }
}
// clean background: diagonal gradient + soft texture
let bg = ctx(); let bp = bg.data!.bindMemory(to: UInt8.self, capacity: res * res * 4)
for y in 0..<res { for x in 0..<res {
    let u = Double(x) / Double(res), v = Double(y) / Double(res), o = (y * res + x) * 4
    let tex = 10 * sin(u * 40) * cos(v * 33)
    bp[o] = UInt8(max(0, min(255, 60 + 150 * u + tex))); bp[o+1] = UInt8(max(0, min(255, 110 + 90 * v + tex))); bp[o+2] = UInt8(max(0, min(255, 200 - 100 * u * v + tex))); bp[o+3] = 255
} }
let clean = [UInt8](UnsafeBufferPointer(start: bp, count: res * res * 4))
let img = ctx(); img.draw(bg.makeImage()!, in: CGRect(x: 0, y: 0, width: res, height: res))
drawText(img, CGColor(red: 0, green: 0, blue: 0, alpha: 1))
let ip = img.data!.bindMemory(to: UInt8.self, capacity: res * res * 4)
// mask from text strokes (white on black), then dilate r=3 (1 = hole here; flipped for the model later)
let mc = ctx(); mc.setFillColor(CGColor(gray: 0, alpha: 1)); mc.fill(CGRect(x: 0, y: 0, width: res, height: res))
drawText(mc, CGColor(gray: 1, alpha: 1))
let mp = mc.data!.bindMemory(to: UInt8.self, capacity: res * res * 4)
var hole = [Bool](repeating: false, count: res * res)
let r = max(3, res / 170)
for y in 0..<res { for x in 0..<res where mp[(y * res + x) * 4] > 127 {
    for dy in -r...r { for dx in -r...r { let yy = y + dy, xx = x + dx; if yy >= 0, yy < res, xx >= 0, xx < res { hole[yy * res + xx] = true } } }
} }
let nh = hole.filter { $0 }.count
// model input: [mask-0.5 (1=known), img*mask] with img in [-1,1]
let x = try MLMultiArray(shape: [1, 4, NSNumber(value: res), NSNumber(value: res)], dataType: .float32)
let p = x.dataPointer.bindMemory(to: Float.self, capacity: 4 * res * res); let hw = res * res
for i in 0..<hw { let m: Float = hole[i] ? 0 : 1; p[i] = m - 0.5
    for c in 0..<3 { p[(1 + c) * hw + i] = (Float(ip[i * 4 + c]) / 127.5 - 1) * m } }
let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: try MLModel.compileModel(at: URL(fileURLWithPath: path)), configuration: cfg)
let o = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: x)])).featureValue(for: "output")!.multiArrayValue!
func outPx(_ c: Int, _ i: Int) -> Float { max(0, min(255, o[c * hw + i].floatValue * 127.5 + 127.5)) } // clamp to [-1,1]
// naive baseline: mean colour of non-hole pixels in a 12px border ring around the whole patch
var mean = [Double](repeating: 0, count: 3); var n = 0.0
for y in 0..<res { for xx in 0..<res where (y < 12 || y >= res - 12 || xx < 12 || xx >= res - 12) && !hole[y * res + xx] {
    for c in 0..<3 { mean[c] += Double(ip[(y * res + xx) * 4 + c]) }; n += 1 } }
mean = mean.map { $0 / n }
var dModel = 0.0, dNaive = 0.0, dInMaskVsInput = 0.0, dOutside = 0.0, dOutsideComp = 0.0, nOut = 0.0
let aft = ctx(); let ap = aft.data!.bindMemory(to: UInt8.self, capacity: res * res * 4)
let nai = ctx(); let np = nai.data!.bindMemory(to: UInt8.self, capacity: res * res * 4)
for i in 0..<hw { for c in 0..<3 {
    let cl = Double(clean[i * 4 + c]), inp = Double(ip[i * 4 + c]), mo = Double(outPx(c, i))
    if hole[i] { dModel += abs(mo - cl); dNaive += abs(mean[c] - cl); dInMaskVsInput += abs(mo - inp) }
    else { dOutside += abs(mo - inp); nOut += 1 }
    ap[i * 4 + c] = hole[i] ? UInt8(mo.rounded()) : ip[i * 4 + c]   // composite: model only fills hole
    np[i * 4 + c] = hole[i] ? UInt8(mean[c].rounded()) : ip[i * 4 + c]
    ap[i * 4 + 3] = 255; np[i * 4 + 3] = 255
} }
let nm = Double(nh * 3)
// mask png for output (white = hole)
let mo = ctx(); let mop = mo.data!.bindMemory(to: UInt8.self, capacity: res * res * 4)
for i in 0..<hw { let v: UInt8 = hole[i] ? 255 : 0; mop[i*4] = v; mop[i*4+1] = v; mop[i*4+2] = v; mop[i*4+3] = 255 }
save(img, "before"); save(mo, "mask"); save(aft, "after"); save(nai, "naive"); save(bg, "clean")
print("res \(res): hole px \(nh) (\(String(format: "%.1f", 100 * Double(nh) / Double(hw)))% of patch), dilation r=\(r)")
print(String(format: "inside mask  MAE vs clean bg (0-255): model %.2f | naive mean-border-colour %.2f", dModel / nm, dNaive / nm))
print(String(format: "inside mask  MAE output vs text-input (changed?): %.2f", dInMaskVsInput / nm))
print(String(format: "outside mask MAE raw model output vs input (0-255): %.2f ; composite outside diff: 0 by construction", dOutside / nOut))
