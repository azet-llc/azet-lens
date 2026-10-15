import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import MwoyeoCore

/// Deterministic texture so scroll matching has something to lock onto.
func texture(width: Int, height: Int, seed: Int = 1) -> GrayImage {
    var g = GrayImage(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            g[x, y] = UInt8(truncatingIfNeeded: (x * 7 + y * y * 13 + seed * 31 + (x * y) % 17) & 0xFF)
        }
    }
    return g
}

@Suite struct FrameDiffTests {
    @Test func identicalFramesAreUnchanged() {
        let a = texture(width: 64, height: 48)
        let m = FrameDiff.changeMap(from: a, to: a, tile: 16)
        #expect(m.isUnchanged)
        #expect(m.dirtyRect == nil)
        #expect(m.columns == 4 && m.rows == 3)
    }

    @Test func smallEditFlagsOnlyItsTile() {
        let a = GrayImage(width: 64, height: 48, fill: 200)
        var b = a
        for y in 20..<23 { for x in 36..<39 { b[x, y] = 20 } } // a 3×3 "glyph" inside tile (2, 1)
        let m = FrameDiff.changeMap(from: a, to: b, tile: 16)
        #expect(m.changedCount == 1)
        #expect(m.changed[1 * 4 + 2])
        #expect(m.dirtyRect == PixelRect(x: 32, y: 16, width: 16, height: 16))
        #expect(m.intersects(PixelRect(x: 40, y: 0, width: 4, height: 48)))
        #expect(!m.intersects(PixelRect(x: 0, y: 0, width: 30, height: 48)))
    }

    @Test func noiseBelowDeltaIsIgnored() {
        let a = GrayImage(width: 32, height: 32, fill: 100)
        var b = a
        for i in stride(from: 0, to: b.pixels.count, by: 3) { b.pixels[i] = 110 }
        #expect(FrameDiff.changeMap(from: a, to: b).isUnchanged)
    }

    @Test func sizeChangeMeansEverythingChanged() {
        let m = FrameDiff.changeMap(from: GrayImage(width: 10, height: 10), to: GrayImage(width: 20, height: 20), tile: 8)
        #expect(m.ratio == 1)
    }

    @Test(arguments: [7, -5, 1, 23])
    func detectsVerticalScroll(dy: Int) {
        let tall = texture(width: 80, height: 200)
        // Window of 120 rows at offset 40; scrolling the page moves the window by -dy.
        func window(at top: Int) -> GrayImage {
            GrayImage(width: 80, height: 120, pixels: Array(tall.pixels[(top * 80)..<((top + 120) * 80)]))
        }
        let a = window(at: 40), b = window(at: 40 - dy)
        #expect(FrameDiff.verticalShift(from: a, to: b, maxShift: 30) == dy)
    }

    @Test func shiftedImageMatchesScrolledFrame() {
        let tall = texture(width: 40, height: 100)
        let a = GrayImage(width: 40, height: 60, pixels: Array(tall.pixels[(20 * 40)..<(80 * 40)]))
        let b = GrayImage(width: 40, height: 60, pixels: Array(tall.pixels[(10 * 40)..<(70 * 40)])) // content moved down 10
        let shifted = a.shifted(dx: 0, dy: 10)
        #expect(Array(shifted.pixels[(10 * 40)...]) == Array(b.pixels[(10 * 40)...]))
        #expect(shifted.pixels[0..<(10 * 40)].allSatisfy { $0 == 0 })
        #expect(a.shifted(dx: 0, dy: -60).pixels.allSatisfy { $0 == 0 })
        #expect(a.vacatedStrips(dx: 0, dy: 10) == [PixelRect(x: 0, y: 0, width: 40, height: 10)])
    }

    @Test func shiftsInTwoDimensions() {
        var a = GrayImage(width: 5, height: 4)
        for y in 0..<4 { for x in 0..<5 { a[x, y] = UInt8(10 * y + x + 1) } }
        let s = a.shifted(dx: -2, dy: 1, fill: 0)
        // Row 0 vacated; row 1 holds old row 0 moved 2 left; last 2 columns vacated.
        #expect(Array(s.pixels[0..<5]) == [0, 0, 0, 0, 0])
        #expect(Array(s.pixels[5..<10]) == [3, 4, 5, 0, 0])
        #expect(Array(s.pixels[15..<20]) == [23, 24, 25, 0, 0])
        #expect(Set(a.vacatedStrips(dx: -2, dy: 1)) == [PixelRect(x: 0, y: 0, width: 5, height: 1), PixelRect(x: 3, y: 1, width: 2, height: 3)])
    }

    @Test func reframesIntoLargerCanvas() {
        var a = GrayImage(width: 3, height: 2)
        for y in 0..<2 { for x in 0..<3 { a[x, y] = UInt8(10 * y + x + 1) } }
        // Capture grew by 1 px on every side: old content sits at (1, 1) of a 5×4 canvas.
        let r = a.reframed(dx: 1, dy: 1, width: 5, height: 4)
        #expect(Array(r.pixels[5..<10]) == [0, 1, 2, 3, 0])
        #expect(Array(r.pixels[10..<15]) == [0, 11, 12, 13, 0])
        let ring = a.uncovered(dx: 1, dy: 1, width: 5, height: 4)
        #expect(ring.reduce(0) { $0 + $1.width * $1.height } == 5 * 4 - 3 * 2)
        #expect(a.uncovered(dx: 9, dy: 0, width: 5, height: 4) == [PixelRect(x: 0, y: 0, width: 5, height: 4)])
        // Shrinking leaves nothing uncovered.
        #expect(a.uncovered(dx: -1, dy: 0, width: 2, height: 2).isEmpty)
    }

    @Test func unrelatedChangeIsNotAScroll() {
        let a = texture(width: 80, height: 100, seed: 1)
        let b = texture(width: 80, height: 100, seed: 9)
        #expect(FrameDiff.verticalShift(from: a, to: b, maxShift: 20) == nil)
        #expect(FrameDiff.verticalShift(from: a, to: a, maxShift: 20) == nil)
    }

    @Test func accumulatorKeepsFractionalMoves() {
        var a = ShiftAccumulator()
        var total = 0
        for _ in 0..<20 { total += a.add(0.3) }
        #expect(total == 6)
        var b = ShiftAccumulator()
        var back = 0
        for _ in 0..<10 { back += b.add(-0.45) }
        #expect(back == -4) // -4.5 → 4 whole steps applied, -0.5 pending
        #expect(b.add(-0.5) == -1)
    }

    @Test func downsamplesBGRA() {
        // 4×2 BGRA: left 2×2 block white, right 2×2 block black → 2×1 gray at step 2.
        var bytes = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for y in 0..<2 { for x in 0..<2 { for c in 0..<3 { bytes[(y * 4 + x) * 4 + c] = 255 } } }
        let g = bytes.withUnsafeBytes { GrayImage(bgra: $0.baseAddress!, width: 4, height: 2, bytesPerRow: 16, step: 2) }
        #expect(g.width == 2 && g.height == 1)
        #expect(g.pixels[0] >= 254 && g.pixels[1] == 0)
    }
}

@Suite struct TextEraseTests {
    let bg = RGBA(200, 220, 240)
    let ink = RGBA(30, 20, 60)

    /// 60×20 patch with a 4 px background ring; "glyphs" are vertical bars inside the text rect.
    func glyphPatch(background: RGBA, ink: RGBA) -> RGBAImage {
        var img = RGBAImage(width: 60, height: 20, color: background)
        for x in stride(from: 6, to: 54, by: 6) { for y in 6..<14 { img.set(x: x, y: y, ink); img.set(x: x + 1, y: y, ink) } }
        return img
    }

    @Test func otsuSplitsBimodalHistogram() {
        var h = [Int](repeating: 0, count: 256)
        h[40] = 100; h[42] = 50; h[200] = 300; h[205] = 80
        let t = TextEraser.otsuThreshold(h)
        #expect(t >= 42 && t < 200)
    }

    @Test func masksDarkGlyphsOnLightBackground() {
        let patch = glyphPatch(background: bg, ink: ink)
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 0)
        #expect(m.count == 8 * 2 * 8)
        #expect(m.bits[6 * 60 + 6] == 1 && m.bits[6 * 60 + 9] == 0)
        #expect(m.appearance.textColor == ink)
        #expect(m.appearance.backgroundColor == bg)
        #expect(m.appearance.isFlatBackground)
    }

    @Test func masksLightGlyphsOnDarkBackground() {
        let patch = glyphPatch(background: RGBA(20, 20, 30), ink: RGBA(250, 250, 250))
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 1)
        #expect(m.appearance.textColor == RGBA(250, 250, 250))
        // Dilation by 1 turns each 2×8 bar into 4×10.
        #expect(m.count == 8 * 4 * 10)
    }

    @Test func ignoresBoxEdgesRunningOffThePatch() {
        // Glyph bars plus a dark box edge along the bottom ring that spans the whole patch width.
        var patch = glyphPatch(background: bg, ink: ink)
        for x in 0..<60 { for y in 17..<20 { patch.set(x: x, y: y, ink) } }
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 0)
        #expect(m.count == 8 * 2 * 8)           // only the bars
        #expect(m.bits[18 * 60 + 30] == 0)       // the edge survives
        #expect(m.glyphBounds == PixelRect(x: 6, y: 6, width: 44, height: 8))
        #expect(m.appearance.backgroundColor == bg) // median ignores the edge
        #expect(m.appearance.isFlatBackground)
    }

    @Test func fillsHolesEnclosedByTheMask() {
        // A 3×3 ring of mask with an unmasked centre, plus an open "C" whose inside reaches the border.
        var bits = [UInt8](repeating: 0, count: 8 * 5)
        for (x, y) in [(1, 1), (2, 1), (3, 1), (1, 2), (3, 2), (1, 3), (2, 3), (3, 3)] { bits[y * 8 + x] = 1 }
        for (x, y) in [(5, 1), (6, 1), (5, 2), (5, 3), (6, 3)] { bits[y * 8 + x] = 1 }
        TextEraser.fillEnclosedHoles(&bits, width: 8, height: 5)
        #expect(bits[2 * 8 + 2] == 1)   // enclosed → filled
        #expect(bits[2 * 8 + 6] == 0)   // open to the border → untouched
        #expect(bits.reduce(0) { $0 + Int($1) } == 14)
    }

    @Test func fillContinuesAGradientThroughTheHole() {
        var img = RGBAImage(width: 40, height: 20, color: RGBA(0, 0, 0))
        for y in 0..<20 { for x in 0..<40 { img.set(x: x, y: y, RGBA(UInt8(x * 5), 100, UInt8(y * 10))) } }
        let clean = img
        var mask = [UInt8](repeating: 0, count: 40 * 20)
        for y in 7..<13 { for x in 10..<30 { mask[y * 40 + x] = 1; img.set(x: x, y: y, RGBA(0, 0, 0)) } }
        TextEraser.fill(&img, mask: mask, smoothing: 40)
        var worst = 0.0
        for y in 7..<13 { for x in 10..<30 { worst = max(worst, img.color(x: x, y: y).distance(to: clean.color(x: x, y: y))) } }
        #expect(worst < 12, "max color error \(worst)")
        // Unmasked pixels untouched.
        #expect(img.color(x: 0, y: 0) == clean.color(x: 0, y: 0))
    }

    @Test func eraseThenFillRemovesGlyphs() {
        var patch = glyphPatch(background: bg, ink: ink)
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 1)
        TextEraser.fill(&patch, mask: m.bits)
        for y in 0..<20 { for x in 0..<60 { #expect(patch.color(x: x, y: y).distance(to: bg) < 2) } }
    }
}

@Suite struct TextTests {
    @Test func editDistance() {
        #expect(TextSimilarity.editDistance("kitten", "sitting") == 3)
        #expect(TextSimilarity.editDistance("", "abc") == 3)
        #expect(TextSimilarity.editDistance("게임종료", "게임 종료") == 1)
        #expect(TextSimilarity.similarity("設定", "設定") == 1)
    }

    @Test func iou() {
        #expect(TextSimilarity.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10)) == 1)
        #expect(abs(TextSimilarity.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 0, width: 10, height: 10)) - 1.0 / 3) < 1e-9)
        #expect(TextSimilarity.iou(CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 5, y: 5, width: 1, height: 1)) == 0)
    }

    @Test func matcherKeepsIdentityThroughJitter() {
        let old = [BlockMatcher.Item(rect: CGRect(x: 10, y: 10, width: 200, height: 20), text: "設定を保存しますか？"),
                   BlockMatcher.Item(rect: CGRect(x: 10, y: 50, width: 200, height: 20), text: "ゲームを終了する")]
        let new = [BlockMatcher.Item(rect: CGRect(x: 12, y: 52, width: 198, height: 21), text: "ゲームを終了する"),
                   BlockMatcher.Item(rect: CGRect(x: 11, y: 9, width: 201, height: 20), text: "設定を保存しますか"),
                   BlockMatcher.Item(rect: CGRect(x: 10, y: 300, width: 100, height: 20), text: "新しい")]
        #expect(BlockMatcher.match(old: old, new: new) == [1, 0, nil])
    }

    @Test func matcherUsesEachOldItemOnce() {
        let old = [BlockMatcher.Item(rect: CGRect(x: 0, y: 0, width: 100, height: 20), text: "abc")]
        let new = [BlockMatcher.Item(rect: CGRect(x: 0, y: 0, width: 100, height: 20), text: "abc"),
                   BlockMatcher.Item(rect: CGRect(x: 1, y: 0, width: 100, height: 20), text: "abc")]
        #expect(BlockMatcher.match(old: old, new: new) == [0, nil])
    }

    @Test func lruEvictsLeastRecentlyUsed() {
        let c = LRUCache<String, Int>(capacity: 2)
        c["a"] = 1; c["b"] = 2
        _ = c["a"]          // a is now most recent
        c["c"] = 3          // evicts b
        #expect(c["b"] == nil && c["a"] == 1 && c["c"] == 3 && c.count == 2)
        c["a"] = nil
        #expect(c.count == 1)
        c["d"] = 4; c["e"] = 5
        #expect(c["c"] == nil && c["d"] == 4 && c["e"] == 5)
    }

    @Test func fitFontSizeBinarySearch() {
        // Text 10 chars, each 0.6em wide, single line of 1.2em height.
        let size = TextFitter.fitFontSize(in: CGSize(width: 120, height: 40), minSize: 6, maxSize: 64) { s in
            CGSize(width: 6 * s, height: 1.2 * s)
        }
        #expect(size >= 19.5 && 6 * size <= 120.5)
        #expect(TextFitter.fitFontSize(in: CGSize(width: 1, height: 1), minSize: 6, maxSize: 64) { CGSize(width: $0, height: $0) } == 6)
        #expect(TextFitter.fitFontSize(in: CGSize(width: 999, height: 999), minSize: 6, maxSize: 64) { CGSize(width: $0, height: $0) } == 64)
    }

    @Test func coreTextWrapsWhenNarrow() {
        let s = NSAttributedString(string: "새로운 아이템을 획득했습니다! 공격력이 10 상승했습니다.",
                                   attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Apple SD Gothic Neo" as CFString, 20, nil)])
        let wide = TextFitter.measure(s, width: 2000), narrow = TextFitter.measure(s, width: 150)
        #expect(narrow.height > wide.height * 2)
        #expect(narrow.width <= 150)
    }

    @Test func stripsEchoedNumbering() {
        #expect(TranslationCleanup.stripEchoedNumbering("3. 게임을 종료합니다.", index: 3, source: "ゲームを終了する") == "게임을 종료합니다.")
        #expect(TranslationCleanup.stripEchoedNumbering("3) 장비", index: 3, source: "装備") == "장비")
        #expect(TranslationCleanup.stripEchoedNumbering("3. 장비", index: 3, source: "3. 装備") == "3. 장비")
        #expect(TranslationCleanup.stripEchoedNumbering("30개", index: 3, source: "30個") == "30개")
    }
}

@Suite struct OverscanTests {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func capturesAroundTheLensAndStaysOnScreen() {
        let lens = CGRect(x: 400, y: 300, width: 400, height: 200)
        let r = Overscan.rect(around: lens, wide: false, display: display)
        #expect(r == lens.insetBy(dx: -120, dy: -80))
        // Near the left edge the capture slides right instead of being cut.
        let edge = CGRect(x: 10, y: 300, width: 400, height: 200)
        let e = Overscan.rect(around: edge, wide: true, display: display)
        #expect(e.minX == 0 && e.width == 400 + 2 * 240)
    }

    @Test func lensMovesInsideTheCaptureUntilNearItsEdge() {
        let lens = CGRect(x: 500, y: 300, width: 400, height: 200)
        let capture = Overscan.rect(around: lens, wide: true, display: display)  // 240 × 200 pt margins
        func plan(dx: CGFloat) -> Overscan.Plan {
            Overscan.plan(lens: lens.offsetBy(dx: dx, dy: 0), capture: capture, wide: true, allowResize: false, display: display)
        }
        #expect(plan(dx: 140) == .keep)
        guard case .move(let r) = plan(dx: 150) else { Issue.record("expected a re-centre"); return }
        #expect(r.size == capture.size && r.midX == lens.midX + 150)
        // Calming down shrinks the margins, but only when resizing is allowed.
        #expect(Overscan.plan(lens: lens, capture: capture, wide: false, allowResize: false, display: display) == .keep)
        guard case .resize = Overscan.plan(lens: lens, capture: capture, wide: false, allowResize: true, display: display)
        else { Issue.record("expected a resize"); return }
    }
}

@Test func grayCropKeepsRows() {
    var a = GrayImage(width: 4, height: 3)
    for y in 0..<3 { for x in 0..<4 { a[x, y] = UInt8(10 * y + x) } }
    let c = a.cropped(to: PixelRect(x: 1, y: 1, width: 2, height: 2))
    #expect(c.pixels == [11, 12, 21, 22])
}

@Test func loneJamoBecomeCompatibilityLetters() {
    #expect(TranslationCleanup.standaloneJamo("\u{110F}\u{110F} RIP") == "ㅋㅋ RIP")
    // A leading consonant followed by a vowel is part of a syllable and stays.
    #expect(TranslationCleanup.standaloneJamo("\u{1100}\u{1161}") == "\u{1100}\u{1161}")
}

@Test func translationFilterKeepsWhatIsNotSourceText() {
    // Japanese page: only lines with Japanese in them are translated.
    #expect(TranslationFilter.needsTranslation("パッチ1.4でバグが直った", cjkSource: true))
    #expect(TranslationFilter.needsTranslation("318件", cjkSource: true))
    #expect(!TranslationFilter.needsTranslation("threadly", cjkSource: true))
    #expect(!TranslationFilter.needsTranslation("Starfall Valley", cjkSource: true))
    #expect(!TranslationFilter.needsTranslation("4 2.4k ▼", cjkSource: true))
    // English page: words are translated; handles, links and counters are not.
    #expect(TranslationFilter.needsTranslation("Is anyone doing the raid tonight?", cjkSource: false))
    #expect(TranslationFilter.needsTranslation("Share", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("2.4k", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("u/ollie_owl", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("@junpark", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("https://example.com/a", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("— 12 —", cjkSource: false))
}

@Test func restoresSourceTokenCase() {
    #expect(TranslationCleanup.restoreSourceTokens("S/starfallvalley 내 검색", source: "s/starfallvalley 内を検索") == "s/starfallvalley 내 검색")
    #expect(TranslationCleanup.restoreSourceTokens("U/mayafox · 5시간 전", source: "u/mayafox · 5時間前") == "u/mayafox · 5시간 전")
    #expect(TranslationCleanup.restoreSourceTokens("RTA 멤버들은", source: "RTA勢は") == "RTA 멤버들은")
}
