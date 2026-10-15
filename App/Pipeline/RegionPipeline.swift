import CoreGraphics
import Foundation
import MwoyeaCore
import os

/// One captured frame of a region.
struct CapturedFrame: @unchecked Sendable {
    let image: CGImage
    /// Downsampled luma for change detection; one gray pixel covers `grayStep`×`grayStep` image pixels.
    let gray: GrayImage
    let grayStep: Int
    /// Image pixels per point.
    let scale: CGFloat
    /// `ProcessInfo.systemUptime` at capture.
    let time: TimeInterval
}

/// A translated block ready to show: region-local frame in points (top-left origin) and its rendered image.
struct OverlayBlock: Identifiable, @unchecked Sendable {
    let id: UUID
    var frame: CGRect
    var image: CGImage
    var seamless: Bool
}

struct OverlaySnapshot: @unchecked Sendable {
    let version: Int
    let blocks: [OverlayBlock]
    let animated: Bool
    /// Region origin (global Quartz points) the block frames are relative to. The overlay compensates
    /// if the region has moved since, so a late snapshot never makes text jump.
    let origin: CGPoint
}

enum RegionActivity: Sendable, Equatable {
    case idle, reading, translating
}

struct PipelineOptions: Sendable, Equatable {
    var renderMode: RenderMode
    var settleDelay: TimeInterval
    var useInpainting: Bool
    var fontStyle: FontStyleChoice
    var boxOpacity: Double
    var sourceLanguage: String
    var targetLanguage: String
    var glossaryTerms: [String]

    init(_ s: AppSettings) {
        renderMode = s.renderMode
        settleDelay = s.settleDelay
        useInpainting = s.useInpaintingModel
        fontStyle = s.fontStyle
        boxOpacity = s.boxOpacity
        sourceLanguage = s.sourceLanguage
        targetLanguage = s.targetLanguage
        glossaryTerms = s.glossaryPairs.map(\.0)
    }
}

/// Turns a stream of frames into overlay snapshots.
///
/// - While content moves: re-read only the changed band (tile diff), show translations on plain boxes
///   ("fast"), follow scrolls by shifting existing blocks instead of re-reading them.
/// - Once still for `settleDelay`: read paragraphs, erase the source text (flat fill or MI-GAN) and write the
///   translation in its place ("seamless"), crossfading from the fast boxes.
actor RegionPipeline {
    private struct Block {
        let id: UUID
        var rect: CGRect            // image pixels
        var lines: [CGRect]         // image pixels
        var source: String
        var translation: String?
        var appearance: TextAppearance
        /// Font size (pixels) estimated from the original glyphs.
        var fontSize: CGFloat?
        /// Free background to the right of the text, included in `rect`, that a longer translation may use.
        var spareWidth: CGFloat = 0
        var erased: RGBAImage?      // seamless background covering `rect`
        var image: CGImage?
    }

    private let translator: TranslationService
    private let inpainter: Inpainter?
    private let onSnapshot: @Sendable (OverlaySnapshot) -> Void
    private var onActivity: (@Sendable (RegionActivity) -> Void)?
    private let log = Logger(subsystem: "dev.midagedev.mwoyea", category: "pipeline")

    private var options: PipelineOptions
    private var latest: CapturedFrame?
    private var prevGray: GrayImage?
    /// Gray of the frame the current blocks describe (shifted along with scrolls).
    private var baseGray: GrayImage?
    private var forcedDirty: PixelRect?
    private var lastChange: TimeInterval = 0
    private var seamlessDone = false
    private var blocks: [Block] = []
    private var working = false
    private var settleTask: Task<Void, Never>?
    private var inFlight: Set<String> = []
    private var version = 0
    private var scale: CGFloat = 2
    private var activity = RegionActivity.idle
    /// Bumped whenever blocks are moved by a scroll; a pass that awaited across a bump discards its result.
    private var scrollEpoch = 0
    private var ignoreFramesUntil: TimeInterval = 0
    private var grayShiftX = ShiftAccumulator()
    private var grayShiftY = ShiftAccumulator()

    /// Region origin, global Quartz points.
    private var origin: CGPoint

    init(options: PipelineOptions, origin: CGPoint, translator: TranslationService, inpainter: Inpainter?,
         onSnapshot: @escaping @Sendable (OverlaySnapshot) -> Void) {
        self.origin = origin
        self.options = options
        self.translator = translator
        self.inpainter = inpainter
        self.onSnapshot = onSnapshot
    }

    func setActivityHandler(_ h: @escaping @Sendable (RegionActivity) -> Void) { onActivity = h }

    func update(options new: PipelineOptions) {
        guard new != options else { return }
        options = new
        reset()
    }

    /// Forget everything (region moved/resized, settings changed). The next frame is read from scratch.
    func reset() {
        settleTask?.cancel()
        blocks = []
        baseGray = nil
        prevGray = nil
        forcedDirty = nil
        seamlessDone = false
        inFlight = []
        emit(animated: false)
        if latest != nil { kick() }
    }

    /// Re-translate everything currently on screen (e.g. after the user downloads a language pack).
    func refresh() {
        for i in blocks.indices { blocks[i].translation = nil; blocks[i].image = nil }
        baseGray = nil
        seamlessDone = false
        kick()
    }

    /// For the headless self-test: whether work is pending, and what each block reads.
    func debugState() -> (busy: Bool, blocks: [(String, String?)]) {
        (working || !inFlight.isEmpty || settleTask != nil && !seamlessDone, blocks.map { ($0.source, $0.translation) })
    }

    func ingest(_ frame: CapturedFrame) {
        if let l = latest, frame.time < l.time { return }
        if frame.time < ignoreFramesUntil { return }
        scale = frame.scale
        if let prev = prevGray {
            let change = FrameDiff.changeMap(from: prev, to: frame.gray)
            if !change.isUnchanged {
                lastChange = frame.time
                seamlessDone = false
                if change.ratio > 0.2, !blocks.isEmpty,
                   let dy = FrameDiff.verticalShift(from: prev, to: frame.gray, maxShift: frame.gray.height / 3) {
                    followScroll(dyGray: dy, frame: frame)
                }
            }
        } else {
            lastChange = frame.time
        }
        prevGray = frame.gray
        latest = frame
        kick()
    }

    // MARK: - Scheduling

    private func kick() {
        guard !working else { return }
        working = true
        Task { await self.run() }
    }

    private func run() async {
        while let frame = latest {
            let now = ProcessInfo.processInfo.systemUptime
            let settled = now - lastChange >= options.settleDelay
            let wantsSeamless = options.renderMode != .fast && !seamlessDone && (settled || options.renderMode == .seamless)
            if wantsSeamless {
                await seamlessPass(frame)
                seamlessDone = lastChange <= frame.time
                continue
            }
            if options.renderMode != .seamless, let dirty = dirtyRect(for: frame) {
                await fastPass(frame, dirty: dirty)
                continue
            }
            break
        }
        working = false
        setActivity(inFlight.isEmpty ? .idle : .translating)
        if options.renderMode == .adaptive, !seamlessDone, latest != nil {
            let wait = max(0.05, options.settleDelay - (ProcessInfo.processInfo.systemUptime - lastChange))
            settleTask?.cancel()
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.kick()
            }
        }
    }

    /// Image-pixel rect needing a re-read, or nil when the blocks still describe the frame.
    private func dirtyRect(for frame: CapturedFrame) -> CGRect? {
        let full = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        guard let base = baseGray else { return full }
        let change = FrameDiff.changeMap(from: base, to: frame.gray)
        var dirty = change.dirtyRect
        if let f = forcedDirty { dirty = dirty.map { PixelRect($0.cgRect.union(f.cgRect)) } ?? f }
        guard let d = dirty else { return nil }
        let step = CGFloat(frame.grayStep), pad = CGFloat(change.tile) * step
        // Text runs horizontally: widen to full rows so partially changed lines are read whole.
        return CGRect(x: 0, y: CGFloat(d.y) * step - pad, width: full.width, height: CGFloat(d.height) * step + 2 * pad)
            .intersection(full)
    }

    private func followScroll(dyGray: Int, frame: CapturedFrame) {
        shiftContent(dx: 0, dy: CGFloat(dyGray * frame.grayStep), dxGray: 0, dyGray: dyGray,
                     imageSize: CGSize(width: frame.image.width, height: frame.image.height))
    }

    /// The region moved to `newOrigin` (global Quartz points).
    ///
    /// - `contentMoved == false` (the user dragged the lens over static content): translated blocks stay glued
    ///   to the content — they slide the other way inside the region — and only newly revealed strips are read.
    /// - `contentMoved == true` (the anchored window moved, carrying its content along): nothing to re-read.
    /// Frames captured with the old geometry are skipped briefly either way.
    func regionMoved(to newOrigin: CGPoint, contentMoved: Bool) {
        let delta = CGVector(dx: newOrigin.x - origin.x, dy: newOrigin.y - origin.y)
        origin = newOrigin
        ignoreFramesUntil = ProcessInfo.processInfo.systemUptime + 0.12
        guard !contentMoved, let frame = latest else { return }
        // Blocks move by the exact pixel delta; the gray references only by whole gray pixels, with the
        // fraction carried over so a slow drag never drifts.
        let px = -delta.dx * scale, py = -delta.dy * scale
        let step = CGFloat(frame.grayStep)
        let gx = grayShiftX.add(px / step), gy = grayShiftY.add(py / step)
        lastChange = ProcessInfo.processInfo.systemUptime
        seamlessDone = false
        if gx != 0 || gy != 0 { prevGray = prevGray?.shifted(dx: gx, dy: gy) }
        shiftContent(dx: px, dy: py, dxGray: gx, dyGray: gy, imageSize: CGSize(width: frame.image.width, height: frame.image.height))
        kick()
    }

    /// The region was resized: keep blocks (matched again on the next read) but read everything.
    func regionResized() {
        baseGray = nil
        prevGray = nil
        lastChange = ProcessInfo.processInfo.systemUptime
        seamlessDone = false
        ignoreFramesUntil = ProcessInfo.processInfo.systemUptime + 0.12
    }

    private func shiftContent(dx: CGFloat, dy: CGFloat, dxGray: Int, dyGray: Int, imageSize: CGSize) {
        scrollEpoch += 1
        let bounds = CGRect(origin: .zero, size: imageSize)
        blocks = blocks.compactMap { b in
            var b = b
            b.rect = b.rect.offsetBy(dx: dx, dy: dy)
            b.lines = b.lines.map { $0.offsetBy(dx: dx, dy: dy) }
            // Blocks cut by the edge stay (the overlay clips them, like a lens); gone ones are dropped.
            return b.rect.intersects(bounds) ? b : nil
        }
        if let base = baseGray, dxGray != 0 || dyGray != 0 {
            baseGray = base.shifted(dx: dxGray, dy: dyGray)
            for strip in base.vacatedStrips(dx: dxGray, dy: dyGray) {
                forcedDirty = forcedDirty.map { PixelRect($0.cgRect.union(strip.cgRect)) } ?? strip
            }
        }
        emit(animated: false)
    }

    // MARK: - Passes

    private var ocrLanguages: [Locale.Language] {
        options.sourceLanguage == "auto" ? [] : [Locale.Language(identifier: options.sourceLanguage)]
    }

    private func fastPass(_ frame: CapturedFrame, dirty: CGRect) async {
        setActivity(.reading)
        let epoch = scrollEpoch
        let useFast = options.sourceLanguage != "auto" && Languages.isLatinScript(options.sourceLanguage)
        let t = Trace.now
        let lines: [OCRLine]
        do {
            lines = try await TextRecognizer.lines(in: frame.image, roi: dirty, languages: ocrLanguages, fast: useFast,
                                                  customWords: options.glossaryTerms)
        } catch {
            log.error("fast OCR failed: \(error.localizedDescription)")
            baseGray = frame.gray
            return
        }
        // Content scrolled while we were reading: these coordinates are stale, read the newer frame instead.
        guard epoch == scrollEpoch else { return }
        Trace.mark("fast: OCR \(Int(dirty.height))px band → \(lines.count) lines", since: t)
        let fresh = lines.filter { TextRecognizer.needsTranslation($0.text, target: options.targetLanguage) }
        let (inside, outside) = blocks.partitioned { $0.rect.intersects(dirty) }
        let matches = BlockMatcher.match(old: inside.map { .init(rect: $0.rect, text: $0.source) },
                                         new: fresh.map { .init(rect: $0.rect, text: $0.text) })
        var updated = outside
        for (i, line) in fresh.enumerated() {
            let boxRect = line.rect.insetBy(dx: -max(2, line.rect.height * 0.12), dy: -max(1, line.rect.height * 0.08))
                .intersection(CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
            if let oi = matches[i] {
                var b = inside[oi]
                let moved = TextSimilarity.iou(b.rect, boxRect) < 0.9
                let textChanged = b.source != line.text
                b.rect = boxRect
                b.lines = [line.rect]
                if textChanged { b.source = line.text; b.translation = nil }
                if moved || textChanged || b.erased != nil {
                    b.erased = nil
                    b.appearance = appearance(of: line.rect, in: frame.image)
                    b.image = nil
                }
                updated.append(b)
            } else {
                updated.append(Block(id: UUID(), rect: boxRect, lines: [line.rect], source: line.text,
                                     appearance: appearance(of: line.rect, in: frame.image)))
            }
        }
        blocks = updated
        baseGray = frame.gray
        forcedDirty = nil
        await fillTranslations()
        renderMissing()
        emit(animated: false)
    }

    private func seamlessPass(_ frame: CapturedFrame) async {
        setActivity(.reading)
        let epoch = scrollEpoch
        var t = Trace.now
        var found: [OCRBlock]
        do {
            found = try await TextRecognizer.blocks(in: frame.image, languages: ocrLanguages, customWords: options.glossaryTerms)
            if found.isEmpty {
                found = try await TextRecognizer.lines(in: frame.image, languages: ocrLanguages, fast: false)
                    .map { TextRecognizer.makeBlock([$0]) }
            }
        } catch {
            log.error("document OCR failed: \(error.localizedDescription)")
            baseGray = frame.gray
            return
        }
        guard epoch == scrollEpoch else { return }
        Trace.mark("seamless: document OCR (\(found.count) blocks)", since: t); t = Trace.now
        found = found.filter { TextRecognizer.needsTranslation($0.text, target: options.targetLanguage) }
        guard let full = RGBAImage(cgImage: frame.image) else { return }
        Trace.mark("seamless: frame → RGBA", since: t); t = Trace.now

        let matches = BlockMatcher.match(old: blocks.map { .init(rect: $0.rect, text: $0.source) },
                                         new: found.map { .init(rect: $0.rect, text: $0.text) })
        var next: [Block] = []
        for (i, ocr) in found.enumerated() {
            guard let e = erase(ocr, in: full) else { continue }
            let id = matches[i].map { blocks[$0].id } ?? UUID()
            var b = Block(id: id, rect: e.rect.cgRect, lines: ocr.lines.map(\.rect), source: ocr.text, appearance: e.look,
                          fontSize: e.fontSize, spareWidth: e.spare)
            if let oi = matches[i], blocks[oi].source == ocr.text { b.translation = blocks[oi].translation }
            b.erased = e.patch
            next.append(b)
        }
        Trace.mark("seamless: erase \(next.count) blocks", since: t); t = Trace.now
        blocks = next
        baseGray = frame.gray
        forcedDirty = nil
        await fillTranslations()
        renderMissing()
        Trace.mark("seamless: render", since: t)
        emit(animated: true)
    }

    // MARK: - Erasing

    private struct Erased {
        var rect: PixelRect
        var patch: RGBAImage
        var look: TextAppearance
        var fontSize: CGFloat?
        var spare: CGFloat
    }

    /// Erases a block's text: builds the glyph mask per line, then fills it (flat backgrounds) or inpaints it
    /// (textured ones). The patch also takes in free background to the right for longer translations.
    private func erase(_ block: OCRBlock, in full: RGBAImage) -> Erased? {
        let lineHeight = block.lines.map(\.rect.height).sorted()[block.lines.count / 2]
        let ring = max(3, Int(lineHeight * 0.18))
        var rect = PixelRect(block.rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: full.width, height: full.height)
        guard !rect.isEmpty else { return nil }

        var masks: [(PixelRect, TextMask)] = []
        var glyphHeights: [CGFloat] = []
        for line in block.lines {
            let lr = PixelRect(line.rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: full.width, height: full.height)
            guard !lr.isEmpty else { continue }
            let text = PixelRect(line.rect).clamped(width: full.width, height: full.height)
            let local = PixelRect(x: text.x - lr.x, y: text.y - lr.y, width: text.width, height: text.height)
            let m = TextEraser.mask(for: full.cropped(to: lr), textRect: local, dilation: max(1, Int(line.rect.height * 0.07)))
            masks.append((lr, m))
            if let g = m.glyphBounds { glyphHeights.append(CGFloat(g.height)) }
        }
        // Prefer a line whose glyphs were actually segmented over a whole-box fallback.
        guard let look = masks.map(\.1.appearance).first(where: { $0.coverage < 0.95 }) ?? masks.first?.1.appearance else { return nil }

        let spare = freeWidth(rightOf: rect, in: full, background: look.backgroundColor)
        rect.width += spare
        var patch = full.cropped(to: rect)
        var mask = [UInt8](repeating: 0, count: rect.width * rect.height)
        for (lr, m) in masks {
            for y in 0..<lr.height {
                for x in 0..<lr.width where m.bits[y * lr.width + x] != 0 {
                    let px = lr.x + x - rect.x, py = lr.y + y - rect.y
                    if px >= 0, py >= 0, px < rect.width, py < rect.height { mask[py * rect.width + px] = 1 }
                }
            }
        }

        TextEraser.fillEnclosedHoles(&mask, width: rect.width, height: rect.height)
        let flat = masks.allSatisfy(\.1.appearance.isFlatBackground)
        if ProcessInfo.processInfo.environment["MWOYEA_ERASE_ONLY"] == "mask" {
            for i in mask.indices where mask[i] != 0 { patch.set(x: i % rect.width, y: i / rect.width, RGBA(255, 0, 0)) }
        } else if !flat, options.useInpainting, let inpainter {
            do {
                patch = try inpainter.inpaint(frame: full, rect: rect, mask: mask)
            } catch {
                log.error("inpainting failed: \(error.localizedDescription)")
                TextEraser.fill(&patch, mask: mask)
            }
        } else {
            TextEraser.fill(&patch, mask: mask)
        }
        let glyph = glyphHeights.isEmpty ? nil : glyphHeights.sorted()[glyphHeights.count / 2]
        return Erased(rect: rect, patch: patch, look: look, fontSize: glyph.map { Self.emSize(glyphHeight: $0, text: block.text) },
                      spare: CGFloat(spare))
    }

    /// Columns to the right of `rect` that hold nothing but the background colour (up to 80 % more width).
    private func freeWidth(rightOf rect: PixelRect, in full: RGBAImage, background: RGBA) -> Int {
        let limit = min(full.width - (rect.x + rect.width), Int(Double(rect.width) * 0.8))
        guard limit > 0 else { return 0 }
        var free = 0
        columns: while free < limit {
            let x = rect.x + rect.width + free
            for y in stride(from: rect.y, to: rect.y + rect.height, by: 2) where full.color(x: x, y: y).distance(to: background) > 22 {
                break columns
            }
            free += 1
        }
        // Leave a margin before whatever stopped us (a box edge, another label).
        return free < limit ? max(0, free - max(4, rect.height / 4)) : free
    }

    /// Em size from the measured glyph height: CJK and Hangul glyphs fill ~88 % of the em; Latin text spans
    /// cap height (~70 %) or, with descenders, ascender-to-descender (~95 %).
    static func emSize(glyphHeight h: CGFloat, text: String) -> CGFloat {
        if text.contains(where: TextRecognizer.isCJK) || text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
            return h / 0.88
        }
        return text.contains(where: { "gjpqy".contains($0) }) ? h / 0.95 : h / 0.72
    }

    private func appearance(of lineRect: CGRect, in image: CGImage) -> TextAppearance {
        let ring = max(2, Int(lineRect.height * 0.15))
        let crop = PixelRect(lineRect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: image.width, height: image.height)
        let text = PixelRect(lineRect).clamped(width: image.width, height: image.height)
        guard let patch = RGBAImage(cgImage: image, crop: crop) else {
            return TextAppearance(textColor: RGBA(255, 255, 255), backgroundColor: RGBA(0, 0, 0), backgroundNoise: 0, coverage: 0.2)
        }
        let local = PixelRect(x: text.x - crop.x, y: text.y - crop.y, width: text.width, height: text.height)
        return TextEraser.mask(for: patch, textRect: local, dilation: 0).appearance
    }

    // MARK: - Translation

    /// Fills translations from the cache right away, and requests the rest in the background.
    private func fillTranslations() async {
        var missing: [String] = []
        // Reading order, so translations fill in top to bottom.
        for i in blocks.indices.sorted(by: { blocks[$0].rect.minY < blocks[$1].rect.minY }) where blocks[i].translation == nil {
            if let hit = await translator.cached(blocks[i].source) {
                blocks[i].translation = hit
                blocks[i].image = nil
            } else {
                missing.append(blocks[i].source)
            }
        }
        request(missing)
    }

    private func request(_ texts: [String]) {
        var seen = Set<String>()
        let todo = texts.filter { !inFlight.contains($0) && seen.insert($0).inserted }
        guard !todo.isEmpty else { return }
        inFlight.formUnion(todo)
        setActivity(.translating)
        Task {
            let t = Trace.now
            let result = await translator.translate(todo) { source, translated in
                Task { await self.receive([source: translated], requested: []) }
            }
            Trace.mark("translate ×\(todo.count)", since: t)
            self.receive(result, requested: todo)
        }
    }

    private func receive(_ result: [String: String], requested: [String]) {
        requested.forEach { inFlight.remove($0) }
        var changed = false
        for i in blocks.indices {
            guard let t = result[blocks[i].source], blocks[i].translation != t else { continue }
            blocks[i].translation = t
            blocks[i].image = nil
            changed = true
        }
        if changed {
            renderMissing()
            emit(animated: true)
        }
        if inFlight.isEmpty, !working { setActivity(.idle) }
    }

    // MARK: - Output

    private func renderMissing() {
        for i in blocks.indices where blocks[i].image == nil {
            let b = blocks[i]
            guard let text = b.translation, !text.isEmpty else { continue }
            let heights = b.lines.map(\.height).sorted()
            let lineHeight = heights.isEmpty ? b.rect.height : heights[heights.count / 2]
            let background: BlockRenderer.Background = b.erased.map { .erased($0) }
                ?? .box(b.appearance.backgroundColor, opacity: options.boxOpacity)
            blocks[i].image = BlockRenderer.render(.init(
                size: b.rect.size, text: text, background: background, appearance: b.appearance,
                lineHeight: lineHeight, fontSize: b.fontSize, originalLineCount: max(1, b.lines.count), spareWidth: b.spareWidth,
                fontStyle: options.fontStyle,
                targetLanguage: options.targetLanguage, scale: scale))
        }
    }

    private func emit(animated: Bool) {
        version += 1
        let s = scale
        let out = blocks.compactMap { b -> OverlayBlock? in
            guard let img = b.image else { return nil }
            return OverlayBlock(id: b.id, frame: CGRect(x: b.rect.minX / s, y: b.rect.minY / s, width: b.rect.width / s, height: b.rect.height / s),
                                image: img, seamless: b.erased != nil)
        }
        onSnapshot(OverlaySnapshot(version: version, blocks: out, animated: animated, origin: origin))
    }

    private func setActivity(_ a: RegionActivity) {
        guard a != activity else { return }
        activity = a
        onActivity?(a)
    }
}

/// Stage timings on stderr when MWOYEA_TRACE is set.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["MWOYEA_TRACE"] != nil
    static func mark(_ label: @autoclosure () -> String, since t: TimeInterval) {
        guard enabled else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - t) * 1000)
        FileHandle.standardError.write("[trace] \(label()) \(ms) ms\n".data(using: .utf8)!)
    }
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

extension Array {
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = [], no: [Element] = []
        for e in self { if belongs(e) { yes.append(e) } else { no.append(e) } }
        return (yes, no)
    }
}
