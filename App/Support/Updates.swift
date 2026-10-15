import AppKit
import Observation

/// Asks GitHub for the latest release. Sends nothing but the request itself: no screen text, no identifiers.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(version: String, page: URL)
    }

    private(set) var state = State.idle

    static let repository = URL(string: "https://github.com/midagedev/mwoyeo")!
    static let releases = repository.appending(path: "releases")
    static let issues = repository.appending(path: "issues")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    /// Installed with `brew install midagedev/tap/mwoyeo`: update the same way, or brew loses track of the app.
    static let viaHomebrew = ["/opt/homebrew/Caskroom/mwoyeo", "/usr/local/Caskroom/mwoyeo"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let lastCheckKey = "lastUpdateCheck"

    func check() async {
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/midagedev/mwoyeo/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            state = Self.isNewer(latest, than: Self.version) ? .available(version: latest, page: release.html_url) : .upToDate
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        } catch {
            state = .failed
        }
    }

    /// Checks once a day while `enabled`, starting now if the last check is a day old.
    func schedule(enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        let due = { [lastCheckKey] in
            (UserDefaults.standard.object(forKey: lastCheckKey) as? Date).map { Date().timeIntervalSince($0) > 86_400 } ?? true
        }
        if due() { Task { await check() } }
        let t = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in if due() { await Updates.shared.check() } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
