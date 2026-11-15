import Foundation
import GaleFormat

/// Makes shaky lines smooth while you draw.
///
/// It works like a "pulled string": the brush sits at the end of an invisible string and only moves
/// when your finger or pencil pulls the string tight. Small wobbles never pull it, so they vanish.
/// On top of that, the brush glides toward where it's pulled instead of jumping.
///
/// `amount` 0 draws exactly where you touch. 1 is the strongest smoothing.
public final class StrokeStabilizer {
    public private(set) var amount: Double
    /// Canvas pixels per screen point, so the string feels the same at any zoom.
    public var scale: Double

    private var lazy: Vec2 = .zero
    private var out: Vec2 = .zero
    private var outPressure: Double = 0.5
    private var cursor: StrokePoint?
    private var lastEmitted: Vec2?
    private var started = false

    public init(amount: Double, scale: Double = 1) {
        self.amount = min(1, max(0, amount))
        self.scale = max(0.01, scale)
    }

    /// Length of the string in canvas pixels.
    public var stringLength: Double { pow(amount, 1.2) * 34 * scale }
    /// How quickly the brush glides (1 = instantly).
    var glide: Double { 1 - 0.78 * amount }

    public func begin(_ p: StrokePoint) -> [StrokePoint] {
        started = true
        lazy = Vec2(p)
        out = lazy
        outPressure = p.pressure
        cursor = p
        lastEmitted = out
        return [p]
    }

    public func add(_ p: StrokePoint) -> [StrokePoint] {
        guard started else { return begin(p) }
        cursor = p
        if amount <= 0.001 {
            return emit(Vec2(p), from: p, pressure: p.pressure)
        }
        let target = Vec2(p)
        let d = lazy.distance(to: target)
        let r = stringLength
        if d > r {
            lazy = lazy + (target - lazy) * ((d - r) / d)
        }
        let a = glide
        out = out + (lazy - out) * a
        outPressure += (p.pressure - outPressure) * min(1, a + 0.2)
        return emit(out, from: p, pressure: outPressure)
    }

    /// Finishes the line where you lifted, gliding in smoothly.
    public func end() -> [StrokePoint] {
        defer { started = false }
        guard started, let c = cursor else { return [] }
        let target = Vec2(c)
        let gap = out.distance(to: target)
        if gap < 0.75 || amount <= 0.001 { return [] }
        var result: [StrokePoint] = []
        let steps = max(1, Int((gap / 2).rounded(.up)))
        let start = out
        for i in 1...steps {
            // Ease out so the end doesn't look like a straight tail.
            let t = Double(i) / Double(steps)
            let e = 1 - (1 - t) * (1 - t)
            let pos = Vec2.lerp(start, target, e)
            var p = c
            p.x = pos.x
            p.y = pos.y
            p.pressure = outPressure + (c.pressure - outPressure) * t
            result.append(p)
        }
        out = target
        lastEmitted = target
        return result
    }

    private func emit(_ pos: Vec2, from p: StrokePoint, pressure: Double) -> [StrokePoint] {
        if let last = lastEmitted, last.distance(to: pos) < 0.35 { return [] }
        lastEmitted = pos
        var q = p
        q.x = pos.x
        q.y = pos.y
        q.pressure = pressure
        return [q]
    }

    /// Runs a whole list of points through a fresh stabilizer (for tests, imports and replays).
    public static func stabilize(_ points: [StrokePoint], amount: Double, scale: Double = 1) -> [StrokePoint] {
        guard let first = points.first else { return [] }
        let s = StrokeStabilizer(amount: amount, scale: scale)
        var out = s.begin(first)
        for p in points.dropFirst() { out += s.add(p) }
        out += s.end()
        return out
    }
}

/// A last smoothing pass when a stroke is finished: evens out positions and pressure
/// while keeping both ends exactly where they are.
public enum StrokeSmoother {
    public static func smooth(_ points: [StrokePoint], amount: Double) -> [StrokePoint] {
        let a = min(1, max(0, amount))
        guard points.count > 3, a > 0.01 else { return points }
        let radius = max(1, Int((a * 4).rounded()))
        let passes = a > 0.5 ? 2 : 1
        var pts = points
        for _ in 0..<passes {
            var next = pts
            for i in 1..<(pts.count - 1) {
                let r = min(radius, i, pts.count - 1 - i)
                var sx = 0.0, sy = 0.0, sp = 0.0, sw = 0.0
                for k in -r...r {
                    let w = Double(r + 1 - abs(k))
                    let q = pts[i + k]
                    sx += q.x * w
                    sy += q.y * w
                    sp += q.pressure * w
                    sw += w
                }
                next[i].x = sx / sw
                next[i].y = sy / sw
                next[i].pressure = sp / sw
            }
            pts = next
        }
        return pts
    }
}
