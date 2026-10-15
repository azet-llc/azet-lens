import CoreGraphics
import Foundation

enum TranslationEngineChoice: String, Codable, CaseIterable, Identifiable {
    /// The language pack's fast model when installed, Apple Intelligence's translation model otherwise.
    case auto
    /// Always Apple Intelligence's high-fidelity translation model.
    case highFidelity
    /// A prompted on-device LLM (Foundation Models) that follows the glossary.
    case customModel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "자동"
        case .highFidelity: "고품질"
        case .customModel: "용어집 우선"
        }
    }
    var detail: String {
        switch self {
        case .auto: "언어 팩이 있으면 가장 빠른 번역, 없으면 Apple Intelligence 번역"
        case .highFidelity: "항상 Apple Intelligence 번역 모델 · 한 줄에 0.5초 안팎"
        case .customModel: "Foundation Models가 용어집을 지켜 번역 · 게임·작품 고유명사에"
        }
    }
}

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    /// Fast boxes while content moves, seamless in-place rewrite once it is still.
    case adaptive
    case fast
    case seamless

    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: "적응형"
        case .fast: "빠르게"
        case .seamless: "자연스럽게"
        }
    }
    var detail: String {
        switch self {
        case .adaptive: "움직이는 동안엔 상자, 멈추면 원문을 지우고 그 자리에 다시 씁니다"
        case .fast: "항상 단색 상자 위에 번역을 띄웁니다. 배터리를 가장 적게 씁니다"
        case .seamless: "항상 원문을 지우고 다시 씁니다"
        }
    }
}

enum FontStyleChoice: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "기본"
        case .rounded: "둥근"
        case .serif: "명조"
        }
    }
}

struct AppSettings: Codable, Equatable {
    /// BCP-47 identifier, or "auto" to detect per line.
    var sourceLanguage = "auto"
    var targetLanguage = Locale.current.language.languageCode?.identifier ?? "ko"
    var engine = TranslationEngineChoice.auto
    var renderMode = RenderMode.adaptive
    var useInpaintingModel = true
    /// One "source = target" pair per line.
    var glossary = ""
    var framesPerSecond = 8.0
    /// Seconds without change before the seamless pass runs.
    var settleDelay = 0.5
    var fontStyle = FontStyleChoice.system
    /// Opacity of the box behind text in fast mode.
    var boxOpacity = 0.94
    var hasCompletedOnboarding = false

    var glossaryPairs: [(String, String)] {
        glossary.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    // Decode leniently so adding a field never wipes a user's saved settings.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? d.sourceLanguage
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        engine = (try? c.decodeIfPresent(TranslationEngineChoice.self, forKey: .engine)) ?? d.engine
        renderMode = (try? c.decodeIfPresent(RenderMode.self, forKey: .renderMode)) ?? d.renderMode
        useInpaintingModel = try c.decodeIfPresent(Bool.self, forKey: .useInpaintingModel) ?? d.useInpaintingModel
        glossary = try c.decodeIfPresent(String.self, forKey: .glossary) ?? d.glossary
        framesPerSecond = try c.decodeIfPresent(Double.self, forKey: .framesPerSecond) ?? d.framesPerSecond
        settleDelay = try c.decodeIfPresent(Double.self, forKey: .settleDelay) ?? d.settleDelay
        fontStyle = (try? c.decodeIfPresent(FontStyleChoice.self, forKey: .fontStyle)) ?? d.fontStyle
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? d.boxOpacity
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }
}

/// A screen area being translated.
struct RegionConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Global Quartz coordinates (top-left origin of the primary display), in points.
    var rect: CGRect
    var isEnabled = true
    /// When set, the region moves with this window.
    var anchor: WindowAnchor?
}

struct WindowAnchor: Codable, Equatable {
    var windowID: CGWindowID
    var appName: String
    var title: String
    /// Region origin minus window origin (points).
    var offset: CGPoint
}

/// Common source languages offered in the UI; anything Vision + Translation support works via "auto".
enum Languages {
    static let sources = ["auto", "ja", "zh-Hans", "zh-Hant", "en", "ko", "fr", "de", "es", "ru", "vi", "th"]
    static let targets = ["ko", "en", "ja", "zh-Hans", "zh-Hant", "fr", "de", "es", "vi"]

    static func name(_ id: String) -> String {
        if id == "auto" { return "자동 감지" }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Scripts Vision's fast recognizer handles; everything else needs the accurate recognizer.
    static func isLatinScript(_ id: String) -> Bool {
        ["en", "fr", "de", "es", "it", "pt", "nl", "sv", "da", "nb", "nn", "no", "fi", "pl", "cs", "ro", "tr", "id", "ms", "vi"]
            .contains(Locale.Language(identifier: id).languageCode?.identifier ?? id)
    }
}
