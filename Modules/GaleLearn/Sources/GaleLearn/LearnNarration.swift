import Foundation

/// What the narrator says, and the maths behind live captions.
///
/// The app speaks with the device's own text-to-speech voice, so every lesson can be heard
/// without shipping any recordings. This file decides the words; the app does the talking.
public enum LearnNarration {
    // MARK: Scripts

    /// The lines spoken when a step opens, in order.
    ///
    /// - A step's own `say` lines win.
    /// - Watch steps speak their beats (the watch player speaks them one at a time).
    /// - Quizzes read the question, then each choice with its letter.
    /// - Everything else reads the title, then the text one sentence at a time.
    public static func lines(for step: LearnStep) -> [String] {
        if !step.say.isEmpty { return step.say.map(clean).filter { !$0.isEmpty } }
        switch step.kind {
        case .watch:
            return step.beats.map { clean($0.say) }.filter { !$0.isEmpty }
        case .quiz:
            var out: [String] = []
            if let q = step.quiz {
                out.append(clean(q.question))
                for (i, choice) in q.choices.enumerated() {
                    out.append("\(letter(i)). \(clean(choice))")
                }
            }
            return out.filter { !$0.isEmpty }
        default:
            var out: [String] = []
            let title = clean(step.title)
            if !title.isEmpty { out.append(endSentence(title)) }
            out += sentences(step.text)
            return out
        }
    }

    /// The lines spoken after a check: the headline, what the check said, and the hint after a miss.
    public static func lines(for feedback: LearnFeedback) -> [String] {
        var out: [String] = [endSentence(clean(feedback.title))]
        out += sentences(feedback.message)
        if !feedback.passed, let hint = feedback.hint {
            out += sentences(hint)
        }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "A", "B", "C" ...
    public static func letter(_ i: Int) -> String {
        String(Character(Unicode.Scalar(UInt8(65 + min(max(i, 0), 25)))))
    }

    // MARK: Text

    /// Splits text into sentences. Keeps quoted words and "e.g." style dots inside a sentence.
    public static func sentences(_ text: String) -> [String] {
        let t = clean(text)
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                // Pull in closing quotes and brackets that belong to this sentence.
                var j = i + 1
                while j < chars.count, "\"')\u{201D}\u{2019}".contains(chars[j]) {
                    current.append(chars[j])
                    j += 1
                }
                let atEnd = j >= chars.count
                let nextIsSpace = !atEnd && chars[j] == " "
                let abbreviation = ch == "." && isAbbreviation(current)
                if (atEnd || nextIsSpace) && !abbreviation {
                    let s = current.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { out.append(s) }
                    current = ""
                }
                i = j
                continue
            }
            i += 1
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private static func isAbbreviation(_ s: String) -> Bool {
        let lower = s.lowercased()
        for a in ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "dr."] where lower.hasSuffix(a) {
            // "etc." at the very end of a sentence still ends it; inside a sentence it doesn't matter much.
            return a != "etc."
        }
        return false
    }

    /// Tidies spaces and new lines.
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func endSentence(_ s: String) -> String {
        guard let last = s.last else { return s }
        return ".!?".contains(last) ? s : s + "."
    }

    /// The words the voice should actually say. Keeps the same words as the caption wherever it can,
    /// so the highlighted caption word stays in step with the voice.
    public static func speechText(_ line: String) -> String {
        var s = line
        let swaps: [(String, String)] = [
            ("\u{201C}", ""), ("\u{201D}", ""), ("\"", ""),
            (" & ", " and "),
            ("3/4", "three-quarter"),
            ("e.g.", "for example"),
            ("i.e.", "that is"),
            ("M B P", "M, B, P"),
            ("F V", "F, V"),
        ]
        for (a, b) in swaps { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }

    /// Roughly how long a line takes to read or hear, in seconds (used when the voice is off).
    public static func readingSeconds(_ text: String) -> Double {
        let words = wordRanges(in: text).count
        return max(1.8, Double(words) / 2.6 + 0.8)
    }

    // MARK: Captions

    /// Where each word sits in the text, as UTF-16 offsets (what the speech engine reports).
    public static func wordRanges(in text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        var offset = 0
        for unit in text.unicodeScalars {
            let isWord = CharacterSet.alphanumerics.contains(unit) || unit == "'" || unit == "\u{2019}" || unit == "-"
            let width = unit.utf16.count
            if isWord {
                if start == nil { start = offset }
            } else if let s = start {
                out.append(s..<offset)
                start = nil
            }
            offset += width
        }
        if let s = start { out.append(s..<offset) }
        // A lone "-" or "'" isn't a word.
        return out.filter { r in
            let scalars = Array(text.utf16)[r]
            return scalars.contains { CharacterSet.alphanumerics.contains(Unicode.Scalar($0) ?? " ") }
        }
    }

    /// Which word (counting from 0) the speech engine is on, given the UTF-16 offset it reports.
    public static func wordIndex(atUTF16 offset: Int, in ranges: [Range<Int>]) -> Int? {
        guard !ranges.isEmpty, offset >= 0 else { return nil }
        for (i, r) in ranges.enumerated() {
            if offset < r.upperBound { return i }
        }
        return ranges.count - 1
    }

    /// The caption word to highlight while the voice speaks `spoken` at `offset`,
    /// when the caption shows `shown` (the two can differ a little, see `speechText`).
    public static func captionWord(shown: String, spoken: String, spokenOffset: Int) -> Int? {
        let spokenWords = wordRanges(in: spoken)
        let shownWords = wordRanges(in: shown)
        guard let i = wordIndex(atUTF16: spokenOffset, in: spokenWords), !shownWords.isEmpty else { return nil }
        if spokenWords.count == shownWords.count { return i }
        // Different word counts (like "&" → "and"): keep the same share of the way through.
        let share = Double(i) / Double(max(1, spokenWords.count - 1))
        return min(shownWords.count - 1, Int((share * Double(shownWords.count - 1)).rounded()))
    }
}
