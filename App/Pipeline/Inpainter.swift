import CoreML
import Foundation
import MwoyeoCore

/// MI-GAN (Core ML) inpainting for text on textured backgrounds.
///
/// Model contract (tools/inpaint/BENCH.md): input `input` float32 [1, 4, S, S] = [mask - 0.5, R, G, B] with
/// RGB in [-1, 1] and zeroed inside the hole, mask 1 = keep / 0 = hole. Output `output` float32 [1, 3, S, S]
/// RGB ≈ [-1, 1] (clamp), a full-frame reconstruction that must be composited back over the known pixels.
final class Inpainter: @unchecked Sendable {
    let side: Int
    private let model: MLModel
    private let lock = NSLock()

    /// Looks for the compiled model in the app bundle, then in Application Support.
    static func load() -> Inpainter? {
        let name = "MIGAN_512"
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { candidates.append(u) }
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            candidates.append(support.appendingPathComponent("AZET Lens/Models/\(name).mlmodelc"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU // measured fastest at 512 on M-series; `.all` was 4× slower
            if let m = try? MLModel(contentsOf: url, configuration: config) {
                return Inpainter(model: m, side: 512)
            }
        }
        return nil
    }

    private init(model: MLModel, side: Int) {
        self.model = model
        self.side = side
    }

    /// Fills `mask` (1 = erase, sized like `rect`) inside `rect` of `frame`, using the frame around it as context.
    /// Returns the repaired `rect` patch. Large rects are processed in overlapping model-sized tiles.
    func inpaint(frame: RGBAImage, rect: PixelRect, mask: [UInt8]) throws -> RGBAImage {
        var patch = frame.cropped(to: rect)
        let s = side
        // Tile the rect with S×S windows centred on it; each window takes real frame pixels as context.
        let step = s * 3 / 4
        var ty = 0
        repeat {
            var tx = 0
            repeat {
                let tileW = min(step, rect.width - tx), tileH = min(step, rect.height - ty)
                let cx = rect.x + tx + tileW / 2, cy = rect.y + ty + tileH / 2
                let win = PixelRect(x: min(max(0, cx - s / 2), max(0, frame.width - s)),
                                    y: min(max(0, cy - s / 2), max(0, frame.height - s)), width: s, height: s)
                try run(window: win, frame: frame, rect: rect, mask: mask, into: &patch,
                        only: PixelRect(x: rect.x + tx, y: rect.y + ty, width: tileW, height: tileH))
                tx += step
            } while tx < rect.width
            ty += step
        } while ty < rect.height
        return patch
    }

    /// Runs the model on one S×S window of the frame (padded with edge pixels if the frame is smaller)
    /// and writes reconstructed hole pixels that fall inside `only` into `patch`.
    private func run(window: PixelRect, frame: RGBAImage, rect: PixelRect, mask: [UInt8], into patch: inout RGBAImage,
                     only: PixelRect) throws {
        let s = side
        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: s), NSNumber(value: s)], dataType: .float32)
        let plane = s * s
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: 4 * plane)

        @inline(__always) func isHole(_ fx: Int, _ fy: Int) -> Bool {
            let mx = fx - rect.x, my = fy - rect.y
            guard mx >= 0, my >= 0, mx < rect.width, my < rect.height else { return false }
            return mask[my * rect.width + mx] != 0
        }

        for y in 0..<s {
            let fy = min(max(window.y + y, 0), frame.height - 1)
            for x in 0..<s {
                let fx = min(max(window.x + x, 0), frame.width - 1)
                let i = y * s + x
                let hole = isHole(fx, fy)
                ptr[i] = hole ? -0.5 : 0.5
                if hole {
                    ptr[plane + i] = 0; ptr[2 * plane + i] = 0; ptr[3 * plane + i] = 0
                } else {
                    let c = frame.color(x: fx, y: fy)
                    ptr[plane + i] = Float(c.r) / 127.5 - 1
                    ptr[2 * plane + i] = Float(c.g) / 127.5 - 1
                    ptr[3 * plane + i] = Float(c.b) / 127.5 - 1
                }
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
        let result: MLFeatureProvider = try lock.withLock { try model.prediction(from: provider) }
        guard let out = result.featureValue(for: "output")?.multiArrayValue else { return }
        let o = out.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        // Output may be fp16 or fp32 depending on the compute unit; read through strides only for fp32.
        let isFloat32 = out.dataType == .float32

        @inline(__always) func value(_ c: Int, _ i: Int) -> UInt8 {
            let v: Float = isFloat32 ? o[c * plane + i] : out[[0, NSNumber(value: c), NSNumber(value: i / s), NSNumber(value: i % s)]].floatValue
            return UInt8(clamping: Int((min(max(v, -1), 1) * 127.5 + 127.5).rounded()))
        }

        for py in only.y..<(only.y + only.height) {
            for px in only.x..<(only.x + only.width) where isHole(px, py) {
                let wx = px - window.x, wy = py - window.y
                guard wx >= 0, wy >= 0, wx < s, wy < s else { continue }
                let i = wy * s + wx
                patch.set(x: px - rect.x, y: py - rect.y, RGBA(value(0, i), value(1, i), value(2, i)))
            }
        }
    }
}
