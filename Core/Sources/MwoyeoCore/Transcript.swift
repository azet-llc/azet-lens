import Foundation

/// What a lens showed, line by line, with when each line was on screen: kept in memory only (nothing is written
/// until the person saves it), and saved as SubRip subtitles or as plain text with the original under each line.
/// A line counts from the first snapshot that shows it until the first one that no longer does; the same text
/// shown again later (a subtitle that comes back) is a new line.
public struct Transcript: Sendable {
    public struct Line: Sendable, Equatable {
        public var source: String
        public var translation: String
        /// Seconds since the transcript began.
        public var start: TimeInterval
        public var end: TimeInterval
    }

    public private(set) var lines: [Line] = []
    public private(set) var began: Date?
    /// Source text → index in `lines` of the line on screen now.
    private var open: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }

    /// The (source, translation) pairs a lens shows at `now`.
    public mutating func observe(_ pairs: [(source: String, translation: String)], at now: Date) {
        let t = began.map { now.timeIntervalSince($0) } ?? 0
        if began == nil { began = now }
        var seen = Set<String>()
        for p in pairs {
            let s = p.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, seen.insert(s).inserted else { continue }
            if let i = open[s] {
                lines[i].end = t
                lines[i].translation = p.translation
            } else {
                open[s] = lines.count
                lines.append(Line(source: s, translation: p.translation, start: t, end: t))
            }
        }
        for (s, i) in open where !seen.contains(s) {
            lines[i].end = t
            open[s] = nil
        }
    }

    public mutating func clear() { self = Transcript() }

    /// SubRip subtitles of the translations. `now` closes the lines still on screen; every line lasts at least
    /// `minimum` seconds so a line seen in one snapshot still shows.
    public func srt(now: Date, minimum: TimeInterval = 1) -> String {
        closed(now: now).enumerated().map { n, l in
            "\(n + 1)\n\(Self.stamp(l.start)) --> \(Self.stamp(max(l.end, l.start + minimum)))\n\(l.translation)\n"
        }.joined(separator: "\n")
    }

    /// Plain text: the time, the translation and the original under it, one block per line.
    public func text(now: Date) -> String {
        closed(now: now).map { l in "[\(Self.stamp(l.start).prefix(8))] \(l.translation)\n          \(l.source)\n" }
            .joined(separator: "\n")
    }

    private func closed(now: Date) -> [Line] {
        let t = began.map { now.timeIntervalSince($0) } ?? 0
        var out = lines
        for i in open.values { out[i].end = t }
        return out
    }

    static func stamp(_ t: TimeInterval) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
