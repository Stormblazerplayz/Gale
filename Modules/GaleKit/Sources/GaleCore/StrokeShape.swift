import Foundation
import GaleFormat

/// Turns stroke points into the shape that gets painted: how wide each point is,
/// how see-through it is, and the outline to fill.
public enum StrokeShape {
    /// Width at one point, in canvas pixels.
    public static func width(of p: StrokePoint, brush: Brush, index: Int, count: Int) -> Double {
        let size = max(0.5, brush.size)
        let pr = min(1, max(0, p.pressure))
        var w: Double
        switch brush.kind {
        case .pen:
            w = size * (0.28 + 0.72 * pow(pr, 0.8))
        case .pencil:
            // Leaning the pencil over shades with its side, like a real pencil.
            let upright = min(1, max(0, p.altitude / (Double.pi / 2)))
            let lean = pow(1 - upright, 2)
            w = size * (0.5 + 0.5 * pr) * (1 + 2.2 * lean)
        case .marker:
            w = size * (0.85 + 0.15 * pr)
        case .brush:
            w = size * (0.08 + 0.92 * pow(pr, 1.3))
        case .airbrush:
            w = size
        case .eraser:
            w = size * (0.6 + 0.4 * pr)
        }
        // Pointy ends for inked lines.
        if (brush.kind == .pen || brush.kind == .brush) && count > 4 {
            let ramp = min(6, count / 3)
            if ramp > 0 {
                let fromStart = Double(index) / Double(ramp)
                let fromEnd = Double(count - 1 - index) / Double(ramp)
                let t = min(1, min(fromStart, fromEnd))
                w *= 0.35 + 0.65 * t
            }
        }
        return max(0.3, w)
    }

    public static func widths(of stroke: Stroke) -> [Double] {
        let n = stroke.points.count
        return stroke.points.enumerated().map { width(of: $0.element, brush: stroke.brush, index: $0.offset, count: n) }
    }

    /// How opaque the whole stroke is.
    public static func alpha(of stroke: Stroke) -> Double {
        let base = stroke.brush.color.a * stroke.brush.opacity
        switch stroke.brush.kind {
        case .pencil:
            let avg = stroke.points.isEmpty ? 0.5 : stroke.points.reduce(0) { $0 + $1.pressure } / Double(stroke.points.count)
            return base * (0.55 + 0.45 * avg)
        case .marker:
            return base * 0.8
        case .airbrush:
            return base * 0.35
        default:
            return base
        }
    }

    /// Adds points between far-apart samples along a smooth curve (Catmull-Rom), so fast strokes stay round.
    public static func densify(_ pts: [StrokePoint], spacing: Double = 3) -> [StrokePoint] {
        guard pts.count > 1 else { return pts }
        var out: [StrokePoint] = [pts[0]]
        out.reserveCapacity(pts.count * 2)
        for i in 0..<(pts.count - 1) {
            let p0 = Vec2(pts[max(0, i - 1)])
            let p1 = Vec2(pts[i])
            let p2 = Vec2(pts[i + 1])
            let p3 = Vec2(pts[min(pts.count - 1, i + 2)])
            let d = p1.distance(to: p2)
            let n = Int(d / max(0.5, spacing))
            if n > 1 {
                for k in 1..<n {
                    let t = Double(k) / Double(n)
                    let t2 = t * t, t3 = t2 * t
                    let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                    let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                    var q = pts[i]
                    q.x = x
                    q.y = y
                    q.pressure = pts[i].pressure + (pts[i + 1].pressure - pts[i].pressure) * t
                    q.altitude = pts[i].altitude + (pts[i + 1].altitude - pts[i].altitude) * t
                    q.time = pts[i].time + (pts[i + 1].time - pts[i].time) * t
                    out.append(q)
                }
            }
            out.append(pts[i + 1])
        }
        return out
    }

    /// The filled outline of a stroke (a closed polygon). Fill it with the non-zero rule.
    public static func outline(of stroke: Stroke, spacing: Double = 3) -> [Vec2] {
        let curved = densify(dedupe(stroke.points), spacing: spacing)
        // Even steps along the line: tiny uneven steps are what make kinks in the edges.
        let step = max(0.75, min(spacing, stroke.brush.size * 0.2))
        let pts = resample(curved, spacing: step)
        let n = pts.count
        var ws = pts.enumerated().map { width(of: $0.element, brush: stroke.brush, index: $0.offset, count: n) }
        ws = smoothValues(ws, radius: 2)
        return outline(points: pts.map { Vec2($0) }, widths: ws)
    }

    /// Points spread evenly along the line, `spacing` canvas pixels apart. Keeps the first and last point.
    public static func resample(_ pts: [StrokePoint], spacing: Double) -> [StrokePoint] {
        guard pts.count > 1 else { return pts }
        let step = max(0.05, spacing)
        var out: [StrokePoint] = [pts[0]]
        out.reserveCapacity(pts.count)
        var carried = 0.0 // distance walked since the last point we kept
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let seg = Vec2(a).distance(to: Vec2(b))
            if seg <= 0 { continue }
            var at = step - carried
            while at <= seg {
                let t = at / seg
                var q = a
                q.x = a.x + (b.x - a.x) * t
                q.y = a.y + (b.y - a.y) * t
                q.pressure = a.pressure + (b.pressure - a.pressure) * t
                q.altitude = a.altitude + (b.altitude - a.altitude) * t
                q.azimuth = a.azimuth + (b.azimuth - a.azimuth) * t
                q.time = a.time + (b.time - a.time) * t
                out.append(q)
                at += step
            }
            carried = seg - (at - step)
        }
        let last = pts[pts.count - 1]
        if let end = out.last, Vec2(end).distance(to: Vec2(last)) > step * 0.35 {
            out.append(last)
        } else if out.count > 1 {
            out[out.count - 1] = last
        } else if Vec2(pts[0]).distance(to: Vec2(last)) > 0 {
            out.append(last)
        }
        return out
    }

    /// Evens out a list of numbers (like widths) with their neighbours.
    static func smoothValues(_ v: [Double], radius: Int) -> [Double] {
        guard v.count > 2, radius > 0 else { return v }
        var out = v
        for i in 0..<v.count {
            let lo = max(0, i - radius), hi = min(v.count - 1, i + radius)
            var s = 0.0, w = 0.0
            for k in lo...hi {
                let wk = Double(radius + 1 - abs(k - i))
                s += v[k] * wk
                w += wk
            }
            out[i] = s / w
        }
        return out
    }

    /// The sharpest bend in a line, in degrees, measured over steps of `spacing` canvas pixels.
    /// A smooth curve stays low; a kink or corner shows up as a big number.
    public static func sharpestBend(_ pts: [StrokePoint], spacing: Double = 4) -> Double {
        let even = resample(dedupe(pts), spacing: spacing)
        guard even.count > 2 else { return 0 }
        var worst = 0.0
        for i in 1..<(even.count - 1) {
            let d1 = Vec2(even[i]) - Vec2(even[i - 1])
            let d2 = Vec2(even[i + 1]) - Vec2(even[i])
            guard d1.length > spacing * 0.5, d2.length > spacing * 0.5 else { continue }
            let c = max(-1, min(1, d1.normalized.dot(d2.normalized)))
            worst = max(worst, acos(c) * 180 / Double.pi)
        }
        return worst
    }

    /// Outline from centers and widths: a round cap, one side, a round cap, the other side.
    public static func outline(points: [Vec2], widths: [Double]) -> [Vec2] {
        guard let first = points.first else { return [] }
        if points.count == 1 {
            return circle(center: first, radius: (widths.first ?? 1) / 2)
        }
        let n = points.count
        var normals: [Vec2] = []
        normals.reserveCapacity(n)
        for i in 0..<n {
            // Looking two points each way keeps the edges from wobbling on tiny steps.
            let a = points[max(0, i - 2)]
            let b = points[min(n - 1, i + 2)]
            var dir = (b - a).normalized
            if dir == .zero { dir = Vec2(1, 0) }
            normals.append(dir.perpendicular)
        }
        var left: [Vec2] = []
        var right: [Vec2] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0..<n {
            let h = widths[i] / 2
            left.append(points[i] + normals[i] * h)
            right.append(points[i] - normals[i] * h)
        }
        var poly: [Vec2] = []
        poly.reserveCapacity(n * 2 + 32)
        poly.append(contentsOf: left)
        // End cap: half circle from left to right around the last point.
        poly.append(contentsOf: arc(center: points[n - 1], radius: widths[n - 1] / 2, from: normals[n - 1], clockwise: true))
        poly.append(contentsOf: right.reversed())
        // Start cap: half circle from right back to left around the first point.
        poly.append(contentsOf: arc(center: points[0], radius: widths[0] / 2, from: -normals[0], clockwise: true))
        return poly
    }

    static func circle(center: Vec2, radius: Double, segments: Int = 16) -> [Vec2] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * Double.pi
            return center + Vec2(cos(a), sin(a)) * radius
        }
    }

    /// Points on a half circle, starting at direction `from`, sweeping 180 degrees (not including the ends).
    static func arc(center: Vec2, radius: Double, from: Vec2, clockwise: Bool, segments: Int = 8) -> [Vec2] {
        let start = atan2(from.y, from.x)
        return (1..<segments).map { i in
            let t = Double(i) / Double(segments)
            let a = start + (clockwise ? -1.0 : 1.0) * t * Double.pi
            return center + Vec2(cos(a), sin(a)) * radius
        }
    }

    /// Drops points that sit on top of the one before.
    public static func dedupe(_ pts: [StrokePoint], minDistance: Double = 0.05) -> [StrokePoint] {
        guard var last = pts.first else { return [] }
        var out = [last]
        for p in pts.dropFirst() where Vec2(p).distance(to: Vec2(last)) >= minDistance {
            out.append(p)
            last = p
        }
        if out.count == 1, let end = pts.last, pts.count > 1 { out.append(end) }
        return out
    }

    /// Centers for airbrush puffs along the stroke, with each puff's radius.
    public static func airbrushDabs(of stroke: Stroke) -> [(center: Vec2, radius: Double, pressure: Double)] {
        let pts = densify(dedupe(stroke.points), spacing: max(1, stroke.brush.size / 6))
        var out: [(Vec2, Double, Double)] = []
        var lastPos: Vec2?
        let step = max(1, stroke.brush.size / 5)
        for p in pts {
            let v = Vec2(p)
            if let l = lastPos, l.distance(to: v) < step { continue }
            lastPos = v
            out.append((v, max(1, stroke.brush.size / 2), p.pressure))
        }
        return out
    }
}
