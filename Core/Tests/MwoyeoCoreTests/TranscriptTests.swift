import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct TranscriptTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func aLineLastsUntilItLeavesAndComesBackAsANewLine() {
        var t = Transcript()
        t.observe([("こんにちは", "안녕하세요")], at: t0)
        t.observe([("こんにちは", "안녕하세요"), ("またね", "또 봐")], at: t0 + 2)
        t.observe([("またね", "또 봐")], at: t0 + 3.5)
        t.observe([], at: t0 + 5)
        t.observe([("こんにちは", "안녕하세요")], at: t0 + 6)
        #expect(t.lines.map(\.source) == ["こんにちは", "またね", "こんにちは"])
        #expect(t.lines[0].start == 0 && t.lines[0].end == 3.5)
        #expect(t.lines[1].start == 2 && t.lines[1].end == 5)
        #expect(t.lines[2].start == 6)
    }

    @Test func srtClosesOpenLinesAndKeepsAMinimumLength() {
        var t = Transcript()
        t.observe([(" Hello ", "안녕"), ("", "x")], at: t0)
        t.observe([("Hello", "안녕"), ("Bye", "잘 가")], at: t0 + 61.25)
        let srt = t.srt(now: t0 + 61.5)
        #expect(srt == "1\n00:00:00,000 --> 00:01:01,500\n안녕\n\n2\n00:01:01,250 --> 00:01:02,250\n잘 가\n")
        #expect(t.text(now: t0 + 62).hasPrefix("[00:00:00] 안녕\n          Hello\n"))
    }

    @Test func stampFormat() {
        #expect(Transcript.stamp(3723.0456) == "01:02:03,046")
    }
}

@Suite struct SubtitleLookTests {
    @Test func centredLinesAreCentredLeftAlignedAreNot() {
        #expect(LineAlignment.isCentered([(100, 500), (180, 420)], outlined: false))
        #expect(!LineAlignment.isCentered([(100, 500), (100, 340)], outlined: false))
        #expect(!LineAlignment.isCentered([(100, 500), (102, 498)], outlined: false))   // same width: cannot tell
        #expect(LineAlignment.isCentered([(100, 500)], outlined: true))
        #expect(!LineAlignment.isCentered([(100, 500)], outlined: false))
    }

    /// White letters with a 3 px black edge on a mid-grey picture, as video subtitles are drawn.
    func patch(outlined: Bool, background: UInt8 = 140) -> RGBAImage {
        var img = RGBAImage(width: 120, height: 40, color: RGBA(background, background, background))
        for (x0, x1) in [(20, 24), (36, 40), (52, 56), (68, 72), (84, 88), (100, 104)] {   // strokes 4 px wide, like text
            for y in 10..<30 {
                for x in (x0 - 3)..<(x1 + 3) {
                    let edge = y < 13 || y >= 27 || x < x0 || x >= x1
                    if edge { if outlined { img.set(x: x, y: y, RGBA(0, 0, 0)) } } else { img.set(x: x, y: y, RGBA(255, 255, 255)) }
                }
            }
        }
        return img
    }

    @Test func outlinedTextKeepsItsFillAndEdgeAndErasesBoth() {
        let m = TextEraser.mask(for: patch(outlined: true), textRect: PixelRect(x: 12, y: 6, width: 100, height: 28), dilation: 1, outlines: true)
        #expect(m.appearance.outlineColor?.luma ?? 255 < 30)
        #expect(m.appearance.textColor.luma > 225)
        let img = patch(outlined: true)
        var missed: [String] = []
        for y in 0..<img.height { for x in 0..<img.width where (img.luma(x: x, y: y) < 30 || img.luma(x: x, y: y) > 225) && m.bits[y * img.width + x] != 1 {
            missed.append("\(x),\(y):\(img.luma(x: x, y: y))")
        } }
        #expect(missed.isEmpty, "\(missed.count) \(missed.prefix(12))")
    }

    @Test func plainTextIsNotOutlined() {
        let m = TextEraser.mask(for: patch(outlined: false), textRect: PixelRect(x: 12, y: 6, width: 100, height: 28), dilation: 1, outlines: true)
        #expect(m.appearance.outlineColor == nil)
        let dark = TextEraser.mask(for: patch(outlined: true, background: 20), textRect: PixelRect(x: 12, y: 6, width: 100, height: 28), dilation: 1, outlines: true)
        #expect(dark.appearance.outlineColor == nil)   // white on black is plain text
        let plain = TextEraser.mask(for: patch(outlined: true), textRect: PixelRect(x: 12, y: 6, width: 100, height: 28), dilation: 1)
        #expect(plain.appearance.outlineColor == nil)  // only the erase path asks for outlines
    }
}
