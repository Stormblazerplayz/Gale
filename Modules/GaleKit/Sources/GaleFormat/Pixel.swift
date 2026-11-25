import Foundation

// MARK: - Pixel storytime (the "pixel" part of a project)
//
// A pixel story is a normal Gale project with a `pixel` field. It holds a small grid (like 32 × 32),
// a limited palette, and scenes. Each scene is a short pixel animation with a caption and speech bubbles.
// The story plays the scenes in order. See docs/format.md section 5.

/// One frame of a pixel scene: a palette index for every cell of the grid.
public struct PixelFrame: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var key: String
    /// Ticks (1/fps of its scene) it stays on screen.
    public var hold: Int
    /// Palette index per cell, row by row from the top left. 0 is always see-through.
    public var cells: [UInt8]

    public init(id: String = GaleID.make(), key: String = OrderKey.first, hold: Int = 1, cells: [UInt8]) {
        self.id = id
        self.key = key
        self.hold = max(1, hold)
        self.cells = cells
    }

    /// A see-through frame for a grid.
    public static func blank(width: Int, height: Int) -> PixelFrame {
        PixelFrame(cells: [UInt8](repeating: 0, count: max(1, width * height)))
    }

    enum CodingKeys: String, CodingKey { case id, key, hold, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        hold = max(1, c.value(.hold, or: 1))
        let runs: [Double] = c.value(.runs, or: [])
        cells = PixelRuns.decode(runs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(hold, forKey: .hold)
        try c.encode(PixelRuns.encode(cells).map(Double.init), forKey: .runs)
    }
}

/// Run-length packing for pixel cells: a flat list of `count, index, count, index...`.
/// "40 zeros, then 3 of color 5" is `[40, 0, 3, 5]`. Same in Swift and JavaScript.
public enum PixelRuns {
    public static func encode(_ cells: [UInt8]) -> [Int] {
        var out: [Int] = []
        guard var current = cells.first else { return out }
        var count = 0
        for v in cells {
            if v == current {
                count += 1
            } else {
                out.append(count)
                out.append(Int(current))
                current = v
                count = 1
            }
        }
        out.append(count)
        out.append(Int(current))
        return out
    }

    /// Bad numbers are skipped; indexes are kept in 0...255. At most `limit` cells come out.
    public static func decode(_ runs: [Double], limit: Int = PixelStory.maxSide * PixelStory.maxSide) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + 1 < runs.count {
            let n = runs[i], v = runs[i + 1]
            i += 2
            guard n.isFinite, v.isFinite, n >= 1 else { continue }
            // Clamp as Doubles first: Int(1e300) would crash.
            let count = Int(min(n, Double(limit - out.count)))
            let index = UInt8(min(255, max(0, v)))
            if count > 0 { out.append(contentsOf: repeatElement(index, count: count)) }
            if out.count >= limit { break }
        }
        return out
    }
}

/// How one scene changes into the next.
public enum PixelTransition: String, Codable, CaseIterable, Sendable {
    case cut, fade, wipe, iris

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = PixelTransition(rawValue: s) ?? .cut
    }

    public var title: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .wipe: return "Wipe"
        case .iris: return "Circle"
        }
    }
}

public enum BubbleStyle: String, Codable, CaseIterable, Sendable {
    case speech, thought, shout, sign

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = BubbleStyle(rawValue: s) ?? .speech
    }

    public var title: String {
        switch self {
        case .speech: return "Talk"
        case .thought: return "Think"
        case .shout: return "Shout"
        case .sign: return "Sign"
        }
    }
}

/// A speech bubble on top of a scene. Positions are 0...1 across and down the picture.
public struct SpeechBubble: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var text: String
    /// Center of the bubble.
    public var x: Double
    public var y: Double
    /// Where the tail points (the speaker's mouth).
    public var tailX: Double
    public var tailY: Double
    public var style: BubbleStyle

    public init(id: String = GaleID.make(), text: String, x: Double = 0.5, y: Double = 0.2,
                tailX: Double = 0.45, tailY: Double = 0.5, style: BubbleStyle = .speech) {
        self.id = id
        self.text = text
        self.x = PixelStory.unit(x)
        self.y = PixelStory.unit(y)
        self.tailX = PixelStory.unit(tailX)
        self.tailY = PixelStory.unit(tailY)
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case id, text, x, y, tailX, tailY, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        text = c.value(.text, or: "")
        x = PixelStory.unit(c.value(.x, or: 0.5))
        y = PixelStory.unit(c.value(.y, or: 0.2))
        tailX = PixelStory.unit(c.value(.tailX, or: 0.45))
        tailY = PixelStory.unit(c.value(.tailY, or: 0.5))
        style = c.value(.style, or: .speech)
    }
}

/// One scene of the story: a looping pixel animation with words.
public struct PixelScene: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var name: String
    /// Ticks per second (1...30).
    public var fps: Int
    /// How many times the animation plays before the story moves on (1...20).
    public var loops: Int
    /// Palette index behind the art (0 = the story's paper color).
    public var background: Int
    /// The words under the picture, like a storybook.
    public var caption: String
    public var bubbles: [SpeechBubble]
    /// How this scene comes in.
    public var transition: PixelTransition
    public var frames: [PixelFrame]

    public init(id: String = GaleID.make(), key: String = OrderKey.first, name: String, fps: Int = 8, loops: Int = 2,
                background: Int = 0, caption: String = "", bubbles: [SpeechBubble] = [],
                transition: PixelTransition = .cut, frames: [PixelFrame]) {
        self.id = id
        self.key = key
        self.name = name
        self.fps = min(30, max(1, fps))
        self.loops = min(20, max(1, loops))
        self.background = max(0, background)
        self.caption = caption
        self.bubbles = bubbles
        self.transition = transition
        self.frames = frames
    }

    enum CodingKeys: String, CodingKey { case id, key, name, fps, loops, background, caption, bubbles, transition, frames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        name = c.value(.name, or: "Scene")
        fps = min(30, max(1, c.value(.fps, or: 8)))
        loops = min(20, max(1, c.value(.loops, or: 2)))
        background = max(0, c.value(.background, or: 0))
        caption = c.value(.caption, or: "")
        bubbles = c.value(.bubbles, or: [])
        transition = c.value(.transition, or: .cut)
        frames = c.value(.frames, or: [])
        frames.sort { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    /// Ticks for one play of the animation.
    public var ticks: Int { frames.reduce(0) { $0 + $1.hold } }
    /// Seconds for one play of the animation.
    public var loopSeconds: Double { Double(max(1, ticks)) / Double(fps) }
}

/// A built-in limited palette.
public struct PixelPalette: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Colors without the see-through slot. They become indexes 1...n.
    public let colors: [RGBA]

    public init(name: String, hex: [String]) {
        self.name = name
        colors = hex.compactMap { RGBA(hex: $0) }
    }

    /// The palette as story colors: see-through first.
    public var storyPalette: [RGBA] { [RGBA.clear] + colors }

    public static let pico8 = PixelPalette(name: "PICO-8", hex: [
        "000000", "1D2B53", "7E2553", "008751", "AB5236", "5F574F", "C2C3C7", "FFF1E8",
        "FF004D", "FFA300", "FFEC27", "00E436", "29ADFF", "83769C", "FF77A8", "FFCCAA",
    ])
    public static let gameBoy = PixelPalette(name: "Game Boy", hex: ["0F380F", "306230", "8BAC0F", "9BBC0F"])
    public static let nes = PixelPalette(name: "NES", hex: [
        "000000", "FCFCFC", "7C7C7C", "BCBCBC", "A80020", "F83800", "FCA044", "F8B800",
        "00A800", "58D854", "0058F8", "3CBCFC", "6844FC", "D800CC", "F878F8", "AC7C00",
    ])
    public static let sweetie16 = PixelPalette(name: "Sweetie 16", hex: [
        "1A1C2C", "5D275D", "B13E53", "EF7D57", "FFCD75", "A7F070", "38B764", "257179",
        "29366F", "3B5DC9", "41A6F6", "73EFF7", "F4F4F4", "94B0C2", "566C86", "333C57",
    ])
    public static let endesga32 = PixelPalette(name: "Endesga 32", hex: [
        "BE4A2F", "D77643", "EAD4AA", "E4A672", "B86F50", "733E39", "3E2731", "A22633",
        "E43B44", "F77622", "FEAE34", "FEE761", "63C74D", "3E8948", "265C42", "193C3E",
        "124E89", "0099DB", "2CE8F5", "FFFFFF", "C0CBDC", "8B9BB4", "5A6988", "3A4466",
        "262B44", "181425", "FF0044", "68386C", "B55088", "F6757A", "E8B796", "C28569",
    ])
    public static let mono = PixelPalette(name: "1-bit", hex: ["000000", "FFFFFF"])

    public static let all: [PixelPalette] = [.pico8, .sweetie16, .endesga32, .nes, .gameBoy, .mono]

    public static func named(_ name: String) -> PixelPalette? { all.first { $0.name == name } }
}

/// The pixel story stored in a project.
public struct PixelStory: Codable, Hashable, Sendable {
    public static let minSide = 8
    public static let maxSide = 256
    /// See-through + up to 63 colors.
    public static let maxColors = 64

    public var width: Int
    public var height: Int
    /// Index 0 is always see-through. Others are "#RRGGBBAA".
    public var palette: [RGBA]
    public var paletteName: String
    /// Paper color shown behind see-through cells.
    public var paper: RGBA
    public var scenes: [PixelScene]

    public init(width: Int, height: Int, palette: PixelPalette = .pico8, paper: RGBA? = nil, scenes: [PixelScene]? = nil) {
        self.width = PixelStory.side(width)
        self.height = PixelStory.side(height)
        self.palette = palette.storyPalette
        paletteName = palette.name
        self.paper = paper ?? palette.colors.last ?? .white
        let w = self.width, h = self.height
        self.scenes = scenes ?? [PixelScene(name: "Scene 1", frames: [PixelFrame.blank(width: w, height: h)])]
        normalize()
    }

    enum CodingKeys: String, CodingKey { case width, height, palette, paletteName, paper, scenes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = PixelStory.side(c.value(.width, or: 32))
        height = PixelStory.side(c.value(.height, or: 32))
        let hex: [String] = c.value(.palette, or: [])
        palette = hex.map { RGBA(hex: $0) ?? .black }
        paletteName = c.value(.paletteName, or: "")
        paper = c.value(.paper, or: .white)
        scenes = c.value(.scenes, or: [])
        normalize()
    }

    static func side(_ v: Int) -> Int { min(maxSide, max(minSide, v)) }
    static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0.5 }

    public var cellCount: Int { width * height }

    /// Fixes anything a hand-edited or synced file could get wrong: sizes, palette, order, at least one scene and frame.
    public mutating func normalize() {
        width = PixelStory.side(width)
        height = PixelStory.side(height)
        if palette.isEmpty { palette = PixelPalette.pico8.storyPalette }
        palette[0] = .clear
        if palette.count == 1 { palette.append(.black) }
        if palette.count > PixelStory.maxColors { palette = Array(palette.prefix(PixelStory.maxColors)) }
        let top = UInt8(palette.count - 1)
        let n = cellCount
        scenes.sort { ($0.key, $0.id) < ($1.key, $1.id) }
        if scenes.isEmpty { scenes = [PixelScene(name: "Scene 1", frames: [])] }
        for s in scenes.indices {
            scenes[s].frames.sort { ($0.key, $0.id) < ($1.key, $1.id) }
            if scenes[s].frames.isEmpty { scenes[s].frames = [PixelFrame.blank(width: width, height: height)] }
            if scenes[s].background >= palette.count { scenes[s].background = 0 }
            for f in scenes[s].frames.indices {
                var cells = scenes[s].frames[f].cells
                if cells.count != n {
                    if cells.count > n { cells.removeLast(cells.count - n) } else { cells += [UInt8](repeating: 0, count: n - cells.count) }
                }
                if cells.contains(where: { $0 > top }) {
                    cells = cells.map { $0 > top ? 0 : $0 }
                }
                if cells != scenes[s].frames[f].cells { scenes[s].frames[f].cells = cells }
            }
        }
    }

    public func sceneIndex(_ id: String) -> Int? { scenes.firstIndex { $0.id == id } }

    // MARK: Edits that keep keys right

    /// Inserts a scene after `index` (nil = at the end) and returns where it went.
    @discardableResult
    public mutating func insertScene(_ scene: PixelScene, after index: Int?) -> Int {
        let i = min(scenes.count - 1, index ?? scenes.count - 1)
        let lower = i >= 0 ? scenes[i].key : nil
        let upper = i + 1 < scenes.count ? scenes[i + 1].key : nil
        var s = scene
        s.key = OrderKey.between(lower, upper) ?? OrderKey.first
        scenes.insert(s, at: i + 1)
        return i + 1
    }

    public mutating func moveScene(from: Int, to: Int) {
        guard scenes.indices.contains(from), to >= 0, to < scenes.count, from != to else { return }
        var s = scenes.remove(at: from)
        let lower = to > 0 ? scenes[to - 1].key : nil
        let upper = to < scenes.count ? scenes[to].key : nil
        s.key = OrderKey.between(lower, upper) ?? s.key
        scenes.insert(s, at: to)
    }

    /// Inserts a frame into a scene after `index` and returns where it went.
    @discardableResult
    public mutating func insertFrame(_ frame: PixelFrame, scene: Int, after index: Int?) -> Int {
        guard scenes.indices.contains(scene) else { return 0 }
        let frames = scenes[scene].frames
        let i = min(frames.count - 1, index ?? frames.count - 1)
        let lower = i >= 0 ? frames[i].key : nil
        let upper = i + 1 < frames.count ? frames[i + 1].key : nil
        var f = frame
        f.key = OrderKey.between(lower, upper) ?? OrderKey.first
        scenes[scene].frames.insert(f, at: i + 1)
        return i + 1
    }

    public mutating func moveFrame(scene: Int, from: Int, to: Int) {
        guard scenes.indices.contains(scene) else { return }
        var frames = scenes[scene].frames
        guard frames.indices.contains(from), to >= 0, to < frames.count, from != to else { return }
        var f = frames.remove(at: from)
        let lower = to > 0 ? frames[to - 1].key : nil
        let upper = to < frames.count ? frames[to].key : nil
        f.key = OrderKey.between(lower, upper) ?? f.key
        frames.insert(f, at: to)
        scenes[scene].frames = frames
    }

    /// Changes the grid size. Art stays anchored at the top left; new cells are see-through.
    public mutating func resize(width newW: Int, height newH: Int) {
        let w = PixelStory.side(newW), h = PixelStory.side(newH)
        guard w != width || h != height else { return }
        for s in scenes.indices {
            for f in scenes[s].frames.indices {
                let old = scenes[s].frames[f].cells
                var cells = [UInt8](repeating: 0, count: w * h)
                for y in 0..<min(h, height) {
                    for x in 0..<min(w, width) { cells[y * w + x] = old[y * width + x] }
                }
                scenes[s].frames[f].cells = cells
            }
        }
        width = w
        height = h
    }

    /// Swaps in another palette. Each color goes to the nearest color of the new palette.
    public mutating func switchPalette(to newPalette: PixelPalette) {
        let target = newPalette.storyPalette
        var map: [UInt8] = [0]
        for i in 1..<palette.count {
            map.append(UInt8(PixelStory.nearest(palette[i], in: target)))
        }
        for s in scenes.indices {
            let bg = scenes[s].background
            scenes[s].background = bg < map.count ? Int(map[bg]) : 0
            for f in scenes[s].frames.indices {
                scenes[s].frames[f].cells = scenes[s].frames[f].cells.map { Int($0) < map.count ? map[Int($0)] : 0 }
            }
        }
        palette = target
        paletteName = newPalette.name
    }

    /// Index of the closest opaque color in `palette` (skips index 0).
    public static func nearest(_ c: RGBA, in palette: [RGBA]) -> Int {
        var best = 1, bestD = Double.infinity
        for i in 1..<max(2, palette.count) where i < palette.count {
            let p = palette[i]
            // Weighted so greens count more, like eyes do.
            let d = 0.30 * (p.r - c.r) * (p.r - c.r) + 0.59 * (p.g - c.g) * (p.g - c.g) + 0.11 * (p.b - c.b) * (p.b - c.b)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}
