import Foundation

/// The chunky storytime font: every letter is 5 × 9 dots (rows 7 and 8 hold the tails of g, j, p, q, y).
/// Text is drawn with each dot as a `scale` × `scale` square, so words look like pixel art too.
public enum PixelFont {
    public static let glyphWidth = 5
    public static let glyphRows = 9
    /// Dots from one letter's left edge to the next.
    public static let advance = 6
    /// Dots from one line's top to the next.
    public static let lineHeight = 11
    /// Height of capital letters (rows above the tails).
    public static let capHeight = 7

    /// Rows for one character. Letters with accents lose them; anything else unknown becomes "?".
    public static func rows(for ch: Character) -> [UInt8] {
        for scalar in String(ch).unicodeScalars {
            if let g = glyphs[scalar.value] { return g }
        }
        switch ch {
        case "\u{2018}", "\u{2019}": return glyphs[39]!
        case "\u{201C}", "\u{201D}": return glyphs[34]!
        case "\u{2026}": return glyphs[46]!
        case "\u{2014}", "\u{2013}": return glyphs[45]!
        case "\n", "\t": return glyphs[32]!
        default: break
        }
        let plain = String(ch).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        if let s = plain.unicodeScalars.first, let g = glyphs[s.value] { return g }
        return glyphs[63]!
    }

    /// Splits text into lines of at most `maxChars` letters, breaking at spaces when it can.
    /// Line breaks in the text are kept. Words longer than a line are cut.
    public static func wrap(_ text: String, maxChars: Int) -> [String] {
        let limit = max(1, maxChars)
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                var w = String(word)
                while w.count > limit {
                    if !line.isEmpty { lines.append(line); line = "" }
                    lines.append(String(w.prefix(limit)))
                    w = String(w.dropFirst(limit))
                }
                if w.isEmpty { continue }
                if line.isEmpty {
                    line = w
                } else if line.count + 1 + w.count <= limit {
                    line += " " + w
                } else {
                    lines.append(line)
                    line = w
                }
            }
            lines.append(line)
        }
        // No empty lines at the end (a trailing return shouldn't make the box taller).
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Size in dots of wrapped lines.
    public static func size(lines: [String]) -> (width: Int, height: Int) {
        let longest = lines.map(\.count).max() ?? 0
        let w = longest == 0 ? 0 : longest * advance - 1
        let h = lines.isEmpty ? 0 : (lines.count - 1) * lineHeight + capHeight
        return (w, h)
    }

    /// Draws one line with its top left at (x, y) in picture pixels. Each dot is `scale` pixels.
    /// Only the first `visible` letters are drawn (for typewriter text); nil draws all.
    public static func draw(_ text: String, into img: inout RGBAImage, x: Int, y: Int, scale: Int, color: Pixel32, visible: Int? = nil) {
        let s = max(1, scale)
        var cx = x
        for (i, ch) in text.enumerated() {
            if let v = visible, i >= v { break }
            let rows = rows(for: ch)
            for (r, mask) in rows.enumerated() where mask != 0 {
                for c in 0..<glyphWidth where mask & (1 << (4 - c)) != 0 {
                    img.fill(x: cx + c * s, y: y + r * s, w: s, h: s, color)
                }
            }
            cx += advance * s
        }
    }

    /// Draws wrapped lines, each centered (or left aligned) inside `width` starting at x.
    /// `visible` counts letters across all lines (spaces between lines count as one).
    public static func drawLines(_ lines: [String], into img: inout RGBAImage, x: Int, y: Int, width: Int, scale: Int,
                                 color: Pixel32, centered: Bool, visible: Int? = nil) {
        var left = visible
        for (i, line) in lines.enumerated() {
            let lineW = line.isEmpty ? 0 : (line.count * advance - 1) * scale
            let lx = centered ? x + (width - lineW) / 2 : x
            draw(line, into: &img, x: lx, y: y + i * lineHeight * scale, scale: scale, color: color, visible: left)
            if let l = left {
                left = max(0, l - line.count - 1)
                if l <= line.count { break }
            }
        }
    }

    /// Letters a typewriter has to show for these lines (what `visible` counts).
    public static func typedLength(_ lines: [String]) -> Int {
        lines.isEmpty ? 0 : lines.reduce(0) { $0 + $1.count } + lines.count - 1
    }
}
