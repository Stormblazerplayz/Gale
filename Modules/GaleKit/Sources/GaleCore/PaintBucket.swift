import Foundation
import GaleFormat

/// The paint bucket: fills the area you tap that's closed in by lines.
/// Small gaps in the lines are closed for you, so a sketchy outline still fills.
public enum PaintBucket {
    /// A pixel grid at a lower resolution than the canvas.
    struct Grid {
        let w: Int
        let h: Int
        let scale: Double
        var cells: [UInt8]   // 0 open, 1 wall, 2 filled

        init(width: Double, height: Double, resolution: Int) {
            let s = min(1, Double(max(16, resolution)) / max(width, height))
            scale = s
            w = max(1, Int((width * s).rounded(.up)))
            h = max(1, Int((height * s).rounded(.up)))
            cells = [UInt8](repeating: 0, count: w * h)
        }

        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }

        mutating func disk(_ cx: Double, _ cy: Double, _ r: Double, value: UInt8) {
            let x0 = max(0, Int((cx - r).rounded(.down))), x1 = min(w - 1, Int((cx + r).rounded(.up)))
            let y0 = max(0, Int((cy - r).rounded(.down))), y1 = min(h - 1, Int((cy + r).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { return }
            let r2 = r * r
            for y in y0...y1 {
                let dy = Double(y) + 0.5 - cy
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - cx
                    if dx * dx + dy * dy <= r2 { cells[y * w + x] = value }
                }
            }
        }
    }

    /// The outline of the filled area (flat x, y list in canvas pixels), or nil if you tapped on a line.
    public static func fill(cel: Cel, canvasWidth: Double, canvasHeight: Double, seed: Vec2,
                            gapClose: Double = 4, resolution: Int = 1024) -> [Double]? {
        var g = Grid(width: canvasWidth, height: canvasHeight, resolution: resolution)
        let s = g.scale
        // 1. Draw the lines as walls (thickened a bit to close small gaps). Erasers cut them back out.
        for stroke in cel.strokes where !stroke.points.isEmpty {
            let isEraser = stroke.brush.kind == .eraser
            let pts = StrokeShape.densify(StrokeShape.dedupe(stroke.points), spacing: max(1, 1 / s))
            let n = pts.count
            for (i, p) in pts.enumerated() {
                let w = StrokeShape.width(of: p, brush: stroke.brush, index: i, count: n)
                let r = isEraser ? (w / 2) * s : (w / 2 + gapClose) * s
                g.disk(p.x * s, p.y * s, max(0.6, r), value: isEraser ? 0 : 1)
            }
        }
        // 2. Flood from the tapped spot.
        let sx = Int(seed.x * s), sy = Int(seed.y * s)
        guard g.inside(sx, sy), g.cells[sy * g.w + sx] == 0 else { return nil }
        var stack = [sy * g.w + sx]
        g.cells[sy * g.w + sx] = 2
        var count = 0
        while let i = stack.popLast() {
            count += 1
            let x = i % g.w, y = i / g.w
            if x > 0 && g.cells[i - 1] == 0 { g.cells[i - 1] = 2; stack.append(i - 1) }
            if x < g.w - 1 && g.cells[i + 1] == 0 { g.cells[i + 1] = 2; stack.append(i + 1) }
            if y > 0 && g.cells[i - g.w] == 0 { g.cells[i - g.w] = 2; stack.append(i - g.w) }
            if y < g.h - 1 && g.cells[i + g.w] == 0 { g.cells[i + g.w] = 2; stack.append(i + g.w) }
        }
        guard count > 0 else { return nil }
        // 3. Grow the fill under the lines, so no white rim shows between fill and line.
        let grow = max(1, Int((gapClose * s).rounded(.up)) + 1)
        var mask = [Bool](repeating: false, count: g.w * g.h)
        for i in 0..<mask.count where g.cells[i] == 2 { mask[i] = true }
        mask = dilate(mask, w: g.w, h: g.h, radius: grow, limit: g.cells)
        // 4. Trace the outside edge and turn it back into canvas pixels.
        guard let contour = trace(mask, w: g.w, h: g.h) else { return nil }
        let pts = contour.map { Vec2((Double($0.x) + 0.5) / s, (Double($0.y) + 0.5) / s) }
        let simple = Geometry.simplify(pts + [pts[0]], tolerance: 0.7 / s).dropLast()
        guard simple.count >= 3 else { return nil }
        return simple.flatMap { [($0.x * 100).rounded() / 100, ($0.y * 100).rounded() / 100] }
    }

    /// Grows `mask` by `radius` cells, but only into wall cells (so a fill never spills into a neighbor area).
    static func dilate(_ mask: [Bool], w: Int, h: Int, radius: Int, limit: [UInt8]) -> [Bool] {
        var cur = mask
        for _ in 0..<radius {
            var next = cur
            for y in 0..<h {
                for x in 0..<w where !cur[y * w + x] && limit[y * w + x] == 1 {
                    if (x > 0 && cur[y * w + x - 1]) || (x < w - 1 && cur[y * w + x + 1]) ||
                        (y > 0 && cur[(y - 1) * w + x]) || (y < h - 1 && cur[(y + 1) * w + x]) {
                        next[y * w + x] = true
                    }
                }
            }
            cur = next
        }
        return cur
    }

    struct Cell: Hashable { var x: Int; var y: Int }

    /// Moore-neighbor tracing of the outer edge of the region holding the first filled cell.
    static func trace(_ mask: [Bool], w: Int, h: Int) -> [Cell]? {
        guard let first = mask.firstIndex(of: true) else { return nil }
        let start = Cell(x: first % w, y: first / w)
        func filled(_ c: Cell) -> Bool { c.x >= 0 && c.y >= 0 && c.x < w && c.y < h && mask[c.y * w + c.x] }
        // Clockwise starting from west.
        let dirs = [Cell(x: -1, y: 0), Cell(x: -1, y: -1), Cell(x: 0, y: -1), Cell(x: 1, y: -1),
                    Cell(x: 1, y: 0), Cell(x: 1, y: 1), Cell(x: 0, y: 1), Cell(x: -1, y: 1)]
        func dirIndex(_ dx: Int, _ dy: Int) -> Int {
            dirs.firstIndex { $0.x == dx && $0.y == dy } ?? 0
        }
        var contour = [start]
        var p = start
        var back = 0          // the cell we came from is p + dirs[back]
        let startBack = 0
        var steps = 0
        let maxSteps = 4 * w * h + 16
        while steps < maxSteps {
            steps += 1
            var found: Cell?
            var foundBack = 0
            for i in 1...8 {
                let idx = (back + i) % 8
                let c = Cell(x: p.x + dirs[idx].x, y: p.y + dirs[idx].y)
                if filled(c) {
                    let prev = (idx + 7) % 8
                    let b = Cell(x: p.x + dirs[prev].x, y: p.y + dirs[prev].y)
                    found = c
                    foundBack = dirIndex(b.x - c.x, b.y - c.y)
                    break
                }
            }
            guard let next = found else { return contour }   // a single cell
            if next == start && foundBack == startBack { break }
            if next == start && contour.count > 2 && steps > 2 * contour.count { break }
            p = next
            back = foundBack
            if p == start { continue }
            contour.append(p)
        }
        return contour
    }
}
