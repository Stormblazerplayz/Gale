import Foundation

/// A color with red, green, blue and alpha from 0 to 1.
/// In files it's written as "#RRGGBBAA" (alpha last), like "#FF8800FF".
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = RGBA.clamp(r)
        self.g = RGBA.clamp(g)
        self.b = RGBA.clamp(b)
        self.a = RGBA.clamp(a)
    }

    public static let black = RGBA(0, 0, 0, 1)
    public static let white = RGBA(1, 1, 1, 1)
    public static let clear = RGBA(0, 0, 0, 0)

    static func clamp(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1, max(0, v))
    }

    /// "#RRGGBBAA"
    public var hex: String {
        func byte(_ v: Double) -> String {
            let n = Int((RGBA.clamp(v) * 255).rounded())
            let s = String(n, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + byte(r) + byte(g) + byte(b) + byte(a)
    }

    /// Reads "#RGB", "#RRGGBB" or "#RRGGBBAA" (the # is optional). Returns nil for anything else.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        self.init(Double((value >> 24) & 0xFF) / 255,
                  Double((value >> 16) & 0xFF) / 255,
                  Double((value >> 8) & 0xFF) / 255,
                  Double(value & 0xFF) / 255)
    }

    public func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let color = RGBA(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a color: \(s)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}
