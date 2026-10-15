import AppKit
import ImageIO
import MwoyeaCore
import UniformTypeIdentifiers

/// Headless end-to-end run on a still image:
///   Mwoyea --render in.png out.png [--src ja] [--tgt ko] [--mode fast|seamless] [--engine auto|translation|intelligence]
///                                  [--no-inpaint] [--scale 2]
/// Prints what was read and translated, and writes the composited result. Exits when done.
///
/// Simulated lens drag over a still "screen" (points; writes the lens view per step as outdir/frame_NNN.png):
///   Mwoyea --render screen.png outdir --pan --lens x,y,w,h --to x,y [--steps 40] [--step-ms 100] [--hold-ms 3000]
enum SelfTest {
    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do {
                try await render(args)
                exit(0)
            } catch {
                FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: OverlaySnapshot?
        var latest: OverlaySnapshot? { lock.withLock { snapshot } }
        func put(_ s: OverlaySnapshot) { lock.withLock { snapshot = s } }
    }

    private static func render(_ args: [String]) async throws {
        guard args.count >= 2 else { throw Failure(description: "usage: --render in.png out.png [options]") }
        func option(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let rgba = RGBAImage(cgImage: decoded), let image = rgba.cgImage
        else { throw Failure(description: "cannot read \(input.path)") }

        var settings = AppSettings()
        settings.sourceLanguage = option("--src") ?? "auto"
        settings.targetLanguage = option("--tgt") ?? "ko"
        settings.renderMode = option("--mode") == "fast" ? .fast : .seamless
        settings.engine = TranslationEngineChoice(rawValue: option("--engine") ?? "auto") ?? .auto
        settings.useInpaintingModel = !args.contains("--no-inpaint")
        let scale = CGFloat(Double(option("--scale") ?? "2") ?? 2)

        let translator = TranslationService(settings: settings)
        await translator.setIssueHandler { issue in
            if let issue { FileHandle.standardError.write("issue: \(issue.message)\n".data(using: .utf8)!) }
        }
        let t0 = Date()
        let inpainter = settings.useInpaintingModel ? Inpainter.load() : nil
        print("inpainter: \(inpainter != nil ? "MI-GAN loaded (\(ms(t0)) ms)" : "none")")
        if args.contains("--pan") {
            if option("--mode") == nil { settings.renderMode = .adaptive }
            try await pan(screen: image, scale: scale, settings: settings, translator: translator, inpainter: inpainter,
                          outdir: output, option: option)
            return
        }

        let collector = Collector()
        let capture = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pipeline = RegionPipeline(options: PipelineOptions(settings), capture: capture, translator: translator, inpainter: inpainter,
                                      onSnapshot: { collector.put($0) })
        let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
        let start = Date()
        await pipeline.ingest(CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: capture, time: ProcessInfo.processInfo.systemUptime))

        // Wait for reading + translation to finish (or give up after 120 s).
        var lastChange = Date(), lastVersion = -1
        while Date().timeIntervalSince(start) < 120 {
            try await Task.sleep(for: .milliseconds(200))
            let state = await pipeline.debugState()
            if let v = collector.latest?.version, v != lastVersion { lastVersion = v; lastChange = Date() }
            if !state.busy, Date().timeIntervalSince(lastChange) > 0.6 { break }
        }
        print("pipeline: \(ms(start)) ms")
        for (source, translation) in await pipeline.debugState().blocks {
            print("  \(source)\n    → \(translation ?? "(no translation)")")
        }

        // Composite: original + overlay blocks (frames are in points; multiply by scale).
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "context") }
        let h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for b in collector.latest?.blocks ?? [] {
            let r = CGRect(x: b.frame.minX * scale, y: h - b.frame.maxY * scale, width: b.frame.width * scale, height: b.frame.height * scale)
            ctx.draw(b.image, in: r)
        }
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(description: "cannot write \(output.path)") }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(description: "cannot write \(output.path)") }
        print("wrote \(output.path)")
    }

    private static func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    /// Drives the pipeline the way `RegionSession` does while a lens is dragged, with frames cropped from `screen`.
    private static func pan(screen: CGImage, scale: CGFloat, settings: AppSettings, translator: TranslationService, inpainter: Inpainter?,
                            outdir: URL, option: (String) -> String?) async throws {
        func numbers(_ name: String) -> [CGFloat] {
            (option(name) ?? "").split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        }
        let l = numbers("--lens"), to = numbers("--to")
        guard l.count == 4, to.count == 2 else { throw Failure(description: "--pan needs --lens x,y,w,h and --to x,y") }
        let steps = Int(option("--steps") ?? "40") ?? 40
        let stepMs = Int(option("--step-ms") ?? "100") ?? 100
        let holdMs = Int(option("--hold-ms") ?? "3000") ?? 3000
        let display = CGRect(x: 0, y: 0, width: CGFloat(screen.width) / scale, height: CGFloat(screen.height) / scale)
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)

        var lens = CGRect(x: l[0], y: l[1], width: l[2], height: l[3])
        var wide = false
        var capture = Overscan.rect(around: lens, wide: wide, display: display)
        let collector = Collector()
        let pipeline = RegionPipeline(options: PipelineOptions(settings), capture: capture, translator: translator, inpainter: inpainter,
                                      onSnapshot: { collector.put($0) })
        await pipeline.setVisible(lens)

        func feed() async {
            let px = CGRect(x: capture.minX * scale, y: capture.minY * scale, width: capture.width * scale, height: capture.height * scale)
            guard let crop = screen.cropping(to: px), let rgba = RGBAImage(cgImage: crop), let image = rgba.cgImage else { return }
            let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
            await pipeline.ingest(CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: capture,
                                                time: ProcessInfo.processInfo.systemUptime))
        }
        func apply(_ plan: Overscan.Plan) async {
            switch plan {
            case .keep: return
            case .move(let r): capture = r; await pipeline.captureMoved(to: r.origin)
            case .resize(let r): capture = r; await pipeline.captureResized(to: r)
            }
            await feed()
        }
        var frameIndex = 0
        func shoot() throws {
            let w = Int(lens.width * scale), h = Int(lens.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let under = screen.cropping(to: CGRect(x: lens.minX * scale, y: lens.minY * scale, width: CGFloat(w), height: CGFloat(h)))
            else { throw Failure(description: "context") }
            ctx.draw(under, in: CGRect(x: 0, y: 0, width: w, height: h))
            var shown = 0
            if let snap = collector.latest {
                for b in snap.blocks {
                    // Snapshot frames are relative to the capture origin; the lens is the overlay panel.
                    let g = b.frame.offsetBy(dx: snap.origin.x - lens.minX, dy: snap.origin.y - lens.minY)
                    guard g.intersects(CGRect(origin: .zero, size: lens.size)) else { continue }
                    shown += 1
                    ctx.draw(b.image, in: CGRect(x: g.minX * scale, y: CGFloat(h) - g.maxY * scale, width: g.width * scale, height: g.height * scale))
                }
            }
            guard let out = ctx.makeImage() else { return }
            let url = outdir.appendingPathComponent(String(format: "frame_%03d.png", frameIndex))
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, out, nil)
                CGImageDestinationFinalize(dest)
            }
            frameIndex += 1
            print(String(format: "frame %03d lens (%4.0f,%4.0f) capture (%4.0f,%4.0f %4.0f×%4.0f) blocks shown %d",
                         frameIndex - 1, lens.minX, lens.minY, capture.minX, capture.minY, capture.width, capture.height, shown))
        }

        // At rest: read and translate the start position completely.
        let start = Date()
        await feed()
        var quiet = Date()
        while Date().timeIntervalSince(start) < 120 {
            try await Task.sleep(for: .milliseconds(200))
            if (await pipeline.debugState()).busy { quiet = Date() } else if Date().timeIntervalSince(quiet) > 0.6 { break }
        }
        print("settled at start: \(ms(start)) ms")
        try shoot()

        // Drag: margins widen at once (as `noteMotion` does), then the lens moves in steps.
        wide = true
        await apply(Overscan.plan(lens: lens, capture: capture, wide: wide, allowResize: true, display: display))
        let from = lens.origin
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            lens.origin = CGPoint(x: from.x + (to[0] - from.x) * f, y: from.y + (to[1] - from.y) * f)
            await pipeline.setVisible(lens)
            await apply(Overscan.plan(lens: lens, capture: capture, wide: wide, allowResize: false, display: display))
            try await Task.sleep(for: .milliseconds(stepMs))
            try shoot()
        }
        // Dropped: keep watching while it settles into seamless.
        for _ in 0 ..< max(1, holdMs / 250) {
            try await Task.sleep(for: .milliseconds(250))
            try shoot()
        }
        for (source, translation) in await pipeline.debugState().blocks {
            print("  \(source) → \(translation ?? "(no translation)")")
        }
    }
}

private extension RGBAImage {
    /// Temporarily exposes the pixels as BGRA (the capture format) for the gray downsampler.
    func withBGRA<T>(_ body: (UnsafeRawPointer) -> T) -> T {
        var bgra = pixels
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        return bgra.withUnsafeBytes { body($0.baseAddress!) }
    }
}
