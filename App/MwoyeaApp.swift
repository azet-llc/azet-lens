import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // `Mwoyea --render in.png out.png` runs the pipeline on a still image (no permissions needed).
        if CommandLine.arguments.dropFirst().first == "--render" {
            SelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
        }
        MwoyeaApp.main()
    }
}

struct MwoyeaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: menuSymbol)
                .accessibilityLabel("Mwoyea")
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
        return model.regions.contains(where: \.isEnabled) ? "character.bubble.fill" : "character.bubble"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.bootstrap() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowPresenter.shared.showOnboarding() }
        return true
    }
}

/// Opens AppKit-hosted windows (onboarding) and the Settings scene for a menu-bar-only app.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var onboarding: NSWindow?

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

    func closeOnboarding() {
        onboarding?.close()
        onboarding = nil
    }
}
