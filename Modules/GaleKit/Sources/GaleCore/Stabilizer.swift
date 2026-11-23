import Foundation
import GaleFormat

/// The smoothing strength Gale starts with, and the numbers both smoothing steps share.
public enum StrokeSmoothing {
    /// Light by default, so faces, eyes and small curves come out the way you drew them.
    /// 0 is off. Shaky hands can turn it up with the slider.
    public static let defaultAmount: Double = 0.25

    /// How a smoothing amount reads in the app: "Off" or a percentage.
    public static func label(_ amount: Double) -> String {
        let a = min(1, max(0, amount))
        if a < 0.005 { return "Off" }
        return "\(Int((a * 100).rounded()))%"
    }

    /// A bend sharper than this (in degrees) is a corner you meant, so it's kept sharp.
    public static let cornerAngle: Double = 60
    /// How far each way (in screen points) a bend is measured to decide if it's a corner.
    /// Long enough that hand shake doesn't look like a corner, short enough for an eye's corner.
    public static let cornerArm: Double = 6
    /// Below this amount the live "pulled string" is off and only the finishing step smooths.
    public static let stringStarts: Double = 0.35

    /// Runs the finishing step the canvas uses (while drawing and when you lift):
    /// evens out wobbles but keeps corners and short strokes the way you drew them.
    /// `scale` is canvas pixels per screen point, so it feels the same at any zoom.
    public static func shape(_ points: [StrokePoint], amount: Double, scale: Double = 1) -> [StrokePoint] {
        let a = min(1, max(0, amount))
        guard a > 0.005 else { return points }
        let s = max(0.01, scale)
        return StrokeSmoother.round(points, radius: StrokeSmoother.radius(amount: a, scale: s),
                                    cornerArm: cornerArm * s, cornerAngle: cornerAngle)
    }

    /// The whole pipeline on a list of points: the live stabilizer, then the finishing step.
    /// The canvas does exactly this, one touch at a time. Used by tests, imports and replays.
    public static func finish(_ raw: [StrokePoint], amount: Double, scale: Double = 1) -> [StrokePoint] {
        let st = StrokeStabilizer.stabilize(raw, amount: amount, scale: scale)
        return shape(StrokeShape.dedupe(st), amount: amount, scale: scale)
    }
}

/// Makes shaky lines smooth while you draw.
///
/// It works like a "pulled string": the brush sits at the end of an invisible string and only moves
/// when your finger or pencil pulls the string tight. Small wobbles never pull it, so they vanish.
/// On top of that, the brush glides toward where it's pulled instead of jumping.
///
/// The string starts at zero and only grows as the line gets longer, so a short stroke
/// (an eye, a nostril, a dot) draws exactly where you touch. When you lift, the line catches up
/// to where the pen left the screen.
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
    private var lastTouch: Vec2 = .zero
    private var lastEmitted: Vec2?
    private var started = false
    /// How far the finger or pencil has moved in this stroke, in canvas pixels.
    public private(set) var traveled: Double = 0

    public init(amount: Double, scale: Double = 1) {
        self.amount = min(1, max(0, amount))
        self.scale = max(0.01, scale)
    }

    /// How hard the string pulls back. Light smoothing (up to `StrokeSmoothing.stringStarts`) has no string
    /// at all, so the line stays right under the pen and corners stay sharp; the finishing step evens out
    /// the wobbles instead. Above that the string grows for shaky hands.
    var pull: Double { max(0, (amount - StrokeSmoothing.stringStarts) / (1 - StrokeSmoothing.stringStarts)) }

    /// Longest the string gets, in canvas pixels (about 16 screen points at full strength).
    public var maxStringLength: Double { pow(pull, 1.3) * 16 * scale }

    /// Length of the string right now. It grows with the line, so short strokes keep their shape.
    public var stringLength: Double { min(maxStringLength, traveled * 0.1) }

    /// How quickly the brush glides (1 = instantly).
    var glide: Double { 1 - 0.6 * pull }

    public func begin(_ p: StrokePoint) -> [StrokePoint] {
        started = true
        traveled = 0
        lazy = Vec2(p)
        out = lazy
        lastTouch = lazy
        outPressure = p.pressure
        cursor = p
        lastEmitted = out
        return [p]
    }

    public func add(_ p: StrokePoint) -> [StrokePoint] {
        guard started else { return begin(p) }
        cursor = p
        let target = Vec2(p)
        traveled += lastTouch.distance(to: target)
        lastTouch = target
        if pull <= 0 {
            out = target
            lazy = target
            outPressure = p.pressure
            return emit(target, from: p, pressure: p.pressure)
        }
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

    /// Finishes the line where you lifted, gliding in smoothly, so the end is never cut short.
    public func end() -> [StrokePoint] {
        defer { started = false }
        guard started, let c = cursor else { return [] }
        let target = Vec2(c)
        let gap = out.distance(to: target)
        if gap < 0.05 * scale { return [] }
        var result: [StrokePoint] = []
        let steps = max(1, Int((gap / (1.5 * scale)).rounded(.up)))
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
        if let last = lastEmitted, last.distance(to: pos) < 0.35 * min(1, scale) { return [] }
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
/// while keeping both ends, and every real corner, exactly where they are.
public enum StrokeSmoother {
    /// How far (in canvas pixels) the rounding reaches for a smoothing `amount` at a zoom `scale`
    /// (canvas pixels per screen point). 0 means no rounding. About 20 screen points at full strength.
    public static func radius(amount: Double, scale: Double = 1) -> Double {
        let a = min(1, max(0, amount))
        return a * 20 * max(0.01, scale)
    }

    /// Rounds off wobbles by distance along the line, so it looks the same however fast you drew
    /// and however many touch samples came in. Spreads points evenly, then blends each one with its
    /// neighbours within `radius` canvas pixels.
    ///
    /// - Both ends stay exactly where they are.
    /// - Short lines are blended less (never more than an eighth of their length), so a tiny curve
    ///   doesn't shrink or turn into a blob.
    /// - With a `cornerArm` (canvas pixels), any bend sharper than `cornerAngle` degrees measured over
    ///   that distance is a corner: it stays put and the line is smoothed on each side of it separately.
    public static func round(_ points: [StrokePoint], radius: Double, cornerArm: Double? = nil,
                             cornerAngle: Double = StrokeSmoothing.cornerAngle) -> [StrokePoint] {
        guard points.count > 2, radius > 0.25 else { return points }
        let spacing = max(0.5, min(4, radius / 5))
        let even = StrokeShape.resample(points, spacing: spacing)
        let n = even.count
        guard n > 3 else { return even }

        var length = 0.0
        for i in 1..<n { length += Vec2(even[i - 1]).distance(to: Vec2(even[i])) }
        // Short strokes keep their shape.
        let r = min(radius, length / 8)
        let reach = Int((r / spacing).rounded())
        guard reach >= 1 else { return even }

        var anchors = [0]
        if let arm = cornerArm, arm > 0 {
            anchors += corners(in: even, arm: arm, angle: cornerAngle, spacing: spacing)
        }
        anchors.append(n - 1)

        let sigma = Double(reach) / 2
        var weights: [Double] = []
        weights.reserveCapacity(reach + 1)
        for k in 0...reach { weights.append(exp(-Double(k * k) / (2 * sigma * sigma))) }

        var out = even
        for piece in 0..<(anchors.count - 1) {
            let lo = anchors[piece], hi = anchors[piece + 1]
            guard hi - lo > 1 else { continue }
            for i in (lo + 1)..<hi {
                // Fewer neighbours near the ends and corners, so they don't get pulled in.
                let rr = min(reach, i - lo, hi - i)
                var sx = 0.0, sy = 0.0, sp = 0.0, sw = 0.0
                for k in -rr...rr {
                    let w = weights[abs(k)]
                    let q = even[i + k]
                    sx += q.x * w
                    sy += q.y * w
                    sp += q.pressure * w
                    sw += w
                }
                out[i].x = sx / sw
                out[i].y = sy / sw
                out[i].pressure = sp / sw
            }
        }
        return out
    }

    /// Where a line (already spread evenly, `spacing` apart) has corners you meant to draw:
    /// the sharpest point of every bend over `angle` degrees, measured `arm` canvas pixels each way.
    /// Hand shake is evened out a little first, so it doesn't count as corners.
    public static func corners(in even: [StrokePoint], arm: Double, angle: Double, spacing: Double) -> [Int] {
        let n = even.count
        let k = max(1, Int((arm / spacing).rounded()))
        guard n > 2 * k + 1 else { return [] }
        // A light blur (a third of the arm) just for measuring.
        let blurReach = max(1, k / 3)
        var pos = even.map { Vec2($0) }
        if blurReach > 0 {
            var blurred = pos
            for i in 0..<n {
                let lo = max(0, i - blurReach), hi = min(n - 1, i + blurReach)
                var s = Vec2.zero
                for j in lo...hi { s = s + pos[j] }
                blurred[i] = s / Double(hi - lo + 1)
            }
            pos = blurred
        }
        var bend = [Double](repeating: 0, count: n)
        for i in k..<(n - k) {
            let d1 = pos[i] - pos[i - k]
            let d2 = pos[i + k] - pos[i]
            guard d1.length > arm * 0.3, d2.length > arm * 0.3 else { continue }
            let c = max(-1, min(1, d1.normalized.dot(d2.normalized)))
            bend[i] = acos(c) * 180 / Double.pi
        }
        var found: [Int] = []
        var i = k
        while i < n - k {
            guard bend[i] >= angle else { i += 1; continue }
            // Walk the whole bend and keep its sharpest point.
            var best = i
            var j = i
            while j < n - k, bend[j] >= angle * 0.6 {
                if bend[j] > bend[best] { best = j }
                j += 1
            }
            if let last = found.last, best - last < k {
                if bend[best] > bend[last] { found[found.count - 1] = best }
            } else {
                found.append(best)
            }
            i = j + 1
        }
        return found
    }

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
