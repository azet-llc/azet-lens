import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // `AZET Lens --render in.png out.png` runs the pipeline on a still image (no permissions needed).
        if CommandLine.arguments.dropFirst().first == "--render" {
            SelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
        }
        MwoyeoApp.main()
    }
}

struct MwoyeoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: menuSymbol)
                .accessibilityLabel("AZET Lens")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    private var menuSymbol: String {
        if model.isPaused { return "pause.circle" }
        if !model.translationsVisible { return "eye.slash" }
        return model.regions.contains(where: \.isEnabled) ? "text.viewfinder" : "viewfinder"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.bootstrap() }
        // `MWOYEO_PREVIEW=menu|onboarding` shows that window on launch, for screenshots.
        switch ProcessInfo.processInfo.environment["MWOYEO_PREVIEW"] {
        case "menu": Task { @MainActor in WindowPresenter.shared.showMenuPreview() }
        case "onboarding": Task { @MainActor in WindowPresenter.shared.showOnboarding() }
        default: break
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows the menu panel once set up, since a full menu
    /// bar on a notched Mac can hide the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            let model = AppModel.shared
            model.recheckPermission()
            if model.settings.hasCompletedOnboarding && model.hasScreenPermission {
                WindowPresenter.shared.showMenu()
            } else {
                WindowPresenter.shared.showOnboarding()
            }
        }
        return true
    }
}

/// Opens AppKit-hosted windows (onboarding, the menu panel) and the Settings scene for a menu-bar-only app.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var onboarding: NSWindow?
    private var menu: NSPanel?

    /// The menu panel in a window of its own under the top-right of the menu bar, for when the icon can't be
    /// reached. Closes when it loses focus, like the menu.
    func showMenu() {
        let w = menu ?? makeMenuPanel()
        menu = w
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            w.setFrameTopLeftPoint(CGPoint(x: v.maxX - w.frame.width - 10, y: v.maxY - 6))
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func toggleMenu() {
        if let w = menu, w.isVisible { w.close() } else { showMenu() }
    }

    private func makeMenuPanel() -> NSPanel {
        let w = NSPanel(contentViewController: NSHostingController(rootView: MenuPanel().environment(AppModel.shared)))
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isFloatingPanel = true
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menu?.close() }
        }
        return w
    }

    func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = onboarding {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.closeOnboarding() }
            .environment(AppModel.shared))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        onboarding = w
    }

    func showMenuPreview() {
        let w = NSWindow(contentViewController: NSHostingController(rootView: MenuPanel().environment(AppModel.shared)))
        w.styleMask = [.titled, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.setFrameTopLeftPoint(CGPoint(x: 200, y: (NSScreen.main?.frame.maxY ?? 900) - 120))
        w.makeKeyAndOrderFront(nil)
        preview = w
    }

    private var preview: NSWindow?

    func closeOnboarding() {
        onboarding?.close()
        onboarding = nil
    }
}
