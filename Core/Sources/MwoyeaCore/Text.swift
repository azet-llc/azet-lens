import CoreGraphics
import CoreText
import Foundation

public enum TextSimilarity {
    /// Levenshtein distance over Characters (grapheme clusters, so Hangul/emoji count as one).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 1 = identical, 0 = nothing in common.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let n = max(a.count, b.count)
        return n == 0 ? 1 : 1 - Double(editDistance(a, b)) / Double(n)
    }

    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return Double(inter / (a.width * a.height + b.width * b.height - inter))
    }
}

/// Matches text boxes between two OCR passes so the same on-screen line keeps its identity
/// (its translation and overlay layer) despite OCR jitter in box position and text.
public enum BlockMatcher {
    public struct Item: Sendable {
        public var rect: CGRect
        public var text: String
        public init(rect: CGRect, text: String) { self.rect = rect; self.text = text }
    }

    /// For each element of `new`, the index of its partner in `old`, or nil. Greedy on a combined score,
    /// each old item used at most once. A pair qualifies when boxes overlap well, or overlap somewhat
    /// and the texts are close.
    public static func match(old: [Item], new: [Item]) -> [Int?] {
        var candidates: [(score: Double, n: Int, o: Int)] = []
        for (ni, n) in new.enumerated() {
            for (oi, o) in old.enumerated() {
                let iou = TextSimilarity.iou(n.rect, o.rect)
                guard iou > 0.2 else { continue }
                let sim = TextSimilarity.similarity(n.text, o.text)
                guard iou >= 0.6 || sim >= 0.6 else { continue }
                candidates.append((iou + sim, ni, oi))
            }
        }
        candidates.sort { $0.score > $1.score }
        var result = [Int?](repeating: nil, count: new.count)
        var usedOld = Set<Int>()
        for c in candidates where result[c.n] == nil && !usedOld.contains(c.o) {
            result[c.n] = c.o
            usedOld.insert(c.o)
        }
        return result
    }
}

/// Fixed-capacity least-recently-used cache. Not thread-safe; own it from one actor.
public final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }

    public let capacity: Int
    private var map: [Key: Node] = [:]
    private var head: Node? // most recent
    private var tail: Node? // least recent

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { map.count }

    public subscript(key: Key) -> Value? {
        get {
            guard let node = map[key] else { return nil }
            moveToFront(node)
            return node.value
        }
        set {
            if let value = newValue { insert(key, value) } else { remove(key) }
        }
    }

    public func removeAll() {
        map.removeAll()
        head = nil
        tail = nil
    }

    private func insert(_ key: Key, _ value: Value) {
        if let node = map[key] {
            node.value = value
            moveToFront(node)
            return
        }
        let node = Node(key: key, value: value)
        map[key] = node
        pushFront(node)
        if map.count > capacity, let lru = tail {
            unlink(lru)
            map[lru.key] = nil
        }
    }

    private func remove(_ key: Key) {
        guard let node = map.removeValue(forKey: key) else { return }
        unlink(node)
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        pushFront(node)
    }

    private func pushFront(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }
}

public enum TextFitter {
    /// Largest font size in [minSize, maxSize] (0.5pt resolution) whose laid-out text fits `box`.
    /// Returns minSize when nothing fits — the caller decides whether to overflow or shrink the box.
    public static func fitFontSize(in box: CGSize, minSize: CGFloat, maxSize: CGFloat, measure: (CGFloat) -> CGSize) -> CGFloat {
        guard maxSize > minSize else { return minSize }
        func fits(_ s: CGFloat) -> Bool {
            let m = measure(s)
            return m.width <= box.width + 0.5 && m.height <= box.height + 0.5
        }
        if fits(maxSize) { return maxSize }
        var lo = minSize, hi = maxSize
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Size CoreText needs to lay out `string` wrapped at `width`.
    public static func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    }
}

public enum TranslationCleanup {
    /// Models asked to translate a numbered list often echo the numbering ("3. 게임 종료"). Strip it,
    /// but only when the source line did not itself start with that number.
    public static func stripEchoedNumbering(_ translated: String, index: Int, source: String) -> String {
        let marker = "\(index)"
        let trimmedSource = source.trimmingCharacters(in: .whitespaces)
        guard !trimmedSource.hasPrefix(marker) else { return translated }
        let t = translated.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(marker) else { return translated }
        var rest = t.dropFirst(marker.count)
        guard let sep = rest.first, ".)：:、".contains(sep) else { return translated }
        rest = rest.dropFirst()
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
