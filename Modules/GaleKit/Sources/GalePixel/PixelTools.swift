import Foundation
import GaleFormat

/// A grid position (column x, row y from the top left).
public struct GridPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

/// The pixel editor's tools.
public enum PixelTool: String, CaseIterable, Codable, Sendable {
    case pencil, eraser, fill, line, rect, circle, picker, move

    public var title: String {
        switch self {
        case .pencil: return "Pencil"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .line: return "Line"
        case .rect: return "Box"
        case .circle: return "Circle"
        case .picker: return "Color picker"
        case .move: return "Move"
        }
    }
}

/// Edits on one frame's cells. Everything is pure: give it cells, get new cells back.
public struct PixelGrid: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var cells: [UInt8]

    public init(width: Int, height: Int, cells: [UInt8]? = nil) {
        self.width = max(1, width)
        self.height = max(1, height)
        let n = self.width * self.height
        var c = cells ?? [UInt8](repeating: 0, count: n)
        if c.count != n {
            if c.count > n { c.removeLast(c.count - n) } else { c += [UInt8](repeating: 0, count: n - c.count) }
        }
        self.cells = c
    }

    public func contains(_ p: GridPoint) -> Bool { p.x >= 0 && p.y >= 0 && p.x < width && p.y < height }

    public subscript(p: GridPoint) -> UInt8 {
        get { contains(p) ? cells[p.y * width + p.x] : 0 }
        set { if contains(p) { cells[p.y * width + p.x] = newValue } }
    }

    // MARK: Pencil, eraser, mirror

    /// Paints a square brush of `size` cells (1, 2 or 3...) centered on p. With `mirror`, also on the other side.
    public mutating func stamp(_ p: GridPoint, color: UInt8, size: Int = 1, mirrorX: Bool = false, mirrorY: Bool = false) {
        let s = max(1, size)
        let start = -(s - 1) / 2
        for dy in 0..<s {
            for dx in 0..<s {
                let q = GridPoint(p.x + start + dx, p.y + start + dy)
                self[q] = color
                if mirrorX { self[GridPoint(width - 1 - q.x, q.y)] = color }
                if mirrorY { self[GridPoint(q.x, height - 1 - q.y)] = color }
                if mirrorX && mirrorY { self[GridPoint(width - 1 - q.x, height - 1 - q.y)] = color }
            }
        }
    }

    /// Every cell on a straight line from a to b (Bresenham), with no gaps and no doubled corners.
    public static func line(_ a: GridPoint, _ b: GridPoint) -> [GridPoint] {
        var out: [GridPoint] = []
        var x0 = a.x, y0 = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while true {
            out.append(GridPoint(x0, y0))
            if x0 == b.x && y0 == b.y { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        return out
    }

    public mutating func drawLine(_ a: GridPoint, _ b: GridPoint, color: UInt8, size: Int = 1, mirrorX: Bool = false, mirrorY: Bool = false) {
        for p in PixelGrid.line(a, b) { stamp(p, color: color, size: size, mirrorX: mirrorX, mirrorY: mirrorY) }
    }

    /// The outline (or filled) box between two corners.
    public mutating func drawRect(_ a: GridPoint, _ b: GridPoint, color: UInt8, filled: Bool = false) {
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x), y0 = min(a.y, b.y), y1 = max(a.y, b.y)
        for y in y0...y1 {
            for x in x0...x1 where filled || x == x0 || x == x1 || y == y0 || y == y1 {
                self[GridPoint(x, y)] = color
            }
        }
    }

    /// The cells of an ellipse that fits the box between two corners (midpoint ellipse, no gaps).
    public static func ellipse(_ a: GridPoint, _ b: GridPoint, filled: Bool = false) -> [GridPoint] {
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x), y0 = min(a.y, b.y), y1 = max(a.y, b.y)
        let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
        let rx = Double(x1 - x0) / 2 + 0.5, ry = Double(y1 - y0) / 2 + 0.5
        var inside = Set<GridPoint>()
        for y in y0...y1 {
            for x in x0...x1 {
                let nx = (Double(x) - cx) / rx, ny = (Double(y) - cy) / ry
                if nx * nx + ny * ny <= 1.0001 { inside.insert(GridPoint(x, y)) }
            }
        }
        if filled { return inside.sorted { ($0.y, $0.x) < ($1.y, $1.x) } }
        // Outline: inside cells with a 4-neighbour outside.
        return inside.filter { p in
            [GridPoint(p.x + 1, p.y), GridPoint(p.x - 1, p.y), GridPoint(p.x, p.y + 1), GridPoint(p.x, p.y - 1)]
                .contains { !inside.contains($0) }
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    public mutating func drawEllipse(_ a: GridPoint, _ b: GridPoint, color: UInt8, filled: Bool = false) {
        for p in PixelGrid.ellipse(a, b, filled: filled) { self[p] = color }
    }

    // MARK: Fill

    /// Paint bucket: fills the area of cells that match the start cell, through edges (not corners).
    /// Returns how many cells changed.
    @discardableResult
    public mutating func floodFill(_ start: GridPoint, color: UInt8) -> Int {
        guard contains(start) else { return 0 }
        let target = self[start]
        guard target != color else { return 0 }
        var stack = [start]
        var changed = 0
        while let p = stack.popLast() {
            // Scan left and right along the row, then queue the rows above and below.
            var x = p.x
            while x >= 0 && cells[p.y * width + x] == target { x -= 1 }
            x += 1
            var upOpen = false, downOpen = false
            while x < width && cells[p.y * width + x] == target {
                cells[p.y * width + x] = color
                changed += 1
                if p.y > 0 {
                    let up = cells[(p.y - 1) * width + x] == target
                    if up && !upOpen { stack.append(GridPoint(x, p.y - 1)) }
                    upOpen = up
                }
                if p.y < height - 1 {
                    let down = cells[(p.y + 1) * width + x] == target
                    if down && !downOpen { stack.append(GridPoint(x, p.y + 1)) }
                    downOpen = down
                }
                x += 1
            }
        }
        return changed
    }

    /// Changes every cell of one color to another (the "replace color" tool).
    public mutating func replace(_ from: UInt8, with to: UInt8) {
        guard from != to else { return }
        for i in cells.indices where cells[i] == from { cells[i] = to }
    }

    // MARK: Whole-frame moves

    /// Slides the art by (dx, dy). Art that leaves one side comes back on the other when `wrap` is on.
    public func shifted(dx: Int, dy: Int, wrap: Bool = true) -> PixelGrid {
        var out = PixelGrid(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var nx = x + dx, ny = y + dy
                if wrap {
                    nx = ((nx % width) + width) % width
                    ny = ((ny % height) + height) % height
                } else if nx < 0 || ny < 0 || nx >= width || ny >= height {
                    continue
                }
                out.cells[ny * width + nx] = cells[y * width + x]
            }
        }
        return out
    }

    public func flippedHorizontally() -> PixelGrid {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out.cells[y * width + x] = cells[y * width + (width - 1 - x)] }
        }
        return out
    }

    public func flippedVertically() -> PixelGrid {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out.cells[y * width + x] = cells[(height - 1 - y) * width + x] }
        }
        return out
    }

    /// How many cells aren't see-through.
    public var inkCount: Int { cells.reduce(0) { $0 + ($1 == 0 ? 0 : 1) } }
}

/// Onion skin for pixel frames: the frames before and after, faded and tinted.
public struct PixelOnion: Hashable, Sendable {
    public var on: Bool
    public var before: Int
    public var after: Int
    /// 0...1 strength of the nearest ghost.
    public var opacity: Double

    public init(on: Bool = true, before: Int = 1, after: Int = 0, opacity: Double = 0.35) {
        self.on = on
        self.before = max(0, before)
        self.after = max(0, after)
        self.opacity = opacity
    }

    /// Ghost frames to draw for `current`, farthest first, with their tint and alpha.
    public func ghosts(current: Int, count: Int, loop: Bool = false) -> [(index: Int, tint: Pixel32, alpha: Double)] {
        guard on, count > 1 else { return [] }
        var out: [(Int, Pixel32, Double)] = []
        func add(_ offset: Int, _ tint: Pixel32, _ distance: Int, _ total: Int) {
            var i = current + offset
            if loop { i = ((i % count) + count) % count }
            guard i >= 0, i < count, i != current else { return }
            let falloff = 1 - Double(distance - 1) / Double(max(1, total))
            out.append((i, tint, opacity * falloff))
        }
        for d in stride(from: before, through: 1, by: -1) { add(-d, Pixel32(255, 60, 90), d, before) }
        for d in stride(from: after, through: 1, by: -1) { add(d, Pixel32(40, 140, 255), d, after) }
        return out
    }
}

/// Turns pixel cells into colors.
public enum PixelRender {
    /// The story palette as 8-bit colors (index 0 see-through).
    public static func colors(_ story: PixelStory) -> [Pixel32] {
        story.palette.enumerated().map { $0.offset == 0 ? .clear : Pixel32($0.element) }
    }

    /// One frame at grid size, over its scene background (or see-through if `background` is nil).
    public static func frame(_ cells: [UInt8], width: Int, height: Int, colors: [Pixel32], background: Pixel32?) -> RGBAImage {
        var img = RGBAImage(width: width, height: height, fill: background ?? .clear)
        let n = min(cells.count, width * height)
        for i in 0..<n {
            let v = Int(cells[i])
            guard v != 0, v < colors.count else { continue }
            let c = colors[v]
            let o = i * 4
            if c.a == 255 || img.bytes[o + 3] == 0 {
                img.bytes[o] = c.r; img.bytes[o + 1] = c.g; img.bytes[o + 2] = c.b; img.bytes[o + 3] = c.a
            } else {
                img[i % width, i / width] = c.over(img[i % width, i / width])
            }
        }
        return img
    }

    /// The color behind a scene's art: its background index, or the story's paper.
    public static func background(_ story: PixelStory, scene: PixelScene) -> Pixel32 {
        let colors = colors(story)
        if scene.background > 0, scene.background < colors.count { return colors[scene.background] }
        return Pixel32(story.paper)
    }

    /// A scene frame at grid size, with onion ghosts drawn under it (for the editor).
    public static func editorFrame(_ story: PixelStory, scene s: Int, frame f: Int, onion: PixelOnion) -> RGBAImage {
        guard story.scenes.indices.contains(s) else { return RGBAImage(width: story.width, height: story.height) }
        let scene = story.scenes[s]
        let colors = colors(story)
        var img = RGBAImage(width: story.width, height: story.height, fill: background(story, scene: scene))
        for g in onion.ghosts(current: f, count: scene.frames.count) {
            let cells = scene.frames[g.index].cells
            for i in 0..<min(cells.count, story.cellCount) {
                let v = Int(cells[i])
                guard v != 0, v < colors.count else { continue }
                // Tinted ghost: the color pulled toward the tint, then faded.
                let c = colors[v].mixed(with: g.tint, 0.55)
                let a = UInt8(min(255, max(0, (g.alpha * 255).rounded())))
                img.set(i % story.width, i / story.width, Pixel32(c.r, c.g, c.b, a), blend: true)
            }
        }
        guard scene.frames.indices.contains(f) else { return img }
        img.draw(frame(scene.frames[f].cells, width: story.width, height: story.height, colors: colors, background: nil), x: 0, y: 0)
        return img
    }
}
