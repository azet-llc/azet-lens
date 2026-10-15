/// What we learned about one line of text sitting on its background.
public struct TextAppearance: Sendable, Equatable {
    public var textColor: RGBA
    public var backgroundColor: RGBA
    /// Standard deviation of border luma. Low = flat background.
    public var backgroundNoise: Double
    /// Fraction of the text rect classified as glyph pixels.
    public var coverage: Double

    public var isFlatBackground: Bool { backgroundNoise < 6 }

    public init(textColor: RGBA, backgroundColor: RGBA, backgroundNoise: Double, coverage: Double) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundNoise = backgroundNoise
        self.coverage = coverage
    }
}

public struct TextMask: Sendable {
    public let width: Int
    public let height: Int
    /// 1 = glyph (to erase), 0 = background.
    public var bits: [UInt8]
    public var appearance: TextAppearance

    public var count: Int { bits.reduce(0) { $0 + Int($1) } }
}

public enum TextEraser {
    /// Builds a glyph mask for `patch`, where `textRect` (patch coordinates) bounds the text and the ring of
    /// pixels outside it is background. Glyph pixels are the Otsu class whose luma lies farther from the
    /// border's luma; the mask is then dilated by `dilation` px to swallow anti-aliased edges.
    public static func mask(for patch: RGBAImage, textRect: PixelRect, dilation: Int) -> TextMask {
        let w = patch.width, h = patch.height
        let inner = textRect.clamped(width: w, height: h)

        // Background statistics from pixels outside the text rect (falls back to the patch edge).
        var border: [RGBA] = []
        for y in 0..<h {
            for x in 0..<w where !(x >= inner.x && x < inner.x + inner.width && y >= inner.y && y < inner.y + inner.height) {
                border.append(patch.color(x: x, y: y))
            }
        }
        if border.isEmpty {
            for x in 0..<w { border.append(patch.color(x: x, y: 0)); border.append(patch.color(x: x, y: h - 1)) }
        }
        let bg = meanColor(border)
        let noise = stddev(border.map { Double($0.luma) })

        // Otsu over the inner rect's luma.
        var hist = [Int](repeating: 0, count: 256)
        for y in inner.y..<(inner.y + inner.height) { for x in inner.x..<(inner.x + inner.width) { hist[patch.luma(x: x, y: y)] += 1 } }
        let t = otsuThreshold(hist)
        let darkGlyphs = bg.luma > t // background on the bright side → glyphs are the dark class
        let minContrast = max(12, Int(noise * 2))

        var bits = [UInt8](repeating: 0, count: w * h)
        var glyphColors: [(RGBA, Int)] = []
        for y in inner.y..<(inner.y + inner.height) {
            for x in inner.x..<(inner.x + inner.width) {
                let l = patch.luma(x: x, y: y)
                let isGlyphClass = darkGlyphs ? l <= t : l > t
                let contrast = abs(l - bg.luma)
                if isGlyphClass && contrast >= minContrast {
                    bits[y * w + x] = 1
                    glyphColors.append((patch.color(x: x, y: y), contrast))
                }
            }
        }

        let innerArea = max(1, inner.width * inner.height)
        var coverage = Double(glyphColors.count) / Double(innerArea)
        // Thresholding failed (textured or low-contrast background): erase the whole text rect instead.
        if coverage > 0.6 || glyphColors.isEmpty {
            for y in inner.y..<(inner.y + inner.height) { for x in inner.x..<(inner.x + inner.width) { bits[y * w + x] = 1 } }
            coverage = 1
        }

        // Text color from the most contrasting half of glyph pixels — edge pixels are blended with the background.
        let textColor: RGBA
        if glyphColors.isEmpty {
            textColor = bg.luma > 128 ? RGBA(0, 0, 0) : RGBA(255, 255, 255)
        } else {
            let core = glyphColors.sorted { $0.1 > $1.1 }.prefix(max(1, glyphColors.count / 2)).map(\.0)
            textColor = meanColor(Array(core))
        }

        var m = TextMask(width: w, height: h, bits: bits,
                         appearance: TextAppearance(textColor: textColor, backgroundColor: bg, backgroundNoise: noise, coverage: coverage))
        m.bits = dilate(m.bits, width: w, height: h, radius: dilation)
        return m
    }

    /// Fills masked pixels from their surroundings: onion-peel propagation (each ring takes the mean of its
    /// already-known 8-neighbours), then Jacobi smoothing so gradients continue through the hole.
    public static func fill(_ img: inout RGBAImage, mask: [UInt8], smoothing: Int = 12) {
        let w = img.width, h = img.height
        precondition(mask.count == w * h)
        var known = mask.map { $0 == 0 }
        guard known.contains(true) else { return }
        var pending = (0..<(w * h)).filter { !known[$0] }
        let holes = pending
        var px = img.pixels.map { Int($0) }

        while !pending.isEmpty {
            var ring: [(i: Int, r: Int, g: Int, b: Int, a: Int)] = []
            var rest: [Int] = []
            for i in pending {
                let x = i % w, y = i / w
                var r = 0, g = 0, b = 0, a = 0, n = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                        let j = (ny * w + nx) * 4
                        r += px[j]; g += px[j + 1]; b += px[j + 2]; a += px[j + 3]
                        n += 1
                    }
                }
                if n > 0 { ring.append((i, r / n, g / n, b / n, a / n)) } else { rest.append(i) }
            }
            if ring.isEmpty { break } // unreachable while at least one pixel is known; guards against a hang
            for c in ring {
                px[c.i * 4] = c.r; px[c.i * 4 + 1] = c.g; px[c.i * 4 + 2] = c.b; px[c.i * 4 + 3] = c.a
                known[c.i] = true
            }
            pending = rest
        }

        for _ in 0..<smoothing {
            var next = px
            for i in holes {
                let x = i % w, y = i / w
                for c in 0..<4 {
                    var sum = 0, n = 0
                    if x > 0 { sum += px[(i - 1) * 4 + c]; n += 1 }
                    if x < w - 1 { sum += px[(i + 1) * 4 + c]; n += 1 }
                    if y > 0 { sum += px[(i - w) * 4 + c]; n += 1 }
                    if y < h - 1 { sum += px[(i + w) * 4 + c]; n += 1 }
                    next[i * 4 + c] = sum / max(n, 1)
                }
            }
            px = next
        }
        img.pixels = px.map { UInt8(clamping: $0) }
    }

    public static func otsuThreshold(_ hist: [Int]) -> Int {
        let total = hist.reduce(0, +)
        guard total > 0 else { return 127 }
        let sumAll = hist.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 127
        for t in 0..<256 {
            wB += hist[t]
            guard wB > 0 else { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return threshold
    }

    public static func dilate(_ bits: [UInt8], width w: Int, height h: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return bits }
        // Separable square dilation: horizontal pass then vertical pass.
        var tmp = [UInt8](repeating: 0, count: bits.count)
        for y in 0..<h {
            for x in 0..<w where bits[y * w + x] != 0 {
                for nx in max(0, x - radius)...min(w - 1, x + radius) { tmp[y * w + nx] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: bits.count)
        for y in 0..<h {
            for x in 0..<w where tmp[y * w + x] != 0 {
                for ny in max(0, y - radius)...min(h - 1, y + radius) { out[ny * w + x] = 1 }
            }
        }
        return out
    }

    static func meanColor(_ cs: [RGBA]) -> RGBA {
        guard !cs.isEmpty else { return RGBA(255, 255, 255) }
        var r = 0, g = 0, b = 0, a = 0
        for c in cs { r += Int(c.r); g += Int(c.g); b += Int(c.b); a += Int(c.a) }
        let n = cs.count
        return RGBA(UInt8(r / n), UInt8(g / n), UInt8(b / n), UInt8(a / n))
    }

    static func stddev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = xs.reduce(0, +) / Double(xs.count)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
    }
}
