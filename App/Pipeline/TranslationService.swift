import Foundation
import FoundationModels
import MwoyeaCore
import NaturalLanguage
import Translation

/// Which kind of pass a translation is for. Seamless passes may use the slower, more natural engine.
enum TranslationTier: Sendable {
    case fast
    case quality
}

struct TranslationRequestItem: Sendable, Hashable {
    let text: String
}

/// Something the user can act on (missing language pack, Apple Intelligence off, …).
enum TranslationIssue: Error, Equatable, Sendable {
    case languagePackMissing(source: String, target: String)
    case intelligenceUnavailable(String)
    case unsupportedPair(source: String, target: String)
    case failed(String)

    var message: String {
        switch self {
        case let .languagePackMissing(s, t):
            "\(Languages.name(s)) → \(Languages.name(t)) 언어 팩이 없습니다. 설정 › 번역에서 내려받으세요."
        case let .intelligenceUnavailable(why): "Apple Intelligence를 쓸 수 없습니다: \(why)"
        case let .unsupportedPair(s, t): "\(Languages.name(s)) → \(Languages.name(t)) 번역은 지원되지 않습니다."
        case let .failed(why): "번역 실패: \(why)"
        }
    }
}

/// Owns every translation engine and the translation cache. Shared by all regions.
actor TranslationService {
    private var settings: AppSettings
    private let cache = LRUCache<String, String>(capacity: 5000)
    private var appleSessions: [String: TranslationSession] = [:]
    private var pairStatus: [String: LanguageAvailability.Status] = [:]
    private let intelligence = IntelligenceTranslator()
    private var issueHandler: (@Sendable (TranslationIssue?) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func update(settings new: AppSettings) {
        let languagesChanged = new.sourceLanguage != settings.sourceLanguage || new.targetLanguage != settings.targetLanguage
        let glossaryChanged = new.glossary != settings.glossary
        settings = new
        if languagesChanged || glossaryChanged { cache.removeAll() }
        if languagesChanged { appleSessions.removeAll() }
    }

    func setIssueHandler(_ h: @escaping @Sendable (TranslationIssue?) -> Void) { issueHandler = h }

    /// Call after the user downloads a language pack.
    func invalidateAvailability() {
        pairStatus.removeAll()
        appleSessions.removeAll()
    }

    func prewarm() {
        intelligence.prewarm(settings: settings)
    }

    /// Best cached translation without doing any work. Quality results win over fast ones.
    func cached(_ text: String) -> String? {
        cache[key(text, tier: .quality)] ?? cache[key(text, tier: .fast)]
    }

    func hasQualityTranslation(_ text: String) -> Bool { cache[key(text, tier: .quality)] != nil }

    /// Translates `texts`, returning a dictionary of source → translation for those that succeeded.
    /// `onResult` fires as each translation lands (Apple Intelligence finishes short lines first), so callers can show them progressively.
    func translate(_ texts: [String], tier: TranslationTier,
                   onResult: (@Sendable (String, String) -> Void)? = nil) async -> [String: String] {
        var result: [String: String] = [:]
        var todo: [String] = []
        for t in Set(texts) {
            if let hit = cache[key(t, tier: tier)] ?? (tier == .fast ? cache[key(t, tier: .quality)] : nil) {
                result[t] = hit
                onResult?(t, hit)
            } else {
                todo.append(t)
            }
        }
        guard !todo.isEmpty else { return result }

        let target = Locale.Language(identifier: settings.targetLanguage)
        // Group by source language so each Apple Translation session handles one pair.
        var groups: [String: [String]] = [:]
        for t in todo { groups[sourceLanguage(for: t), default: []].append(t) }

        for (source, items) in groups {
            do {
                let translated = try await translateGroup(items, source: source, target: target, tier: tier) { s, t in
                    onResult?(s, t)
                }
                for (s, t) in translated {
                    result[s] = t
                    cache[key(s, tier: tier)] = t
                }
                issueHandler?(nil)
            } catch let issue as TranslationIssue {
                issueHandler?(issue)
            } catch {
                issueHandler?(.failed(error.localizedDescription))
            }
        }
        return result
    }

    // MARK: - Engines

    private func translateGroup(_ items: [String], source: String, target: Locale.Language, tier: TranslationTier,
                                onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        let targetID = settings.targetLanguage
        let wantsIntelligence: Bool = switch settings.engine {
        case .appleIntelligence: true
        case .appleTranslation: false
        case .auto: tier == .quality
        }

        if wantsIntelligence, intelligence.isAvailable {
            do {
                return try await intelligence.translate(items, source: source == "und" ? nil : source, target: targetID,
                                                        glossary: settings.glossaryPairs, onResult: onResult)
            } catch {
                // Guardrails or an unsupported language: fall through to Apple Translation when we can.
                if settings.engine == .appleIntelligence, try await appleTranslationStatus(source: source) != .installed {
                    throw TranslationIssue.failed(error.localizedDescription)
                }
            }
        }

        switch try await appleTranslationStatus(source: source) {
        case .installed:
            let out = try await appleTranslate(items, source: source, target: target)
            for (s, t) in out { onResult(s, t) }
            return out
        case .supported:
            // No pack yet. Apple Intelligence can still cover this pair in auto mode.
            if settings.engine != .appleTranslation, intelligence.isAvailable {
                return try await intelligence.translate(items, source: source == "und" ? nil : source, target: targetID,
                                                        glossary: settings.glossaryPairs, onResult: onResult)
            }
            throw TranslationIssue.languagePackMissing(source: source, target: targetID)
        default:
            if intelligence.isAvailable {
                return try await intelligence.translate(items, source: nil, target: targetID,
                                                        glossary: settings.glossaryPairs, onResult: onResult)
            }
            if let why = intelligence.unavailableReason { throw TranslationIssue.intelligenceUnavailable(why) }
            throw TranslationIssue.unsupportedPair(source: source, target: targetID)
        }
    }

    private func appleTranslationStatus(source: String) async throws -> LanguageAvailability.Status {
        guard source != "und" else { return .unsupported }
        let pair = "\(source)>\(settings.targetLanguage)"
        if let s = pairStatus[pair] { return s }
        let s = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                     to: Locale.Language(identifier: settings.targetLanguage))
        pairStatus[pair] = s
        return s
    }

    private func appleTranslate(_ items: [String], source: String, target: Locale.Language) async throws -> [String: String] {
        let pair = "\(source)>\(settings.targetLanguage)"
        let session = appleSessions[pair] ?? TranslationSession(installedSource: Locale.Language(identifier: source), target: target)
        appleSessions[pair] = session
        let requests = items.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses = try await session.translations(from: requests)
        var out: [String: String] = [:]
        for r in responses {
            guard let id = r.clientIdentifier, let i = Int(id), i < items.count else { continue }
            out[items[i]] = applyGlossary(r.targetText, source: items[i])
        }
        return out
    }

    /// Apple Translation has no glossary; enforce entries whose source term survived untranslated.
    private func applyGlossary(_ translated: String, source: String) -> String {
        var t = translated
        for (s, d) in settings.glossaryPairs where source.contains(s) {
            t = t.replacingOccurrences(of: s, with: d)
        }
        return t
    }

    // MARK: - Helpers

    private func key(_ text: String, tier: TranslationTier) -> String {
        "\(tier == .quality ? "q" : "f")|\(settings.targetLanguage)|\(text)"
    }

    /// The configured source language, or the dominant language of `text` when set to auto ("und" if unsure).
    func sourceLanguage(for text: String) -> String {
        if settings.sourceLanguage != "auto" { return settings.sourceLanguage }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage else { return "und" }
        switch lang {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .undetermined: return "und"
        default: return lang.rawValue
        }
    }
}

/// On-device Apple Intelligence (Foundation Models) translator: natural phrasing, glossary-aware.
final class IntelligenceTranslator: @unchecked Sendable {
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private let maxConcurrent = 4

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    var unavailableReason: String? {
        guard case let .unavailable(reason) = model.availability else { return nil }
        return switch reason {
        case .appleIntelligenceNotEnabled: "시스템 설정에서 Apple Intelligence를 켜 주세요"
        case .deviceNotEligible: "이 기기는 Apple Intelligence를 지원하지 않습니다"
        case .modelNotReady: "모델을 내려받는 중입니다"
        @unknown default: "알 수 없는 이유"
        }
    }

    func supports(_ language: String) -> Bool {
        model.supportedLanguages.contains { $0.languageCode == Locale.Language(identifier: language).languageCode }
    }

    func prewarm(settings: AppSettings) {
        guard isAvailable else { return }
        session(source: nil, target: settings.targetLanguage, glossary: settings.glossaryPairs).prewarm()
    }

    /// One request per line, a few at a time: decode speed is the bottleneck, so a batch costs about as
    /// much as its lines run separately, while separate requests let short lines land first.
    func translate(_ items: [String], source: String?, target: String, glossary: [(String, String)],
                   onResult: (@Sendable (String, String) -> Void)? = nil) async throws -> [String: String] {
        var out: [String: String] = [:]
        var firstError: Error?
        // Shortest first: they finish fastest and fill the screen quickly.
        var queue = items.sorted { $0.count < $1.count }[...]
        try await withThrowingTaskGroup(of: (String, String?, Error?).self) { group in
            func launch() {
                guard let src = queue.popFirst() else { return }
                group.addTask {
                    do {
                        let r = try await self.session(source: source, target: target, glossary: glossary)
                            .respond(to: src, options: GenerationOptions(sampling: .greedy))
                        return (src, Self.clean(r.content, source: src), nil)
                    } catch {
                        return (src, nil, error)
                    }
                }
            }
            for _ in 0..<maxConcurrent { launch() }
            while let (src, translated, error) = try await group.next() {
                if let translated {
                    out[src] = translated
                    onResult?(src, translated)
                } else if firstError == nil {
                    firstError = error
                }
                launch()
            }
        }
        if out.isEmpty, let firstError { throw firstError }
        return out
    }

    /// Strips wrapping quotes or a leading label the model sometimes adds.
    static func clean(_ s: String, source: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("「", "」"), ("“", "”")] where t.hasPrefix(open) && t.hasSuffix(close) && t.count > 2
            && !(source.hasPrefix(open) && source.hasSuffix(close)) {
            t = String(t.dropFirst().dropLast())
        }
        if !source.contains("\n") { t = t.components(separatedBy: .newlines).first ?? t }
        return t
    }

    private func session(source: String?, target: String, glossary: [(String, String)]) -> LanguageModelSession {
        let en = Locale(identifier: "en")
        let targetName = en.localizedString(forIdentifier: target) ?? target
        let sourceName = source.flatMap { en.localizedString(forIdentifier: $0) } ?? "the source language"
        var instructions = """
        You translate text captured from a computer screen — apps, games, web pages, comics, video subtitles — \
        from \(sourceName) into natural, fluent \(targetName).
        Rules:
        - Reply with the translation only: no quotes, labels, explanations, romanization or notes.
        - Keep it about as short as the original; it replaces UI labels and captions in place. Match the original's register.
        - Keep numbers, units, names, product names, keyboard shortcuts and placeholders like %@ or {0} unchanged.
        """
        if !glossary.isEmpty {
            instructions += "\nGlossary — always use these translations:\n"
            instructions += glossary.map { "- \($0.0) → \($0.1)" }.joined(separator: "\n")
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }


}
