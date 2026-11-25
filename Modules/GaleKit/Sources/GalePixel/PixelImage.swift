import Foundation
import GaleFormat

/// An 8-bit color: red, green, blue, alpha (0...255).
public struct Pixel32: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(_ c: RGBA) {
        func byte(_ v: Double) -> UInt8 { UInt8(min(255, max(0, (v * 255).rounded()))) }
        self.init(byte(c.r), byte(c.g), byte(c.b), byte(c.a))
    }

    public static let clear = Pixel32(0, 0, 0, 0)
    public static let black = Pixel32(0, 0, 0)
    public static let white = Pixel32(255, 255, 255)

    /// `self` drawn over `below` (straight alpha).
    public func over(_ below: Pixel32) -> Pixel32 {
        if a == 255 || below.a == 0 { return self }
        if a == 0 { return below }
        let sa = Double(a) / 255, da = Double(below.a) / 255
        let oa = sa + da * (1 - sa)
        func mix(_ s: UInt8, _ d: UInt8) -> UInt8 {
            UInt8(min(255, max(0, ((Double(s) * sa + Double(d) * da * (1 - sa)) / oa).rounded())))
        }
        return Pixel32(mix(r, below.r), mix(g, below.g), mix(b, below.b), UInt8(min(255, (oa * 255).rounded())))
    }

    /// Straight mix between two colors (t = 0 gives self, 1 gives other).
    public func mixed(with other: Pixel32, _ t: Double) -> Pixel32 {
        let k = min(1, max(0, t))
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * k).rounded()) }
        return Pixel32(m(r, other.r), m(g, other.g), m(b, other.b), m(a, other.a))
    }
}

/// A plain RGBA picture: 4 bytes per pixel, rows from the top. Straight (not premultiplied) alpha.
public struct RGBAImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, fill: Pixel32 = .clear) {
        self.width = max(1, width)
        self.height = max(1, height)
        var b = [UInt8](repeating: 0, count: self.width * self.height * 4)
        if fill != .clear {
            for i in Swift.stride(from: 0, to: b.count, by: 4) {
                b[i] = fill.r; b[i + 1] = fill.g; b[i + 2] = fill.b; b[i + 3] = fill.a
            }
        }
        bytes = b
    }

    public func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }

    public subscript(x: Int, y: Int) -> Pixel32 {
        get {
            let i = (y * width + x) * 4
            return Pixel32(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            bytes[i] = newValue.r; bytes[i + 1] = newValue.g; bytes[i + 2] = newValue.b; bytes[i + 3] = newValue.a
        }
    }

    /// Sets one pixel if it's inside. `blend` draws over what's there instead of replacing it.
    public mutating func set(_ x: Int, _ y: Int, _ c: Pixel32, blend: Bool = false) {
        guard contains(x, y) else { return }
        self[x, y] = blend ? c.over(self[x, y]) : c
    }

    /// Fills a rectangle (clipped to the picture).
    public mutating func fill(x: Int, y: Int, w: Int, h: Int, _ c: Pixel32, blend: Bool = false) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 {
            var i = (yy * width + x0) * 4
            for _ in x0..<x1 {
                if blend {
                    let below = Pixel32(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
                    let o = c.over(below)
                    bytes[i] = o.r; bytes[i + 1] = o.g; bytes[i + 2] = o.b; bytes[i + 3] = o.a
                } else {
                    bytes[i] = c.r; bytes[i + 1] = c.g; bytes[i + 2] = c.b; bytes[i + 3] = c.a
                }
                i += 4
            }
        }
    }

    /// Copies `src` with its top left at (x, y). See-through pixels of `src` leave what's below.
    public mutating func draw(_ src: RGBAImage, x: Int, y: Int) {
        for sy in 0..<src.height {
            let dy = y + sy
            guard dy >= 0, dy < height else { continue }
            for sx in 0..<src.width {
                let dx = x + sx
                guard dx >= 0, dx < width else { continue }
                let c = src[sx, sy]
                if c.a == 0 { continue }
                self[dx, dy] = c.a == 255 ? c : c.over(self[dx, dy])
            }
        }
    }

    /// The picture made bigger by a whole number, every pixel a sharp square.
    public func scaled(by k: Int) -> RGBAImage {
        let s = max(1, k)
        if s == 1 { return self }
        var out = RGBAImage(width: width * s, height: height * s)
        let rowBytes = out.width * 4
        for y in 0..<height {
            var row = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<width {
                let i = (y * width + x) * 4
                for k in 0..<s {
                    let o = (x * s + k) * 4
                    row[o] = bytes[i]; row[o + 1] = bytes[i + 1]; row[o + 2] = bytes[i + 2]; row[o + 3] = bytes[i + 3]
                }
            }
            for k in 0..<s {
                let start = (y * s + k) * rowBytes
                out.bytes.replaceSubrange(start..<(start + rowBytes), with: row)
            }
        }
        return out
    }

    /// Every pixel mixed toward `other` (same size) by t.
    public func crossfade(to other: RGBAImage, _ t: Double) -> RGBAImage {
        guard other.width == width, other.height == height else { return t < 0.5 ? self : other }
        var out = self
        let k = min(1, max(0, t))
        for i in 0..<bytes.count {
            out.bytes[i] = UInt8((Double(bytes[i]) + (Double(other.bytes[i]) - Double(bytes[i])) * k).rounded())
        }
        return out
    }

    /// The picture with every pixel's alpha made 255 over a solid color.
    public func flattened(on paper: Pixel32) -> RGBAImage {
        var out = self
        for i in Swift.stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] != 255 {
            let c = Pixel32(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]).over(paper)
            out.bytes[i] = c.r; out.bytes[i + 1] = c.g; out.bytes[i + 2] = c.b; out.bytes[i + 3] = 255
        }
        return out
    }
}
