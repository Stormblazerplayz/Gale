import Foundation
import GaleFormat

/// The smoothing strength Gale starts with, and the numbers both smoothing steps share.
public enum StrokeSmoothing {
    /// Light by default, so faces, eyes and small curves come out the way you drew them.
    /// 0 is off. Shaky hands can turn it up with the slider (or let the stabilizer test pick).
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

    /// The numbers adaptive smoothing ("Keep corners sharp") uses. Same as the computer app's.
    public enum Adaptive {
        /// A turn sharper than this (degrees) while drawing makes the brush snap to the corner.
        public static let snapAngle: Double = 55
        /// How far each way (screen points) a turn is measured while drawing, at 50% smoothing
        /// (more for stronger smoothing).
        public static let snapArm: Double = 12
        /// Each side of a corner must be a straight line: touches stray from it by at most this much of its length.
        public static let straightness: Double = 0.07
        /// Each side's straight-across distance must be at least this much of the distance drawn along it.
        public static let chord: Double = 0.8
        /// While drawing, touches are evened out over this many screen points before looking for corners.
        public static let blur: Double = 1.5
        /// How much a wobbly hand raises the turn needed to snap (times the wobble seen so far).
        public static let wobbleWeight: Double = 5
        /// The side after a corner is checked over this many arms.
        public static let outArm: Double = 2
        /// With a long string, corners are measured over at least this many string lengths.
        public static let armPerString: Double = 1.5
        /// Holding the pen within this many screen points...
        public static let pauseMove: Double = 1
        /// ...for this many seconds is a pause: the brush catches up to the pen.
        public static let pauseTime: Double = 0.12
        /// Steady stretches are measured over this many corner arms.
        public static let longArm: Double = 2.5
        /// Below this bend (degrees, over the long arm) a stretch is a steady curve and gets extra smoothing.
        public static let steadyBend: Double = 10
        /// From this bend up, smoothing is turned down...
        public static let softBend: Double = 30
        /// ...to this much of normal at the corner angle.
        public static let cornerFactor: Double = 0.3
        /// Steady curves get up to this much more smoothing.
        public static let curveBoost: Double = 1.5
        /// Only lines at least this long (screen points) get the extra smoothing on curves.
        public static let boostLength: Double = 50
    }

    /// Runs the finishing step the canvas uses (while drawing and when you lift):
    /// evens out wobbles but keeps corners and short strokes the way you drew them.
    /// `scale` is canvas pixels per screen point, so it feels the same at any zoom.
    /// `adaptive` ("Keep corners sharp") smooths less where the line bends on purpose and more on long curves.
    public static func shape(_ points: [StrokePoint], amount: Double, scale: Double = 1, adaptive: Bool = true) -> [StrokePoint] {
        let a = min(1, max(0, amount))
        guard a > 0.005 else { return points }
        let s = max(0.01, scale)
        return StrokeSmoother.round(points, radius: StrokeSmoother.radius(amount: a, scale: s),
                                    cornerArm: cornerArm * s, cornerAngle: cornerAngle, adaptive: adaptive, scale: s)
    }

    /// The whole pipeline on a list of points: the live stabilizer, then the finishing step.
    /// The canvas does exactly this, one touch at a time. Used by tests, imports, replays and the stabilizer test.
    public static func finish(_ raw: [StrokePoint], amount: Double, scale: Double = 1, adaptive: Bool = true) -> [StrokePoint] {
        let st = StrokeStabilizer.stabilize(raw, amount: amount, scale: scale, adaptive: adaptive)
        return shape(StrokeShape.dedupe(st), amount: amount, scale: scale, adaptive: adaptive)
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
/// Adaptive (on by default): when you turn a sharp corner, the brush snaps to exactly where your pen
/// turned, the part it had cut across is redrawn into the corner, and the string starts again from there.
/// When you hold the pen still for a moment, the brush catches up to it. So zigzags, stars and boxes stay
/// crisp even with strong smoothing. Because a snap can redraw the end of the line, read `points` for
/// the whole line so far.
///
/// `amount` 0 draws exactly where you touch. 1 is the strongest smoothing.
public final class StrokeStabilizer {
    public private(set) var amount: Double
    /// Canvas pixels per screen point, so the string feels the same at any zoom.
    public var scale: Double
    /// Snap to corners and catch up after pauses.
    public let adaptive: Bool

    private var lazy: Vec2 = .zero
    private var out: Vec2 = .zero
    private var outPressure: Double = 0.5
    private var cursor: StrokePoint?
    private var lastTouch: Vec2 = .zero
    private var lastEmitted: Vec2?
    private var started = false
    /// How far the finger or pencil has moved in this stroke, in canvas pixels.
    public private(set) var traveled: Double = 0
    /// Distance since the brush last snapped to a corner or caught up after a pause (nil = never).
    private var sinceReset: Double?
    /// Every point drawn so far in this stroke. A snap to a corner can redraw the end of it.
    public private(set) var points: [StrokePoint] = []
    /// How many corners the brush snapped to in this stroke.
    public private(set) var corners = 0

    private var hist: [StrokePoint] = []
    private var histDone: [Int] = []
    private var lastCorner = -1
    private var stillAt: Vec2?
    private var stillSince: Double = 0
    private var wobble: Double = 0
    private var wobbleSeen = false

    public init(amount: Double, scale: Double = 1, adaptive: Bool = true) {
        self.amount = min(1, max(0, amount))
        self.scale = max(0.01, scale)
        self.adaptive = adaptive
    }

    /// How hard the string pulls back. Light smoothing (up to `StrokeSmoothing.stringStarts`) has no string
    /// at all, so the line stays right under the pen and corners stay sharp; the finishing step evens out
    /// the wobbles instead. Above that the string grows for shaky hands.
    var pull: Double { max(0, (amount - StrokeSmoothing.stringStarts) / (1 - StrokeSmoothing.stringStarts)) }

    /// Longest the string gets, in canvas pixels (about 16 screen points at full strength).
    public var maxStringLength: Double { pow(pull, 1.3) * 16 * scale }

    /// Length of the string right now. It grows with the line (again after a corner), so short strokes keep their shape.
    public var stringLength: Double { min(maxStringLength, (sinceReset ?? traveled) * 0.1) }

    /// How quickly the brush glides (1 = instantly). Right after a corner it glides in gently again.
    var glide: Double {
        let ramp = sinceReset.map { min(1, $0 / (20 * scale)) } ?? 1
        return 1 - 0.6 * pull * ramp
    }

    private var adapts: Bool { adaptive && pull > 0 }

    public func begin(_ p: StrokePoint) -> [StrokePoint] {
        started = true
        traveled = 0
        sinceReset = nil
        lazy = Vec2(p)
        out = lazy
        lastTouch = lazy
        outPressure = p.pressure
        cursor = p
        lastEmitted = out
        points = [p]
        corners = 0
        hist = [p]
        histDone = [1]
        lastCorner = -1
        stillAt = lazy
        stillSince = p.time
        wobble = 0
        wobbleSeen = false
        return [p]
    }

    /// Adds a touch. Returns the points drawn since the last call (after a corner snap, that starts with the redrawn part).
    @discardableResult
    public func add(_ p: StrokePoint) -> [StrokePoint] {
        guard started else { return begin(p) }
        let before = points.count
        let target = Vec2(p)
        if adapts, let still = stillAt, still.distance(to: target) > StrokeSmoothing.Adaptive.pauseMove * scale {
            // A pause: you held the pen still, so the brush catches up to exactly where you stopped.
            if p.time - stillSince >= StrokeSmoothing.Adaptive.pauseTime {
                catchUp(to: still, pressure: cursor?.pressure ?? p.pressure)
            }
            stillAt = target
            stillSince = p.time
        }
        cursor = p
        let moved = lastTouch.distance(to: target)
        traveled += moved
        if let r = sinceReset { sinceReset = r + moved }
        lastTouch = target
        step(p)
        if adapts, let last = hist.last, Vec2(last).distance(to: target) >= 0.5 * scale {
            hist.append(p)
            histDone.append(points.count)
            checkCorner(atEnd: false)
        }
        return newPoints(since: before)
    }

    /// Finishes the line where you lifted, gliding in smoothly, so the end is never cut short.
    @discardableResult
    public func end() -> [StrokePoint] {
        defer { started = false }
        guard started, let c = cursor else { return [] }
        let before = points.count
        if adapts { checkCorner(atEnd: true) }
        let target = Vec2(c)
        let gap = out.distance(to: target)
        if gap >= 0.05 * scale {
            let steps = max(1, Int((gap / (1.5 * scale)).rounded(.up)))
            let start = out
            for i in 1...steps {
                // Ease out so the end doesn't look like a straight tail.
                let t = Double(i) / Double(steps)
                let e = 1 - (1 - t) * (1 - t)
                let pos = Vec2.lerp(start, target, e)
                var q = c
                q.x = pos.x
                q.y = pos.y
                q.pressure = outPressure + (c.pressure - outPressure) * t
                points.append(q)
            }
            out = target
            lastEmitted = target
        }
        return newPoints(since: before)
    }

    /// Runs a whole list of points through a fresh stabilizer (for tests, imports and replays).
    public static func stabilize(_ points: [StrokePoint], amount: Double, scale: Double = 1, adaptive: Bool = true) -> [StrokePoint] {
        guard let first = points.first else { return [] }
        let s = StrokeStabilizer(amount: amount, scale: scale, adaptive: adaptive)
        _ = s.begin(first)
        for p in points.dropFirst() { s.add(p) }
        s.end()
        return s.points
    }

    // MARK: Moving the brush

    private func newPoints(since before: Int) -> [StrokePoint] {
        // After a snap the line was redrawn from an earlier point: hand back the redrawn part.
        Array(points[min(before, points.count)...])
    }

    /// Moves the brush toward a touch and draws it.
    private func step(_ p: StrokePoint) {
        let target = Vec2(p)
        if pull <= 0 {
            out = target
            lazy = target
            outPressure = p.pressure
            emit(target, from: p, pressure: p.pressure)
            return
        }
        let d = lazy.distance(to: target)
        let r = stringLength
        if d > r {
            lazy = lazy + (target - lazy) * ((d - r) / d)
        }
        let a = glide
        out = out + (lazy - out) * a
        outPressure += (p.pressure - outPressure) * min(1, a + 0.2)
        emit(out, from: p, pressure: outPressure)
    }

    /// Draws straight from the brush to `pos` and starts the string again from there.
    private func catchUp(to pos: Vec2, pressure: Double) {
        if let c = cursor { line(to: pos, pressure: pressure, from: c) }
        lazy = pos
        out = pos
        outPressure = pressure
        sinceReset = 0
    }

    private func line(to pos: Vec2, pressure: Double, from p: StrokePoint) {
        let start = out
        let gap = start.distance(to: pos)
        guard gap >= 0.05 * scale else { return }
        let steps = max(1, Int((gap / (1.5 * scale)).rounded(.up)))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            emit(Vec2.lerp(start, pos, t), from: p, pressure: outPressure + (pressure - outPressure) * t, force: true)
        }
    }

    private func emit(_ pos: Vec2, from p: StrokePoint, pressure: Double, force: Bool = false) {
        if let last = lastEmitted {
            if !force && last.distance(to: pos) < 0.35 * min(1, scale) { return }
            if force && last.distance(to: pos) < 1e-9 { return }
        }
        lastEmitted = pos
        var q = p
        q.x = pos.x
        q.y = pos.y
        q.pressure = pressure
        points.append(q)
    }

    // MARK: Corners

    /// Looks back along where the pen went for a sharp turn, and snaps the brush to it.
    private func checkCorner(atEnd: Bool) {
        typealias A = StrokeSmoothing.Adaptive
        let h = hist
        let n = h.count
        guard n >= 4 else { return }
        let s = scale
        // Shakier hands use stronger smoothing, so corners are measured over a longer stretch (at least the string).
        let arm = max(A.snapArm * s * (0.5 + amount), maxStringLength * A.armPerString)
        // Walk back from the pen far enough to see both sides (never past the last corner).
        var lo = n - 1
        var walked = 0.0
        while lo > lastCorner + 1 && lo > 0 && walked < (2 + A.outArm) * arm {
            walked += Vec2(h[lo]).distance(to: Vec2(h[lo - 1]))
            lo -= 1
        }
        guard walked >= 1.6 * arm else { return }
        // Spread the touches evenly and even out hand shake a little (just for measuring).
        let step = 0.5 * s
        let even = StrokeStabilizer.evenly(h, lo, n - 1, step)
        let pts = StrokeStabilizer.blur(even, max(1, Int((A.blur * s / step).rounded())))
        let m = pts.count
        let k = Int((arm / step).rounded())
        // The side after the corner must stay straight for longer, so a quick wobble isn't taken for a corner.
        let kOut = Int((arm * A.outArm / step).rounded())
        guard m >= k + 3 else { return }
        // The point furthest from the straight line across the window is where it turned.
        let a = pts[0], c = pts[m - 1]
        var best = -1
        var bestD = -1.0
        for j in 1..<(m - 1) {
            let d = Geometry.distanceToSegment(pts[j], a, c)
            if d > bestD { bestD = d; best = j }
        }
        guard best > 0 else { return }
        let outLen = min(kOut, m - 1 - best)
        let inLen = min(k, best)
        guard Double(outLen) >= (atEnd ? 0.45 * Double(k) : Double(kOut)), Double(inLen) >= 0.6 * Double(k) else { return }
        // Both sides must be straight lines: fit a line to each and check how far the touches stray from it.
        // Hand shake strays a lot; a corner you drew doesn't.
        let fIn = StrokeStabilizer.fitLine(pts, best - inLen, best)
        let fOut = StrokeStabilizer.fitLine(pts, best, best + outLen)
        // How much your hand has wobbled so far in this stroke. Wobblier hands need a sharper turn to count.
        wobble = wobbleSeen ? wobble + (fIn.spread - wobble) * 0.15 : fIn.spread
        wobbleSeen = true
        // Straight across must be nearly as far as along the touches (a zigzagging shake isn't).
        let chordIn = pts[best].distance(to: pts[best - inLen])
        let chordOut = pts[best + outLen].distance(to: pts[best])
        guard chordIn >= A.chord * StrokeStabilizer.along(pts, best - inLen, best),
              chordOut >= A.chord * StrokeStabilizer.along(pts, best, best + outLen) else { return }
        guard fIn.spread <= A.straightness * chordIn, fOut.spread <= A.straightness * chordOut else { return }
        let noise = 2 * atan(A.wobbleWeight * wobble / chordIn) * 180 / Double.pi
        guard StrokeStabilizer.angle(fIn.dir, fOut.dir) >= A.snapAngle + noise else { return }
        // Snap to the real touch nearest the corner.
        let corner = even[best]
        var index = lo
        var nearest = Double.infinity
        for j in lo..<n {
            let d = Vec2(h[j]).distance(to: corner)
            if d < nearest { nearest = d; index = j }
        }
        guard index > lastCorner, index < n - 1 else { return }
        snap(to: index)
    }

    /// Redraws the end of the line so it goes straight into the corner, then follows the pen out of it.
    private func snap(to index: Int) {
        let v = hist[index]
        // Take back what was drawn after the pen reached the corner (the brush was cutting across it).
        let keep = max(1, min(points.count, histDone[index]))
        points.removeLast(points.count - keep)
        let last = points[keep - 1]
        out = Vec2(last)
        outPressure = last.pressure
        lastEmitted = out
        line(to: Vec2(v), pressure: v.pressure, from: v)
        lazy = Vec2(v)
        out = lazy
        outPressure = v.pressure
        lastEmitted = out
        lastCorner = index
        corners += 1
        // Follow the pen from the corner to where it is now.
        var prev = lazy
        var reset = 0.0
        sinceReset = 0
        for k in (index + 1)..<hist.count {
            let q = hist[k]
            reset += prev.distance(to: Vec2(q))
            sinceReset = reset
            prev = Vec2(q)
            step(q)
            histDone[k] = points.count
        }
        if let c = cursor {
            let tip = Vec2(c)
            let gap = prev.distance(to: tip)
            sinceReset = reset + gap
            if gap > 0 { step(c) }
        }
    }

    /// Touches `lo...hi` spread evenly, `step` apart (positions only).
    static func evenly(_ h: [StrokePoint], _ lo: Int, _ hi: Int, _ step: Double) -> [Vec2] {
        var out = [Vec2(h[lo])]
        guard hi > lo else { return out }
        var carried = 0.0
        for i in lo..<hi {
            let a = Vec2(h[i]), b = Vec2(h[i + 1])
            let seg = a.distance(to: b)
            if seg <= 0 { continue }
            var at = step - carried
            while at <= seg {
                out.append(Vec2.lerp(a, b, at / seg))
                at += step
            }
            carried = seg - (at - step)
        }
        return out
    }

    /// Each point averaged with `reach` neighbours each way.
    static func blur(_ pts: [Vec2], _ reach: Int) -> [Vec2] {
        var out: [Vec2] = []
        out.reserveCapacity(pts.count)
        for k in 0..<pts.count {
            let a = max(0, k - reach), z = min(pts.count - 1, k + reach)
            var sx = 0.0, sy = 0.0
            for j in a...z { sx += pts[j].x; sy += pts[j].y }
            out.append(Vec2(sx / Double(z - a + 1), sy / Double(z - a + 1)))
        }
        return out
    }

    /// The straight line that best fits points `a...b`: which way it goes (from a toward b) and how far points stray (RMS).
    static func fitLine(_ pts: [Vec2], _ a: Int, _ b: Int) -> (dir: Vec2, spread: Double) {
        let n = Double(b - a + 1)
        var cx = 0.0, cy = 0.0
        for i in a...b { cx += pts[i].x; cy += pts[i].y }
        cx /= n
        cy /= n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in a...b {
            let dx = pts[i].x - cx, dy = pts[i].y - cy
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var dir = Vec2(cos(theta), sin(theta))
        if dir.dot(pts[b] - pts[a]) < 0 { dir = -dir }
        let nrm = Vec2(-dir.y, dir.x)
        let center = Vec2(cx, cy)
        var ss = 0.0
        for i in a...b {
            let d = (pts[i] - center).dot(nrm)
            ss += d * d
        }
        return (dir, (ss / n).squareRoot())
    }

    /// Distance along points `a...b`.
    static func along(_ pts: [Vec2], _ a: Int, _ b: Int) -> Double {
        guard b > a else { return 0 }
        var d = 0.0
        for i in (a + 1)...b { d += pts[i - 1].distance(to: pts[i]) }
        return d
    }

    /// The angle between two directions, in degrees.
    static func angle(_ a: Vec2, _ b: Vec2) -> Double {
        guard a.length >= 1e-9, b.length >= 1e-9 else { return 180 }
        let c = max(-1, min(1, a.normalized.dot(b.normalized)))
        return acos(c) * 180 / Double.pi
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
    /// - `adaptive` (needs a `cornerArm`): smooths less where the line bends on purpose, so soft corners
    ///   and zigzags stay crisp, and more along long steady curves. `scale` is canvas pixels per screen point.
    public static func round(_ points: [StrokePoint], radius: Double, cornerArm: Double? = nil,
                             cornerAngle: Double = StrokeSmoothing.cornerAngle,
                             adaptive: Bool = false, scale: Double = 1) -> [StrokePoint] {
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

        var factors: [Double]?
        if adaptive, let arm = cornerArm, arm > 0 {
            factors = adaptiveFactors(even, arm: arm, angle: cornerAngle, spacing: spacing, length: length,
                                      scale: max(0.01, scale))
        }
        // Longest reach anywhere (steady curves reach further, but short lines still never more than an eighth).
        let maxReach = factors == nil ? reach
            : max(reach, Int((min(radius * StrokeSmoothing.Adaptive.curveBoost, length / 8) / spacing).rounded()))

        var out = even
        for piece in 0..<(anchors.count - 1) {
            let lo = anchors[piece], hi = anchors[piece + 1]
            guard hi - lo > 1 else { continue }
            for i in (lo + 1)..<hi {
                let ri = factors.map { max(0, min(maxReach, Int((Double(reach) * $0[i]).rounded()))) } ?? reach
                // Fewer neighbours near the ends and corners, so they don't get pulled in.
                let rr = min(ri, i - lo, hi - i)
                guard rr >= 1 else { continue }
                let sigma = max(0.5, Double(ri) / 2)
                var sx = 0.0, sy = 0.0, sp = 0.0, sw = 0.0
                for k in -rr...rr {
                    let w = exp(-Double(k * k) / (2 * sigma * sigma))
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

    /// How much each point bends (degrees), measured `k` points each way after a light blur
    /// (a third of the arm), so hand shake doesn't count as bends.
    public static func bends(_ even: [StrokePoint], k: Int, arm: Double) -> [Double] {
        let n = even.count
        var bend = [Double](repeating: 0, count: n)
        guard n > 2 * k + 1 else { return bend }
        let blurReach = max(1, k / 3)
        var pos: [Vec2] = []
        pos.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - blurReach), hi = min(n - 1, i + blurReach)
            var s = Vec2.zero
            for j in lo...hi { s = s + Vec2(even[j]) }
            pos.append(s / Double(hi - lo + 1))
        }
        for i in k..<(n - k) {
            let d1 = pos[i] - pos[i - k]
            let d2 = pos[i + k] - pos[i]
            guard d1.length > arm * 0.3, d2.length > arm * 0.3 else { continue }
            let c = max(-1, min(1, d1.normalized.dot(d2.normalized)))
            bend[i] = acos(c) * 180 / Double.pi
        }
        return bend
    }

    /// Where a line (already spread evenly, `spacing` apart) has corners you meant to draw:
    /// the sharpest point of every bend over `angle` degrees, measured `arm` canvas pixels each way.
    /// Hand shake is evened out a little first, so it doesn't count as corners.
    public static func corners(in even: [StrokePoint], arm: Double, angle: Double, spacing: Double) -> [Int] {
        let n = even.count
        let k = max(1, Int((arm / spacing).rounded()))
        guard n > 2 * k + 1 else { return [] }
        let bend = bends(even, k: k, arm: arm)
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

    /// How much of the normal smoothing each point gets (adaptive smoothing): less where the line bends on
    /// purpose (so soft corners and zigzags stay crisp), more along long steady curves.
    /// `even` is spread `spacing` apart, `arm` is the corner arm in canvas pixels.
    public static func adaptiveFactors(_ even: [StrokePoint], arm: Double, angle: Double, spacing: Double,
                                       length: Double, scale: Double) -> [Double] {
        typealias A = StrokeSmoothing.Adaptive
        let n = even.count
        let k = max(1, Int((arm * A.longArm / spacing).rounded()))
        let bend = bends(even, k: k, arm: arm * A.longArm)
        let canBoost = length >= A.boostLength * scale
        var raw = [Double](repeating: 1, count: n)
        for i in 0..<n {
            let b = bend[i]
            let inside = i >= k && i < n - k
            if b >= A.softBend {
                let t = min(1, (b - A.softBend) / max(1, angle - A.softBend))
                raw[i] = 1 - t * (1 - A.cornerFactor)
            } else if canBoost && inside && b <= A.steadyBend {
                raw[i] = A.curveBoost
            } else if canBoost && inside {
                let t = (b - A.steadyBend) / (A.softBend - A.steadyBend)
                raw[i] = A.curveBoost + (1 - A.curveBoost) * t
            }
        }
        // Take the smallest factor nearby (so the smoothing turns down before it reaches a bend), then soften it.
        var near = raw
        for i in 0..<n {
            var m = raw[i]
            for j in max(0, i - k)...min(n - 1, i + k) where raw[j] < m { m = raw[j] }
            near[i] = m
        }
        let r = max(1, k / 2)
        var out = near
        for i in 0..<n {
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            var s = 0.0
            for j in lo...hi { s += near[j] }
            out[i] = s / Double(hi - lo + 1)
        }
        return out
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
