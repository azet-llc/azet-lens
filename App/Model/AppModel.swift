import AppKit
import Observation
import os

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            let s = settings
            Task {
                await translator.update(settings: s)
                for session in sessions.values { await session.update(settings: s) }
            }
        }
    }

    private(set) var regions: [RegionConfig] = [] {
        didSet { save() }
    }

    private(set) var translationsVisible = true
    private(set) var isPaused = false
    private(set) var issue: TranslationIssue?
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private(set) var inpaintingAvailable = false
    /// Bumped when any session's activity/error changes, so views re-read them.
    private(set) var sessionTick = 0

    @ObservationIgnored let translator: TranslationService
    @ObservationIgnored private var sessions: [UUID: RegionSession] = [:]
    @ObservationIgnored private var inpainter: Inpainter?
    @ObservationIgnored private let picker = RegionPicker()
    @ObservationIgnored private var picking = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "dev.midagedev.mwoyea", category: "app")

    private init() {
        let s = (defaults.data(forKey: "settings")).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        settings = s
        translator = TranslationService(settings: s)
        regions = (defaults.data(forKey: "regions")).flatMap { try? JSONDecoder().decode([RegionConfig].self, from: $0) } ?? []
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: "settings") }
        if let d = try? JSONEncoder().encode(regions) { defaults.set(d, forKey: "regions") }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        HotKeys.shared.register(HotKeys.addRegion) { [weak self] in Task { await self?.addRegion() } }
        HotKeys.shared.register(HotKeys.toggleOriginal) { [weak self] in self?.toggleTranslations() }
        HotKeys.shared.register(HotKeys.pause) { [weak self] in Task { await self?.togglePause() } }
        HotKeys.shared.register(HotKeys.refresh) { [weak self] in Task { await self?.refreshAll() } }

        await translator.setIssueHandler { issue in Task { @MainActor in AppModel.shared.issue = issue } }
        await translator.prewarm()
        inpainter = await Task.detached(priority: .userInitiated) { Inpainter.load() }.value
        inpaintingAvailable = inpainter != nil
        Self.warmUpVision()

        if !settings.hasCompletedOnboarding || !hasScreenPermission {
            WindowPresenter.shared.showOnboarding()
        }
        // Window IDs do not survive the target app relaunching; re-find anchors by app + title.
        regions = regions.map(reanchor)
        if hasScreenPermission {
            for r in regions where r.isEnabled { await startSession(r) }
        }
    }

    /// The accurate text recognizer takes tens of seconds to load the first time; do it before the user needs it.
    private static func warmUpVision() {
        Task.detached(priority: .utility) {
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(.white)
            ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            if let img = ctx?.makeImage() {
                _ = try? await TextRecognizer.lines(in: img, languages: [Locale.Language(identifier: "ja")], fast: false)
                _ = try? await TextRecognizer.blocks(in: img, languages: [])
            }
        }
    }

    func recheckPermission() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        recheckPermission()
    }

    // MARK: - Regions

    func addRegion() async {
        guard !picking else { return }
        recheckPermission()
        guard hasScreenPermission else {
            WindowPresenter.shared.showOnboarding()
            return
        }
        picking = true
        defer { picking = false }
        guard let result = await picker.pick() else { return }
        var config = RegionConfig(name: result.window.map { $0.appName.isEmpty ? "창" : $0.appName } ?? "영역 \(regions.count + 1)",
                                  rect: result.rect)
        if let w = result.window {
            config.anchor = WindowAnchor(windowID: w.id, appName: w.appName, title: w.title,
                                         offset: CGPoint(x: result.rect.minX - w.bounds.minX, y: result.rect.minY - w.bounds.minY))
        }
        regions.append(config)
        if isPaused { isPaused = false; for r in regions where r.isEnabled && sessions[r.id] == nil { await startSession(r) } }
        else { await startSession(config) }
    }

    func remove(_ id: UUID) async {
        await sessions.removeValue(forKey: id)?.stop()
        regions.removeAll { $0.id == id }
        sessionTick += 1
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].isEnabled = enabled
        if enabled, !isPaused { await startSession(regions[i]) } else { await sessions.removeValue(forKey: id)?.stop() }
        sessionTick += 1
    }

    func toggleAnchor(_ id: UUID) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        if regions[i].anchor != nil {
            regions[i].anchor = nil
        } else {
            let r = regions[i].rect
            if let w = WindowInfo.onScreen().first(where: { $0.bounds.contains(r) }) {
                regions[i].anchor = WindowAnchor(windowID: w.id, appName: w.appName, title: w.title,
                                                 offset: CGPoint(x: r.minX - w.bounds.minX, y: r.minY - w.bounds.minY))
            }
        }
        sessions[id]?.setAnchor(regions[i].anchor)
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = regions.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        regions[i].name = name
        sessions[id]?.rename(name)
    }

    func activity(of id: UUID) -> RegionActivity { sessions[id]?.activity ?? .idle }
    func error(of id: UUID) -> String? { sessions[id]?.errorMessage }
    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    var isBusy: Bool { sessions.values.contains { $0.activity != .idle } }

    private func startSession(_ config: RegionConfig) async {
        guard sessions[config.id] == nil else { return }
        let s = RegionSession(config: config, settings: settings, translator: translator, inpainter: inpainter)
        s.onChange = { [weak self] in self?.sessionTick += 1 }
        s.onConfigChange = { [weak self] updated in
            guard let self, let i = regions.firstIndex(where: { $0.id == updated.id }) else { return }
            regions[i].rect = updated.rect
            regions[i].anchor = updated.anchor
        }
        s.onCloseRequest = { [weak self] in Task { await self?.remove(config.id) } }
        sessions[config.id] = s
        s.setTranslationsVisible(translationsVisible)
        await s.start()
    }

    private func reanchor(_ r: RegionConfig) -> RegionConfig {
        guard let a = r.anchor, WindowInfo.window(id: a.windowID) == nil else { return r }
        var r = r
        let windows = WindowInfo.onScreen()
        if let w = windows.first(where: { $0.appName == a.appName && $0.title == a.title })
            ?? windows.first(where: { $0.appName == a.appName }) {
            r.anchor?.windowID = w.id
            r.rect.origin = CGPoint(x: w.bounds.minX + a.offset.x, y: w.bounds.minY + a.offset.y)
        } else {
            r.anchor = nil // keep the area where it was
        }
        return r
    }

    // MARK: - Global actions

    func toggleTranslations() {
        translationsVisible.toggle()
        sessions.values.forEach { $0.setTranslationsVisible(translationsVisible) }
    }

    func togglePause() async {
        isPaused.toggle()
        if isPaused {
            for s in sessions.values { await s.stop() }
            sessions.removeAll()
        } else {
            for r in regions where r.isEnabled { await startSession(r) }
        }
        sessionTick += 1
    }

    func refreshAll() async {
        await translator.invalidateAvailability()
        for s in sessions.values { await s.refresh() }
    }

    func languagePacksChanged() async {
        issue = nil
        await refreshAll()
    }
}
