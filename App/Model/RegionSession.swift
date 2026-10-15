import AppKit
import MwoyeoCore
import os

/// Runs one region: capture → pipeline → overlay, plus the draggable lens chrome around it, and keeps it
/// glued to its window when anchored.
///
/// The capture is larger than the lens (overscan): the text around it is read and translated ahead, so dragging the
/// lens or scrolling reveals translations that are already there. The margin widens while things move, and more of it
/// lies where things are heading; the lens moves freely inside it and the capture only re-centres when the lens nears
/// its edge.
///
/// Scroll events over the capture predict where the content is going before the frames show it, so the translations
/// move with the page like the page moves with the finger.
@MainActor
final class RegionSession {
    private(set) var config: RegionConfig
    private(set) var activity = RegionActivity.idle
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    /// The region's rect or anchor changed (lens dragged, window followed); persist it.
    var onConfigChange: ((RegionConfig) -> Void)?
    var onCloseRequest: (() -> Void)?

    private let capturer = RegionCapturer()
    private let pipeline: RegionPipeline
    private let panel: OverlayPanel
    private let chrome: RegionFrameWindow
    private var fps: Double
    private var trackTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var hiddenByOcclusion = false
    private var translationsVisible = true
    private var dragging = false
    private var captureUpdateRunning = false
    private var captureUpdatePending = false
    /// Captured rect, global Quartz points; contains `config.rect` (the visible lens).
    private var capture: CGRect
    private var wideMargins = false
    private var lastMotion: TimeInterval = 0
    private var calmTimer: Timer?
    /// Where things are heading (-1…1 per axis): the lens while dragged, new content while the page scrolls.
    private var lead = CGVector.zero
    private var lastLens: (rect: CGRect, time: TimeInterval)?
    private var predictor = ScrollPredictor()
    /// The area under the pointer that scrolled last (global Quartz points), and the window it belongs to.
    private var scrollArea: CGRect?
    private var scrollWindow: CGWindowID?
    private var lastWheel: TimeInterval = 0
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "session")

    init(config: RegionConfig, settings: AppSettings, translator: TranslationService, inpainter: Inpainter?) {
        self.config = config
        self.fps = settings.framesPerSecond
        let frame = ScreenGeometry.appKitRect(fromQuartz: config.rect)
        let panel = OverlayPanel(frame: frame)
        self.panel = panel
        chrome = RegionFrameWindow(region: frame, name: config.name)
        chrome.setDetail(Self.languagePair(settings))
        let capture = Self.overscan(config.rect, wide: false)
        self.capture = capture
        pipeline = RegionPipeline(options: PipelineOptions(settings), capture: capture, translator: translator,
                                  inpainter: inpainter, onSnapshot: { snapshot in Task { @MainActor in panel.apply(snapshot) } })
        capturer.onFrame = { [pipeline] frame in Task { await pipeline.ingest(frame) } }
        capturer.onStop = { [weak self] error in Task { @MainActor in self?.captureStopped(error) } }
        wireChrome()
    }

    func start() async {
        await pipeline.setActivityHandler { [weak self] a in Task { @MainActor in self?.setActivity(a) } }
        await pipeline.setMotionHandler { [weak self] in Task { @MainActor in self?.noteMotion() } }
        await pipeline.setScrollHandler { [weak self] r in Task { @MainActor in self?.scrolled(r) } }
        panel.prediction = { [weak self] since, now in self?.predictedScroll(since: since, now: now) }
        await pipeline.setVisible(config.rect)
        panel.orderFrontRegardless()
        chrome.orderFrontRegardless()
        panel.setTranslationsVisible(translationsVisible, animated: false)
        do {
            try await capturer.start(rect: capture, fps: fps)
            errorMessage = nil
            chrome.sweep()
        } catch {
            errorMessage = String(localized: "Couldn’t start capturing: \(error.localizedDescription)")
            log.error("capture start failed: \(error.localizedDescription)")
        }
        startTracking()
        watchPointer()
        onChange?()
    }

    func stop() async {
        trackTimer?.invalidate()
        trackTimer = nil
        calmTimer?.invalidate()
        calmTimer = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        await capturer.stop()
        panel.orderOut(nil)
        chrome.orderOut(nil)
    }

    private static func languagePair(_ s: AppSettings) -> String {
        "\(s.sourceLanguage == "auto" ? String(localized: "Auto") : Languages.name(s.sourceLanguage)) → \(Languages.name(s.targetLanguage))"
    }

    func update(settings: AppSettings) async {
        chrome.setDetail(Self.languagePair(settings))
        await pipeline.update(options: PipelineOptions(settings))
        if settings.framesPerSecond != fps {
            fps = settings.framesPerSecond
            try? await capturer.update(rect: capture, fps: fps)
        }
    }

    func refresh() async { await pipeline.refresh() }

    func rename(_ name: String) {
        config.name = name
        chrome.setName(name)
    }

    func setTranslationsVisible(_ visible: Bool) {
        translationsVisible = visible
        panel.setTranslationsVisible(visible && !hiddenByOcclusion)
    }

    func setAnchor(_ anchor: WindowAnchor?) {
        config.anchor = anchor
        startTracking()
    }

    private func setActivity(_ a: RegionActivity) {
        guard a != activity else { return }
        activity = a
        chrome.setBusy(a != .idle)
        onChange?()
    }

    private func captureStopped(_ error: Error?) {
        guard let error else { return }
        errorMessage = error.localizedDescription
        onChange?()
    }

    // MARK: - Lens (drag / resize)

    private func wireChrome() {
        chrome.onMove = { [weak self] frame in self?.lensMoved(frame) }
        chrome.onResize = { [weak self] frame in self?.lensResized(frame) }
        chrome.onCommit = { [weak self] in self?.lensDropped() }
        chrome.onClose = { [weak self] in self?.onCloseRequest?() }
    }

    private func lensMoved(_ appKitFrame: NSRect) {
        let rect = ScreenGeometry.quartzRect(fromAppKit: appKitFrame), now = ProcessInfo.processInfo.systemUptime
        // Heading: the direction of the last ~100 ms of the drag.
        if let last = lastLens {
            if now - last.time > 0.1 {
                let d = CGVector(dx: rect.midX - last.rect.midX, dy: rect.midY - last.rect.midY), len = hypot(d.dx, d.dy)
                if len > 4 { setLead(CGVector(dx: d.dx / len, dy: d.dy / len)) }
                lastLens = (rect, now)
            }
        } else {
            lastLens = (rect, now)
        }
        if !dragging { dragging = true; noteMotion() }
        config.rect = rect
        // The content stays put, and so do the blocks: only which of them show changes.
        panel.slide(to: appKitFrame)
        fitCapture(allowResize: false)
    }

    /// Moves the lens as if dragged by `delta` (Quartz points, y down) over `duration`, eased. For scripted demos.
    func glide(by delta: CGVector, duration: TimeInterval) async {
        let start = ScreenGeometry.appKitRect(fromQuartz: config.rect)
        let steps = max(1, Int(duration * 60))
        for i in 1...steps {
            let t = Double(i) / Double(steps), e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let f = start.offsetBy(dx: delta.dx * e, dy: -delta.dy * e)
            chrome.setRegion(f)
            lensMoved(f)
            try? await Task.sleep(for: .milliseconds(16))
        }
        lensDropped()
    }

    private func lensResized(_ appKitFrame: NSRect) {
        dragging = true
        config.rect = ScreenGeometry.quartzRect(fromAppKit: appKitFrame)
        panel.slide(to: appKitFrame)
        fitCapture(allowResize: false)
    }

    private func lensDropped() {
        dragging = false
        lastLens = nil
        setLead(.zero)
        fitCapture(allowResize: true)
        // Re-evaluate which window (if any) the lens now sits in.
        if config.anchor != nil {
            if let w = WindowInfo.onScreen().first(where: { $0.bounds.contains(CGPoint(x: config.rect.midX, y: config.rect.midY)) }) {
                config.anchor = WindowAnchor(windowID: w.id, appName: w.appName, title: w.title,
                                             offset: CGPoint(x: config.rect.minX - w.bounds.minX, y: config.rect.minY - w.bounds.minY))
            } else {
                config.anchor = nil
            }
            startTracking()
        }
        onConfigChange?(config)
        updateEmphasis(NSEvent.mouseLocation)
    }

    // MARK: - Overscan

    /// The lens's display, Quartz points.
    private static func display(of lens: CGRect) -> CGRect {
        ScreenGeometry.screen(for: lens).map { ScreenGeometry.quartzRect(fromAppKit: $0.frame) } ?? lens
    }

    static func overscan(_ lens: CGRect, wide: Bool) -> CGRect {
        Overscan.rect(around: lens, wide: wide, display: display(of: lens))
    }

    private func fitCapture(allowResize: Bool) {
        let lens = config.rect
        switch Overscan.plan(lens: lens, capture: capture, wide: wideMargins, allowResize: allowResize, display: Self.display(of: lens), lead: lead) {
        case .keep: break
        case .move(let r):
            capture = r
            // The pipeline must know the new geometry before the capturer delivers its first frame of it.
            Task { await pipeline.captureMoved(to: r.origin); scheduleCaptureUpdate() }
        case .resize(let r):
            capture = r
            Task { await pipeline.captureResized(to: r); scheduleCaptureUpdate() }
        }
        Task { [pipeline] in await pipeline.setVisible(lens) }
    }

    /// Content or lens is moving: read wider until things calm down for a few seconds.
    private func noteMotion() {
        lastMotion = ProcessInfo.processInfo.systemUptime
        if !wideMargins {
            wideMargins = true
            fitCapture(allowResize: true)
        }
        guard calmTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkCalm() } }
        RunLoop.main.add(t, forMode: .common)
        calmTimer = t
    }

    private func checkCalm() {
        guard !dragging, ProcessInfo.processInfo.systemUptime - lastMotion > 4 else { return }
        calmTimer?.invalidate()
        calmTimer = nil
        wideMargins = false
        setLead(.zero)
        fitCapture(allowResize: true)
    }

    private func setLead(_ v: CGVector) {
        guard v != lead else { return }
        lead = v
        Task { [pipeline] in await pipeline.setLead(v) }
    }

    // MARK: - Scrolling

    /// A scroll event anywhere: if it scrolls content this lens reads, it predicts the next frames.
    private func wheel(_ e: NSEvent) {
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard capture.contains(p), e.scrollingDeltaY != 0 || e.phase == .began else { return }
        if e.phase == .began || e.phase == .mayBegin || (e.phase.isEmpty && e.momentumPhase.isEmpty && e.timestamp - lastWheel > 0.5) {
            // A new gesture: pixels per wheel unit belong to the app (and page) under the pointer.
            let window = WindowInfo.onScreen().first { $0.bounds.contains(p) }?.id
            if window != scrollWindow { predictor.reset(); scrollArea = nil; scrollWindow = window }
        }
        predictor.wheel(delta: Double(e.scrollingDeltaY), time: e.timestamp, precise: e.hasPreciseScrollingDeltas)
        lastWheel = e.timestamp
        panel.predict()
    }

    /// The frames showed content scrolled: learn how far scroll events move it, and read ahead where it comes from.
    private func scrolled(_ r: ScrollReport) {
        setLead(CGVector(dx: 0, dy: r.shift < 0 ? 1 : -1))
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard r.area.contains(p) else { return }
        scrollArea = r.area
        predictor.confirm(shift: Double(r.shift), from: r.from, to: r.to)
    }

    /// The scroll the overlay should show on top of the frame captured at `since`, as of `now`.
    private func predictedScroll(since: TimeInterval, now: TimeInterval) -> (area: CGRect, dy: CGFloat)? {
        guard let area = scrollArea, now - lastWheel < 1 else { return nil }
        return (area, CGFloat(predictor.offset(from: since, to: now)))
    }

    /// Coalesces capture reconfiguration: at most one in flight, always ending on the latest rect.
    private func scheduleCaptureUpdate() {
        guard !captureUpdateRunning else { captureUpdatePending = true; return }
        captureUpdateRunning = true
        Task {
            repeat {
                captureUpdatePending = false
                do { try await capturer.update(rect: capture, fps: fps) } catch {
                    log.error("capture update failed: \(error.localizedDescription)")
                }
            } while captureUpdatePending
            captureUpdateRunning = false
        }
    }

    /// Show the lens chrome fully while the pointer is near the region; a faint outline otherwise.
    private func watchPointer() {
        guard mouseMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateEmphasis(NSEvent.mouseLocation) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { mouseMonitors.append(g) }
        // Scroll events of other apps need no accessibility permission (only key events do).
        if let s = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.wheel(e) }) { mouseMonitors.append(s) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { handler($0); return $0 }) {
            mouseMonitors.append(l)
        }
    }

    private func updateEmphasis(_ p: NSPoint) {
        let near = chrome.frame.insetBy(dx: -16, dy: -16).contains(p)
        let interior = chrome.regionFrame.insetBy(dx: 24, dy: 24).contains(p)
        chrome.setEmphasized(dragging || (near && !interior))
    }

    // MARK: - Window anchoring

    private func startTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        guard config.anchor != nil else {
            if hiddenByOcclusion { setOccluded(false) }
            return
        }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackWindow() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func trackWindow() {
        guard let anchor = config.anchor, !dragging else { return }
        guard let w = WindowInfo.window(id: anchor.windowID) else {
            setOccluded(true) // window closed or minimized
            return
        }
        // Hide while another window covers the region; the capture shows that window, not ours.
        let covered = WindowInfo.windows(above: anchor.windowID).contains { $0.bounds.intersects(config.rect.insetBy(dx: 4, dy: 4)) }
        setOccluded(!w.isOnScreen || covered)

        let target = CGRect(origin: CGPoint(x: w.bounds.minX + anchor.offset.x, y: w.bounds.minY + anchor.offset.y), size: config.rect.size)
        guard abs(target.minX - config.rect.minX) > 0.5 || abs(target.minY - config.rect.minY) > 0.5 else { return }
        let delta = CGVector(dx: target.minX - config.rect.minX, dy: target.minY - config.rect.minY)
        config.rect = target
        let frame = ScreenGeometry.appKitRect(fromQuartz: target)
        panel.move(to: frame)      // content moved with the window: blocks move along
        chrome.setRegion(frame)
        // The capture moves with the window too (slid back onto the display if it would leave it).
        let moved = Self.overscan(target, wide: wideMargins)
        if moved.size == capture.size {
            capture = moved
            Task { await pipeline.captureMoved(to: moved.origin, contentDelta: delta); scheduleCaptureUpdate() }
        }
        fitCapture(allowResize: false)
        onConfigChange?(config)
    }

    private func setOccluded(_ occluded: Bool) {
        guard occluded != hiddenByOcclusion else { return }
        hiddenByOcclusion = occluded
        panel.setTranslationsVisible(translationsVisible && !occluded)
        occluded ? chrome.orderOut(nil) : chrome.orderFrontRegardless()
    }
}
