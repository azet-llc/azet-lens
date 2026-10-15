import CoreGraphics

/// Which tiles of a frame changed relative to a reference frame.
public struct ChangeMap: Sendable, Equatable {
    public let tile: Int
    public let columns: Int
    public let rows: Int
    public let changed: [Bool]
    /// Size of the gray images that were compared.
    public let imageWidth: Int
    public let imageHeight: Int

    public var changedCount: Int { changed.lazy.filter { $0 }.count }
    public var ratio: Double { changed.isEmpty ? 0 : Double(changedCount) / Double(changed.count) }
    public var isUnchanged: Bool { !changed.contains(true) }

    /// Bounding box of all changed tiles, in gray-image pixels. nil when nothing changed.
    public var dirtyRect: PixelRect? {
        var minC = Int.max, minR = Int.max, maxC = -1, maxR = -1
        for r in 0..<rows {
            for c in 0..<columns where changed[r * columns + c] {
                minC = min(minC, c); maxC = max(maxC, c)
                minR = min(minR, r); maxR = max(maxR, r)
            }
        }
        guard maxC >= 0 else { return nil }
        return PixelRect(x: minC * tile, y: minR * tile, width: (maxC - minC + 1) * tile, height: (maxR - minR + 1) * tile)
            .clamped(width: imageWidth, height: imageHeight)
    }

    /// True if any changed tile overlaps `rect` (gray-image pixels).
    public func intersects(_ rect: PixelRect) -> Bool {
        let r = rect.clamped(width: imageWidth, height: imageHeight)
        guard !r.isEmpty else { return false }
        let c0 = r.x / tile, c1 = min(columns - 1, (r.x + r.width - 1) / tile)
        let r0 = r.y / tile, r1 = min(rows - 1, (r.y + r.height - 1) / tile)
        for row in r0...r1 { for col in c0...c1 where changed[row * columns + col] { return true } }
        return false
    }

    public static func allChanged(width: Int, height: Int, tile: Int) -> ChangeMap {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        return ChangeMap(tile: tile, columns: cols, rows: rows, changed: Array(repeating: true, count: cols * rows),
                         imageWidth: width, imageHeight: height)
    }
}

public enum FrameDiff {
    /// A tile counts as changed when at least `minPixels` of its pixels moved by more than `delta` luma levels.
    /// Counting strong pixel changes (instead of averaging) keeps a single edited glyph from being diluted
    /// by the rest of the tile, while ignoring dithering/compression noise.
    public static func changeMap(from a: GrayImage, to b: GrayImage, tile: Int = 16, delta: Int = 24, minPixels: Int = 2) -> ChangeMap {
        guard a.width == b.width, a.height == b.height else {
            return .allChanged(width: b.width, height: b.height, tile: tile)
        }
        let cols = (b.width + tile - 1) / tile, rows = (b.height + tile - 1) / tile
        var counts = [Int](repeating: 0, count: cols * rows)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in 0..<b.height {
                    let rowBase = (y / tile) * cols
                    let o = y * b.width
                    for x in 0..<b.width where abs(Int(pa[o + x]) - Int(pb[o + x])) > delta {
                        counts[rowBase + x / tile] += 1
                    }
                }
            }
        }
        return ChangeMap(tile: tile, columns: cols, rows: rows, changed: counts.map { $0 >= minPixels },
                         imageWidth: b.width, imageHeight: b.height)
    }

    /// Detects a pure vertical scroll: content of `a` shifted by `dy` pixels appears in `b`
    /// (positive dy = content moved down). Returns nil when no shift explains the change clearly better than no shift.
    public static func verticalShift(from a: GrayImage, to b: GrayImage, maxShift: Int) -> Int? {
        guard a.width == b.width, a.height == b.height, a.height > 8 else { return nil }
        let maxShift = min(maxShift, a.height / 2)
        let base = meanAbsDiff(a, b, dy: 0)
        guard base > 0.5 else { return nil }
        var best = (dy: 0, err: base)
        for dy in -maxShift...maxShift where dy != 0 {
            let e = meanAbsDiff(a, b, dy: dy)
            if e < best.err { best = (dy, e) }
        }
        // Must explain the change much better than "nothing moved", and match well in absolute terms.
        guard best.dy != 0, best.err < base * 0.35, best.err < 3.0 else { return nil }
        return best.dy
    }

    /// Mean |a(x, y) - b(x, y + dy)| over the overlapping rows, sampling every other column.
    static func meanAbsDiff(_ a: GrayImage, _ b: GrayImage, dy: Int) -> Double {
        let y0 = max(0, -dy), y1 = min(a.height, b.height - dy)
        guard y1 > y0 else { return .infinity }
        var sum = 0, n = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in y0..<y1 {
                    let oa = y * a.width, ob = (y + dy) * b.width
                    var x = 0
                    while x < a.width {
                        sum += abs(Int(pa[oa + x]) - Int(pb[ob + x]))
                        x += 2
                    }
                    n += (a.width + 1) / 2
                }
            }
        }
        return Double(sum) / Double(max(n, 1))
    }
}

/// Turns fractional moves into whole-pixel steps without losing the remainder, so many tiny moves
/// (a slow drag) add up to exactly the same shift as one big move.
public struct ShiftAccumulator: Sendable {
    private var remainder: CGFloat = 0
    public init() {}

    /// Adds `delta` and returns the whole steps to apply now.
    public mutating func add(_ delta: CGFloat) -> Int {
        remainder += delta
        // Nudge by an epsilon so 20 × 0.3 counts as 6, not 5.999….
        let whole = (remainder + (remainder >= 0 ? 1e-9 : -1e-9)).rounded(.towardZero)
        remainder -= whole
        return Int(whole)
    }

    public mutating func reset() { remainder = 0 }
}
