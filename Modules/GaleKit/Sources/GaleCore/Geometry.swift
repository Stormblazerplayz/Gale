import Foundation
import GaleFormat

/// A 2D point or direction.
public struct Vec2: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ p: StrokePoint) {
        x = p.x
        y = p.y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    /// Turned 90 degrees.
    public var perpendicular: Vec2 { Vec2(-y, x) }

    public var normalized: Vec2 {
        let l = length
        return l > 1e-12 ? self / l : .zero
    }

    public func distance(to o: Vec2) -> Double { (self - o).length }

    public static func lerp(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 { a + (b - a) * t }
}

/// An axis-aligned box.
public struct Box: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// An empty box that any union replaces.
    public static let empty = Box(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public var isEmpty: Bool { minX > maxX || minY > maxY }
    public var width: Double { isEmpty ? 0 : maxX - minX }
    public var height: Double { isEmpty ? 0 : maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }
    public var diagonal: Double { (width * width + height * height).squareRoot() }
    public var maxSide: Double { max(width, height) }

    public mutating func add(_ p: Vec2) {
        minX = min(minX, p.x)
        minY = min(minY, p.y)
        maxX = max(maxX, p.x)
        maxY = max(maxY, p.y)
    }

    public func union(_ o: Box) -> Box {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return Box(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    public func inset(by d: Double) -> Box {
        isEmpty ? self : Box(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }

    public func intersects(_ o: Box) -> Bool {
        !isEmpty && !o.isEmpty && minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY
    }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    /// x, y, width, height (how stash items store it).
    public var xywh: [Double] { [minX, minY, width, height] }
}

public enum Geometry {
    /// Box around a stroke, including half its width.
    public static func bounds(of stroke: Stroke) -> Box {
        var b = Box.empty
        for p in stroke.points { b.add(Vec2(p)) }
        return b.inset(by: -stroke.brush.size / 2)
    }

    public static func bounds(of strokes: [Stroke]) -> Box {
        strokes.reduce(Box.empty) { $0.union(bounds(of: $1)) }
    }

    public static func bounds(ofPath path: [Double]) -> Box {
        var b = Box.empty
        var i = 0
        while i + 1 < path.count {
            b.add(Vec2(path[i], path[i + 1]))
            i += 2
        }
        return b
    }

    /// Even-odd point-in-polygon test. `poly` is x, y, x, y...
    public static func contains(_ poly: [Double], _ p: Vec2) -> Bool {
        let n = poly.count / 2
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let xi = poly[2 * i], yi = poly[2 * i + 1]
            let xj = poly[2 * j], yj = poly[2 * j + 1]
            if (yi > p.y) != (yj > p.y) {
                let x = (xj - xi) * (p.y - yi) / (yj - yi) + xi
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Shortest distance from p to the outline of a closed polygon.
    public static func distanceToOutline(_ poly: [Double], _ p: Vec2) -> Double {
        let n = poly.count / 2
        guard n >= 2 else { return .infinity }
        var best = Double.infinity
        for i in 0..<n {
            let j = (i + 1) % n
            let a = Vec2(poly[2 * i], poly[2 * i + 1])
            let b = Vec2(poly[2 * j], poly[2 * j + 1])
            best = min(best, distanceToSegment(p, a, b))
        }
        return best
    }

    public static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let l2 = ab.lengthSquared
        if l2 < 1e-12 { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / l2))
        return p.distance(to: a + ab * t)
    }

    public static func centroid(of strokes: [Stroke]) -> Vec2 {
        var sum = Vec2.zero
        var n = 0.0
        for s in strokes {
            for p in s.points {
                sum = sum + Vec2(p)
                n += 1
            }
        }
        return n > 0 ? sum / n : .zero
    }

    /// Douglas-Peucker line simplification.
    public static func simplify(_ pts: [Vec2], tolerance: Double) -> [Vec2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            var maxD = 0.0
            var idx = s
            if e - s < 2 { continue }
            for i in (s + 1)..<e {
                let d = distanceToSegment(pts[i], pts[s], pts[e])
                if d > maxD {
                    maxD = d
                    idx = i
                }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }
}

/// Moving, scaling and flipping strokes.
public enum StrokeTransform {
    public static func translate(_ strokes: [Stroke], dx: Double, dy: Double) -> [Stroke] {
        strokes.map { s in
            var s = s
            s.points = s.points.map { p in
                var p = p
                p.x += dx
                p.y += dy
                return p
            }
            return s
        }
    }

    public static func translate(_ fills: [Fill], dx: Double, dy: Double) -> [Fill] {
        fills.map { f in
            var f = f
            for i in stride(from: 0, to: f.path.count - 1, by: 2) {
                f.path[i] += dx
                f.path[i + 1] += dy
            }
            return f
        }
    }

    /// Scales around `origin`. Brush sizes scale too.
    public static func scale(_ strokes: [Stroke], by k: Double, around origin: Vec2) -> [Stroke] {
        strokes.map { s in
            var s = s
            s.brush.size *= k
            s.points = s.points.map { p in
                var p = p
                p.x = origin.x + (p.x - origin.x) * k
                p.y = origin.y + (p.y - origin.y) * k
                return p
            }
            return s
        }
    }

    public static func scale(_ fills: [Fill], by k: Double, around origin: Vec2) -> [Fill] {
        fills.map { f in
            var f = f
            for i in stride(from: 0, to: f.path.count - 1, by: 2) {
                f.path[i] = origin.x + (f.path[i] - origin.x) * k
                f.path[i + 1] = origin.y + (f.path[i + 1] - origin.y) * k
            }
            return f
        }
    }

    /// Mirror left-right around the vertical line x = axis. Pencil lean flips too.
    public static func flipHorizontally(_ strokes: [Stroke], axis: Double) -> [Stroke] {
        strokes.map { s in
            var s = s
            s.points = s.points.map { p in
                var p = p
                p.x = 2 * axis - p.x
                p.azimuth = Double.pi - p.azimuth
                return p
            }
            return s
        }
    }

    public static func flipHorizontally(_ fills: [Fill], axis: Double) -> [Fill] {
        fills.map { f in
            var f = f
            for i in stride(from: 0, to: f.path.count - 1, by: 2) {
                f.path[i] = 2 * axis - f.path[i]
            }
            return f
        }
    }

    /// Copies with brand-new ids (so pasted things never clash with the originals).
    public static func freshIDs(_ strokes: [Stroke]) -> [Stroke] {
        strokes.map { s in
            var s = s
            s.id = GaleID.make()
            return s
        }
    }

    public static func freshIDs(_ fills: [Fill]) -> [Fill] {
        fills.map { f in
            var f = f
            f.id = GaleID.make()
            return f
        }
    }
}
