import CoreGraphics
import Foundation
import NaturalLanguage
import Vision
import os

/// One recognized line, in image pixels (top-left origin).
struct OCRLine: Sendable {
    var rect: CGRect
    var text: String
}

/// A paragraph: lines that read as one unit and should be translated together.
struct OCRBlock: Sendable {
    var rect: CGRect
    var lines: [OCRLine]
    var text: String
}

enum TextRecognizer {
    /// Per-line recognition, optionally restricted to `roi` (image pixels).
    /// `fast` only reads Latin scripts; callers pick it only for those.
    static func lines(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], fast: Bool,
                      customWords: [String] = []) async throws -> [OCRLine] {
        var req = RecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = !fast
        req.customWords = customWords
        if languages.isEmpty {
            req.automaticallyDetectsLanguage = true
        } else {
            req.recognitionLanguages = languages
        }
        let size = CGSize(width: image.width, height: image.height)
        let region = roi.map { normalized($0, in: size) } ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        req.regionOfInterest = region
        let observations = try await deadline { try await req.perform(on: image) }
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            // Boxes come back normalized to the region of interest, not the whole image.
            return OCRLine(rect: pixelRect(unclip(obs.boundingBox.cgRect, from: region), in: size), text: candidate.string)
        }
    }

    /// Paragraph-level recognition via the document recognizer, which groups lines into reading units.
    static func blocks(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], customWords: [String] = []) async throws -> [OCRBlock] {
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.customWords = customWords
        if languages.isEmpty {
            req.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            req.textRecognitionOptions.recognitionLanguages = languages
        }
        let size = CGSize(width: image.width, height: image.height)
        let region = roi.map { normalized($0, in: size) } ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        req.regionOfInterest = region
        let docs = try await deadline { try await req.perform(on: image) }
        var out: [OCRBlock] = []
        for doc in docs {
            for paragraph in doc.document.paragraphs {
                let lines = paragraph.lines.compactMap { obs -> OCRLine? in
                    guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
                    return OCRLine(rect: pixelRect(unclip(obs.boundingBox.cgRect, from: region), in: size), text: s)
                }
                guard !lines.isEmpty else { continue }
                out.append(makeBlock(lines))
            }
        }
        return out
    }

    struct Timeout: Error {}
    private static let warm = OSAllocatedUnfairLock(initialState: false)

    /// Vision requests occasionally never return (seen with the document recognizer after many runs). A stuck
    /// request must not stall the region forever: give up after `seconds` and let the caller fall back or retry.
    /// The abandoned request keeps running in the background; it cannot be cancelled.
    static func deadline<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        // Until one request has finished, the models are still loading (tens of seconds on a fresh install).
        let seconds: Double = warm.withLock { $0 } ? 8 : 90
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<T, Error>) -> Void = { r in
                if done.withLock({ was in defer { was = true }; return !was }) { cont.resume(with: r) }
            }
            Task {
                do {
                    let r = try await work()
                    warm.withLock { $0 = true }
                    finish(.success(r))
                } catch { finish(.failure(error)) }
            }
            Task { try? await Task.sleep(for: .seconds(seconds)); finish(.failure(Timeout())) }
        }
    }

    /// Lines → block, joining text the way the script expects (no spaces between CJK lines).
    static func makeBlock(_ lines: [OCRLine]) -> OCRBlock {
        let rect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
        var text = ""
        for line in lines {
            if let last = text.last, let first = line.text.first, !(isCJK(last) || isCJK(first)) {
                text += last == "-" ? "" : " "
            }
            text += line.text
        }
        return OCRBlock(rect: rect, lines: lines, text: text)
    }

    /// Text worth translating: has letters, and is not already in the target language.
    static func needsTranslation(_ text: String, target: String) -> Bool {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        let targetCode = Locale.Language(identifier: target).languageCode?.identifier
        // Hangul is unambiguous; for other targets ask NaturalLanguage, but only trust confident answers.
        if targetCode == "ko" {
            let hangul = text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            return Double(hangul) / Double(max(letters, 1)) < 0.5
        }
        let r = NLLanguageRecognizer()
        r.processString(text)
        if let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.8,
           Locale.Language(identifier: lang.rawValue).languageCode?.identifier == targetCode {
            return false
        }
        return true
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) ||
                (0xF900...0xFAFF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value) ||
                (0x3000...0x303F).contains(s.value)
        }
    }

    /// Region-of-interest-relative normalized box → image-relative normalized box.
    private static func unclip(_ b: CGRect, from region: NormalizedRect) -> CGRect {
        let r = region.cgRect
        return CGRect(x: r.minX + b.minX * r.width, y: r.minY + b.minY * r.height, width: b.width * r.width, height: b.height * r.height)
    }

    private static func pixelRect(_ n: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height, width: n.width * size.width, height: n.height * size.height)
    }

    private static func normalized(_ r: CGRect, in size: CGSize) -> NormalizedRect {
        let c = r.intersection(CGRect(origin: .zero, size: size))
        return NormalizedRect(x: c.minX / size.width, y: 1 - c.maxY / size.height,
                              width: c.width / size.width, height: c.height / size.height)
    }
}
