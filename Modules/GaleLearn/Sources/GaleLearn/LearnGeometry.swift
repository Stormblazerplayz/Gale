import Foundation

/// A point in lesson space. Lesson space is 1 unit tall and `aspect` units wide (4:3 by default),
/// with (0, 0) at the top left and y going down, like the screen.
public struct LearnPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = LearnPoint(0, 0)

    public static func + (a: LearnPoint, b: LearnPoint) -> LearnPoint { LearnPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: LearnPoint, b: LearnPoint) -> LearnPoint { LearnPoint(a.x - b.x, a.y - b.y) }
    public static func * (a: LearnPoint, s: Double) -> LearnPoint { LearnPoint(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to o: LearnPoint) -> Double { (self - o).length }
    public func dot(_ o: LearnPoint) -> Double { x * o.x + y * o.y }
    public var isFinite: Bool { x.isFinite && y.isFinite }

    public static func lerp(_ a: LearnPoint, _ b: LearnPoint, _ t: Double) -> LearnPoint { a + (b - a) * t }
}

/// What a guide line is for.
public enum LearnPathRole: String, Codable, Hashable, Sendable, CaseIterable {
    /// The real drawing. Trace steps score against these lines.
    case ink
    /// Helper lines (construction, horizon, vanishing lines). Shown light and dashed, never scored.
    case guide
    /// Highlights such as motion paths and arcs. Shown in the accent color, never scored.
    case accent
}

/// One line of a guide drawing.
public struct LearnPath: Codable, Hashable, Sendable {
    public var points: [LearnPoint]
    public var role: LearnPathRole
    /// Line width in lesson units (1 = the full height).
    public var width: Double
    /// The last point joins back to the first.
    public var closed: Bool

    public static let defaultWidth = 0.012

    public init(points: [LearnPoint], role: LearnPathRole = .ink, width: Double = LearnPath.defaultWidth, closed: Bool = false) {
        self.points = points
        self.role = role
        self.width = width
        self.closed = closed
    }

    /// The points to draw through (the first point is repeated at the end when closed).
    public var polyline: [LearnPoint] {
        guard closed, let first = points.first, points.count > 2 else { return points }
        if let last = points.last, last.distance(to: first) < 1e-9 { return points }
        return points + [first]
    }

    enum CodingKeys: String, CodingKey {
        case pts, role, width = "w", closed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let flat = try c.decode([Double].self, forKey: .pts)
        guard flat.count % 2 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .pts, in: c, debugDescription: "pts needs x, y pairs")
        }
        var pts: [LearnPoint] = []
        pts.reserveCapacity(flat.count / 2)
        var i = 0
        while i + 1 < flat.count {
            pts.append(LearnPoint(flat[i], flat[i + 1]))
            i += 2
        }
        points = pts
        role = try c.decodeIfPresent(LearnPathRole.self, forKey: .role) ?? .ink
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? LearnPath.defaultWidth
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 2)
        for p in points {
            flat.append(p.x)
            flat.append(p.y)
        }
        try c.encode(flat, forKey: .pts)
        if role != .ink { try c.encode(role, forKey: .role) }
        if width != LearnPath.defaultWidth { try c.encode(width, forKey: .width) }
        if closed { try c.encode(closed, forKey: .closed) }
    }
}

/// Small geometry helpers used by scoring and checks.
public enum LearnGeometry {
    /// Total length of a line through the points.
    public static func length(_ pts: [LearnPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i - 1].distance(to: pts[i]) }
        return total
    }

    /// Points spaced `spacing` apart along the line (both ends included).
    public static func resample(_ pts: [LearnPoint], spacing: Double) -> [LearnPoint] {
        guard let first = pts.first else { return [] }
        guard pts.count > 1, spacing > 0 else { return [first] }
        var out = [first]
        var carry = 0.0
        for i in 1..<pts.count {
            let a = pts[i - 1]
            let b = pts[i]
            let seg = a.distance(to: b)
            if seg < 1e-12 { continue }
            var t = spacing - carry
            while t <= seg {
                out.append(LearnPoint.lerp(a, b, t / seg))
                t += spacing
            }
            carry = seg - (t - spacing)
        }
        if let last = pts.last, let end = out.last, end.distance(to: last) > spacing * 0.05 {
            out.append(last)
        }
        return out
    }

    public static func distanceToSegment(_ p: LearnPoint, _ a: LearnPoint, _ b: LearnPoint) -> Double {
        let ab = b - a
        let l2 = ab.dot(ab)
        if l2 < 1e-18 { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / l2))
        return p.distance(to: a + ab * t)
    }

    /// Shortest distance from `p` to any of the lines (a single point counts as a dot).
    public static func distance(_ p: LearnPoint, toLines lines: [[LearnPoint]]) -> Double {
        var best = Double.infinity
        for line in lines {
            if line.count == 1 {
                best = min(best, p.distance(to: line[0]))
                continue
            }
            guard line.count > 1 else { continue }
            for i in 1..<line.count {
                let d = distanceToSegment(p, line[i - 1], line[i])
                if d < best { best = d }
            }
        }
        return best
    }

    /// Middle of the drawing, weighted by ink length so dense point spacing doesn't pull it.
    public static func centroid(_ strokes: [[LearnPoint]]) -> LearnPoint? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for s in strokes {
            for p in resample(s, spacing: 0.01) {
                sx += p.x
                sy += p.y
                n += 1
            }
        }
        return n > 0 ? LearnPoint(sx / n, sy / n) : nil
    }

    /// How different two drawings are: the average gap between their lines, both ways.
    public static func chamfer(_ a: [[LearnPoint]], _ b: [[LearnPoint]]) -> Double {
        let sa = a.flatMap { resample($0, spacing: 0.02) }
        let sb = b.flatMap { resample($0, spacing: 0.02) }
        guard !sa.isEmpty, !sb.isEmpty else { return .infinity }
        let ab = sa.reduce(0.0) { $0 + distance($1, toLines: b) } / Double(sa.count)
        let ba = sb.reduce(0.0) { $0 + distance($1, toLines: a) } / Double(sb.count)
        return (ab + ba) / 2
    }
}

/// A rough place on the page, for hints like "near the top left".
public enum LearnArea: String, Hashable, Sendable, CaseIterable {
    case topLeft, top, topRight, left, middle, right, bottomLeft, bottom, bottomRight

    public init(point: LearnPoint, aspect: Double) {
        let w = max(0.1, aspect)
        let col = point.x < w / 3 ? 0 : (point.x < 2 * w / 3 ? 1 : 2)
        let row = point.y < 1.0 / 3 ? 0 : (point.y < 2.0 / 3 ? 1 : 2)
        let all: [[LearnArea]] = [[.topLeft, .top, .topRight], [.left, .middle, .right], [.bottomLeft, .bottom, .bottomRight]]
        self = all[row][col]
    }

    /// Words for a hint: "near the top left".
    public var words: String {
        switch self {
        case .topLeft: return "the top left"
        case .top: return "the top"
        case .topRight: return "the top right"
        case .left: return "the left side"
        case .middle: return "the middle"
        case .right: return "the right side"
        case .bottomLeft: return "the bottom left"
        case .bottom: return "the bottom"
        case .bottomRight: return "the bottom right"
        }
    }
}
