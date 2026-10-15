import AppKit
import ImageIO
import MwoyeaCore
import UniformTypeIdentifiers

/// Headless end-to-end run on a still image:
///   Mwoyea --render in.png out.png [--src ja] [--tgt ko] [--mode fast|seamless] [--engine auto|translation|intelligence]
///                                  [--no-inpaint] [--scale 2]
/// Prints what was read and translated, and writes the composited result. Exits when done.
enum SelfTest {
    static func run(_ args: [String]) -> Never {
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

        let collector = Collector()
        let pipeline = RegionPipeline(options: PipelineOptions(settings), origin: .zero, translator: translator, inpainter: inpainter,
                                      onSnapshot: { collector.put($0) })
        let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
        let start = Date()
        await pipeline.ingest(CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, time: ProcessInfo.processInfo.systemUptime))

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
}

private extension RGBAImage {
    /// Temporarily exposes the pixels as BGRA (the capture format) for the gray downsampler.
    func withBGRA<T>(_ body: (UnsafeRawPointer) -> T) -> T {
        var bgra = pixels
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        return bgra.withUnsafeBytes { body($0.baseAddress!) }
    }
}
