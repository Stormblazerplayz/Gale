import Foundation

/// A small animated GIF writer made for pixel art: colors are kept exactly (no dithering, no blur)
/// whenever a frame has 256 colors or fewer. Frames with more (like mid-fade) use a 252-color cube.
public struct GIFEncoder {
    public private(set) var data = Data()
    public let width: Int
    public let height: Int
    private var finished = false

    /// `loops`: 0 = forever.
    public init(width: Int, height: Int, loops: Int = 0) {
        self.width = min(65535, max(1, width))
        self.height = min(65535, max(1, height))
        data.append(contentsOf: Array("GIF89a".utf8))
        u16(self.width)
        u16(self.height)
        // No global color table; every frame brings its own.
        data.append(contentsOf: [0x00, 0x00, 0x00])
        // NETSCAPE2.0 loop block.
        data.append(contentsOf: [0x21, 0xFF, 0x0B])
        data.append(contentsOf: Array("NETSCAPE2.0".utf8))
        data.append(contentsOf: [0x03, 0x01])
        u16(max(0, min(65535, loops)))
        data.append(0x00)
    }

    private mutating func u16(_ v: Int) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    /// Adds a frame. It must be `width × height`. Pixels with alpha under 128 become see-through.
    public mutating func add(_ img: RGBAImage, centiseconds: Int) {
        precondition(!finished, "The GIF is already finished")
        precondition(img.width == width && img.height == height, "Every frame must be the GIF's size")
        let (palette, indexes, transparent) = GIFEncoder.indexed(img)
        var size = 1
        while (1 << size) < palette.count { size += 1 }
        size = max(1, size)

        // Graphic control: delay, and a see-through color if there is one. Disposal 1 = leave the frame.
        data.append(contentsOf: [0x21, 0xF9, 0x04])
        data.append(UInt8((1 << 2) | (transparent != nil ? 1 : 0)))
        u16(max(0, min(65535, centiseconds)))
        data.append(UInt8(transparent ?? 0))
        data.append(0x00)

        // Image descriptor with a local color table.
        data.append(0x2C)
        u16(0); u16(0); u16(width); u16(height)
        data.append(UInt8(0x80 | (size - 1)))
        for i in 0..<(1 << size) {
            if i < palette.count {
                data.append(palette[i].r); data.append(palette[i].g); data.append(palette[i].b)
            } else {
                data.append(contentsOf: [0, 0, 0])
            }
        }
        let minCode = max(2, size)
        data.append(UInt8(minCode))
        let compressed = GIFEncoder.lzw(indexes, minCodeSize: minCode)
        var i = 0
        while i < compressed.count {
            let n = min(255, compressed.count - i)
            data.append(UInt8(n))
            data.append(contentsOf: compressed[i..<(i + n)])
            i += n
        }
        data.append(0x00)
    }

    /// Writes the end marker and returns the file.
    public mutating func finish() -> Data {
        if !finished {
            data.append(0x3B)
            finished = true
        }
        return data
    }

    // MARK: Colors

    /// The frame's colors (at most 256) and each pixel's index into them.
    static func indexed(_ img: RGBAImage) -> (palette: [Pixel32], indexes: [UInt8], transparent: Int?) {
        let n = img.width * img.height
        var indexes = [UInt8](repeating: 0, count: n)
        var lookup: [UInt32: UInt8] = [:]
        var palette: [Pixel32] = []
        var transparent: Int?
        var overflow = false
        let b = img.bytes
        for i in 0..<n {
            let o = i * 4
            let key: UInt32
            if b[o + 3] < 128 {
                key = 0xFFFF_FFFF
            } else {
                key = UInt32(b[o]) << 16 | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2])
            }
            if let idx = lookup[key] {
                indexes[i] = idx
                continue
            }
            if palette.count == 256 { overflow = true; break }
            let idx = UInt8(palette.count)
            lookup[key] = idx
            if key == 0xFFFF_FFFF {
                transparent = palette.count
                palette.append(.clear)
            } else {
                palette.append(Pixel32(b[o], b[o + 1], b[o + 2]))
            }
            indexes[i] = idx
        }
        guard overflow else { return (palette, indexes, transparent) }

        // Too many colors: a 6 × 7 × 6 cube (green gets the extra step) plus see-through.
        palette = []
        for r in 0..<6 { for g in 0..<7 { for bl in 0..<6 {
            palette.append(Pixel32(UInt8(r * 51), UInt8((g * 255 + 3) / 6), UInt8(bl * 51)))
        } } }
        let clearIndex = palette.count
        palette.append(.clear)
        var usedClear = false
        for i in 0..<n {
            let o = i * 4
            if b[o + 3] < 128 {
                indexes[i] = UInt8(clearIndex)
                usedClear = true
                continue
            }
            let r = (Int(b[o]) * 5 + 127) / 255
            let g = (Int(b[o + 1]) * 6 + 127) / 255
            let bl = (Int(b[o + 2]) * 5 + 127) / 255
            indexes[i] = UInt8(r * 42 + g * 6 + bl)
        }
        return (palette, indexes, usedClear ? clearIndex : nil)
    }

    // MARK: LZW

    /// GIF's variable-length LZW, packed least significant bit first.
    static func lzw(_ indexes: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize
        let end = clear + 1
        var out: [UInt8] = []
        out.reserveCapacity(indexes.count / 2)
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var codeSize = minCodeSize + 1
        func emit(_ code: Int) {
            bitBuffer |= UInt32(code) << UInt32(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }
        // Dictionary: (prefix code << 8 | next index) -> code.
        var table: [Int: Int] = [:]
        table.reserveCapacity(4096)
        var next = end + 1
        emit(clear)
        guard var prefix = indexes.first.map(Int.init) else {
            emit(end)
            if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
            return out
        }
        for k in indexes.dropFirst() {
            let key = prefix << 8 | Int(k)
            if let code = table[key] {
                prefix = code
                continue
            }
            emit(prefix)
            if next < 4096 {
                table[key] = next
                // The decoder grows its code size one code later than us, so grow when `next` passes the limit.
                if next == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
                next += 1
            } else {
                emit(clear)
                table.removeAll(keepingCapacity: true)
                codeSize = minCodeSize + 1
                next = end + 1
            }
            prefix = Int(k)
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
        return out
    }
}
