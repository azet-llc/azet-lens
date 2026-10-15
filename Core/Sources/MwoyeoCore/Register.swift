import Foundation

/// Whether a line is written casually. Apple Translation has no tone control and turns "guilty. they finally fixed
/// it" into "유죄입니다. … 해결했습니다." — chat that should read as chat.
public enum Register {
    public static func isCasual(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return isCasualJapanese(t) }
        guard t.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) else { return false }
        return isCasualLatin(t)
    }

    /// Japanese marks politeness in the verb: a sentence without です/ます forms is plain (casual) speech. Short
    /// labels ("ホーム", "見つける") carry no register.
    static func isCasualJapanese(_ t: String) -> Bool {
        t.count >= 10 && !["です", "ます", "まし", "ませ", "でし", "ください", "ござい"].contains { t.contains($0) }
    }

    /// English has no polite verb forms; chat shows itself by sentences starting in lower case ("ok who stayed
    /// up", "I'm in! what time"), doubled "??"/"!!", chat slang, or a last sentence left without a full stop
    /// after punctuated ones ("…tonight? I need two more people"). A label ("Today at 8:12 PM") has none of these.
    static func isCasualLatin(_ t: String) -> Bool {
        let words = t.split(whereSeparator: { $0.isWhitespace })
        let lower = t.lowercased()
        if lower.contains("??") || lower.contains("!!") || lower.contains("?!") { return true }
        let slang: Set<String> = ["lol", "lmao", "omg", "tbh", "idk", "imo", "btw", "gonna", "wanna", "gotta", "kinda", "sorta",
                                  "dunno", "yeah", "yep", "nope", "pls", "plz", "thx", "ok", "okay", "haha", "rip", "ngl", "u", "ur"]
        if words.contains(where: { slang.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }) { return true }
        // Sentence starts: the first word and every word after . ? !
        var starts = words.prefix(1).map { $0 }
        for (a, b) in zip(words, words.dropFirst()) where a.last.map({ ".?!".contains($0) }) == true { starts.append(b) }
        // An all-lower-case word starting a sentence; "iPhone" or "macOS" are names, not casual writing.
        if starts.contains(where: { w in w.first?.isLowercase == true && !w.contains(where: \.isUppercase) }) { return true }
        let punctuated = words.dropLast().contains { $0.last.map { ".?!".contains($0) } == true }
        return punctuated && t.last.map { !".?!:)…\"'”’".contains($0) } == true
    }
}

/// Rewrites the formal endings Apple Translation produces (합쇼체 "-습니다", 해요체 "-요", "-하십시오") into
/// casual 반말, and the humble or distant pronouns with them ("저는" → "나는", "당신" → "너").
public enum KoreanRegister {
    public static func casual(_ s: String) -> String {
        var out = "", word: [Character] = []
        for c in s {
            if isSyllable(c) { word.append(c); continue }
            out += casualWord(word) + String(c)
            word = []
        }
        return out + casualWord(word)
    }

    private static let pronouns: [String: String] = [
        "저는": "나는", "저도": "나도", "저를": "나를", "저의": "나의", "저한테": "나한테", "제가": "내가",
        "저희": "우리", "저희는": "우리는", "저희가": "우리가", "저희도": "우리도",
        "당신": "너", "당신은": "너는", "당신이": "네가", "당신을": "너를", "당신의": "너의", "당신도": "너도", "당신에게": "너에게",
    ]

    /// Stems whose final ㅂ turns into 우 ("어렵다" → "어려워"); the common adjectives, not every irregular verb.
    private static let irregularB: Set<Character> = ["답", "럽", "롭", "깝", "겁", "섭", "쉽", "춥", "덥", "맵", "밉", "눕", "렵", "갑", "엽"]

    static func casualWord(_ w: [Character]) -> String {
        let s = String(w)
        if let p = pronouns[s] { return p }
        func stem(_ n: Int) -> [Character] { Array(w.dropLast(n)) }
        // Copula: "유죄입니다" → "유죄야", "뜻입니까" → "뜻이야".
        if s.hasSuffix("입니다") || s.hasSuffix("입니까") || s.hasSuffix("이에요") { return copula(stem(3)) }
        if s.hasSuffix("예요") { return copula(stem(2)) }
        if s.hasSuffix("습니다") || s.hasSuffix("습니까") { return informal(stem(3)) }
        // Vowel stems: "필요합니다" → "필요해", "됩니까" → "돼".
        if (s.hasSuffix("니다") || s.hasSuffix("니까")), w.count >= 3, let v = dropB(w[w.count - 3]) { return informal(stem(3) + [v]) }
        if s.hasSuffix("시다"), w.count >= 3, let v = dropB(w[w.count - 3]) { return String(stem(3) + [v]) + "자" }
        if s.hasSuffix("십시오") { return informal(dropEu(stem(3))) }
        if s.hasSuffix("계세요") { return String(stem(3)) + "있어" }
        if s.hasSuffix("세요"), w.count > 2 { return informal(dropEu(stem(2))) }
        if s.hasSuffix("죠") { return String(stem(1)) + "지" }
        // 해요체: "뜻인가요" → "뜻인가", "할게요" → "할게". A noun like "필요" keeps its 요.
        if s.hasSuffix("요"), w.count >= 2 {
            let prev = w[w.count - 2]
            if jamo(prev)?.t == 0 || ["군", "걸", "든", "는", "란", "던"].contains(prev) { return String(stem(1)) }
        }
        return s
    }

    private static func copula(_ noun: [Character]) -> String {
        guard let last = noun.last, let j = jamo(last) else { return String(noun) + "이야" }
        return String(noun) + (j.t == 0 ? "야" : "이야")
    }

    /// Stem + 아/어, contracted the way speech does: 하 → 해, 보 → 봐, 되 → 돼, 마시 → 마셔, 모르 → 몰라, 있 → 있어.
    /// ponytail: ㄷ/ㅅ-irregular stems (듣다, 낫다) and most ㅂ-irregular verbs come out regular; add when seen.
    static func informal(_ stem: [Character]) -> String {
        guard let last = stem.last, let j = jamo(last) else { return String(stem) }
        var head = Array(stem.dropLast())
        let prevVowel = head.last.flatMap(jamo)?.v
        let bright = { (v: Int?) in v == 0 || v == 8 } // ㅏ ㅗ
        if last == "하" { return String(head) + "해" }
        if j.t != 0 {
            if j.t == 20 { return String(stem) + "어" } // ㅆ: 했어, 있어
            if j.t == 17, irregularB.contains(last) { return String(head) + String(syllable(j.l, j.v, 0)) + "워" }
            return String(stem) + (bright(j.v) ? "아" : "어")
        }
        switch j.v {
        case 8: return String(head) + String(syllable(j.l, 9, 0))   // ㅗ → ㅘ
        case 13: return String(head) + String(syllable(j.l, 14, 0)) // ㅜ → ㅝ
        case 11: return String(head) + String(syllable(j.l, 10, 0)) // ㅚ → ㅙ
        case 20: return String(head) + String(syllable(j.l, 6, 0))  // ㅣ → ㅕ
        case 18:                                                     // ㅡ
            if last == "르", let p = head.last, let pj = jamo(p), pj.t == 0 {
                head[head.count - 1] = syllable(pj.l, pj.v, 8)
                return String(head) + (bright(pj.v) ? "라" : "러")
            }
            return String(head) + String(syllable(j.l, bright(prevVowel) ? 0 : 4, 0))
        case 0, 1, 4, 5, 6, 3, 7: return String(stem)                // ㅏ ㅐ ㅓ ㅔ ㅕ ㅒ ㅖ: already contracted
        default: return String(stem) + "어"
        }
    }

    /// The syllable without its final ㅂ (the ㅂ of "-ㅂ니다"), or nil if it has none.
    private static func dropB(_ c: Character) -> Character? {
        guard let j = jamo(c), j.t == 17 else { return nil }
        return syllable(j.l, j.v, 0)
    }

    /// "읽으" → "읽": the linking 으 of "-으세요" / "-으십시오".
    private static func dropEu(_ stem: [Character]) -> [Character] {
        stem.count >= 2 && stem.last == "으" ? Array(stem.dropLast()) : stem
    }

    private static func isSyllable(_ c: Character) -> Bool { jamo(c) != nil }

    private static func jamo(_ c: Character) -> (l: Int, v: Int, t: Int)? {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first, (0xAC00...0xD7A3).contains(s.value) else { return nil }
        let i = Int(s.value) - 0xAC00
        return (i / 588, (i % 588) / 28, i % 28)
    }

    private static func syllable(_ l: Int, _ v: Int, _ t: Int) -> Character {
        Character(Unicode.Scalar(UInt32(0xAC00 + l * 588 + v * 28 + t))!)
    }
}
