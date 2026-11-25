import Foundation
import GaleFormat

/// The stabilizer test.
///
/// You trace a few guide shapes. Gale measures how much your hand shakes: it fits a smooth curve to every
/// little stretch of each line and sees how far your touches wander from it. Real corners (the zigzag's
/// points) are left out, so only shake counts. Then it picks the smoothing that suits your hand.
/// The computer app's `calibration.js` is a port of this, with the same numbers.
public enum StabilizerCalibration {
    /// Guides live in a box this wide and 1 tall.
    public static let aspect: Double = 1.6
    /// Lines shorter than this (screen points) are too short to measure.
    public static let minLength: Double = 40
    /// At least this many lines must be measured for a result.
    public static let minLines = 2
    /// Each little stretch that gets a smooth curve fitted reaches this many screen points each way.
    static let fitReach = 10
    /// Points this close (screen points) to a real corner are left out.
    static let cornerSkip = 10

    /// One shape to trace.
    public struct Guide: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let tip: String
        /// Points along the guide in box units (x 0...aspect, y 0...1, y down).
        public let points: [Vec2]
    }

    /// The shapes you trace, in order.
    public static let guides: [Guide] = [
        Guide(id: "line", title: "A straight line", tip: "Follow the dot from start to end in one stroke.",
              points: guidePoints("line")),
        Guide(id: "circle", title: "A circle", tip: "Go all the way round at your normal speed.",
              points: guidePoints("circle")),
        Guide(id: "wave", title: "A wave", tip: "Smooth and steady, like you’re drawing hair.",
              points: guidePoints("wave")),
        Guide(id: "zigzag", title: "A zigzag", tip: "Sharp corners. This one shows off corner snapping.",
              points: guidePoints("zigzag")),
    ]

    /// Points along a guide, in box units.
    public static func guidePoints(_ id: String) -> [Vec2] {
        var pts: [Vec2] = []
        switch id {
        case "line":
            for i in 0...60 {
                let t = Double(i) / 60
                pts.append(Vec2(0.2 + 1.2 * t, 0.75 - 0.5 * t))
            }
        case "circle":
            for i in 0...120 {
                let a = -Double.pi / 2 + Double(i) / 120 * Double.pi * 2
                pts.append(Vec2(0.8 + 0.34 * cos(a), 0.5 + 0.34 * sin(a)))
            }
        case "wave":
            for i in 0...120 {
                let t = Double(i) / 120
                pts.append(Vec2(0.15 + 1.3 * t, 0.5 - 0.22 * sin(t * Double.pi * 3)))
            }
        case "zigzag":
            let c: [(Double, Double)] = [(0.2, 0.7), (0.5, 0.3), (0.8, 0.7), (1.1, 0.3), (1.4, 0.7)]
            for s in 0..<(c.count - 1) {
                for i in 0..<20 {
                    let t = Double(i) / 20
                    pts.append(Vec2(c[s].0 + (c[s + 1].0 - c[s].0) * t, c[s].1 + (c[s + 1].1 - c[s].1) * t))
                }
            }
            pts.append(Vec2(1.4, 0.7))
        default:
            break
        }
        return pts
    }

    /// Shake (screen points) to smoothing: steadier hands get less, so details stay crisp.
    static let table: [(Double, Double)] = [
        (0, 0.08), (0.08, 0.14), (0.17, 0.25), (0.3, 0.4), (0.42, 0.55), (0.6, 0.78), (0.9, 0.92), (1.3, 1),
    ]

    /// The smoothing that suits a hand that shakes `shake` screen points (RMS).
    public static func recommendedAmount(shake: Double) -> Double {
        let s = max(0, shake.isFinite ? shake : 0)
        if s >= table[table.count - 1].0 { return table[table.count - 1].1 }
        for i in 1..<table.count {
            let (x1, y1) = table[i]
            if s <= x1 {
                let (x0, y0) = table[i - 1]
                let t = (s - x0) / (x1 - x0)
                return ((y0 + (y1 - y0) * t) * 100).rounded() / 100
            }
        }
        return 1
    }

    /// 0 (very shaky) to 100 (rock steady).
    public static func steadiness(shake: Double) -> Int {
        let v = Int((100 * exp(-max(0, shake) / 0.45)).rounded())
        return max(0, min(100, v))
    }

    /// A few words for how steady a hand is.
    public static func levelName(shake: Double) -> String {
        if shake < 0.1 { return "Rock steady" }
        if shake < 0.2 { return "Steady" }
        if shake < 0.35 { return "A little shaky" }
        if shake < 0.55 { return "Shaky" }
        return "Very shaky"
    }

    /// Savitzky-Golay weights for a quadratic fit over 2m+1 points (the fitted value at the middle).
    /// A curve that bends smoothly (like a circle) fits exactly, so only shake is left over.
    public static func quadWeights(_ m: Int) -> [Double] {
        let md = Double(m)
        let d: Double = (2 * md + 3) * (2 * md + 1) * (2 * md - 1)
        let top: Double = 3 * (3 * md * md + 3 * md - 1)
        var w: [Double] = []
        for k in -m...m {
            let kk = Double(k * k)
            w.append((top - 15 * kk) / d)
        }
        return w
    }

    /// How much one line shakes: squared distances (screen points) of each touch from a smooth curve fitted
    /// around it. `scale` = canvas pixels per screen point. Nil if the line is too short.
    public static func lineShake(_ points: [StrokePoint], scale: Double = 1) -> (sum: Double, count: Int)? {
        let s = max(0.01, scale)
        guard points.count >= 3 else { return nil }
        let even = StrokeShape.resample(points, spacing: s)
        let n = even.count
        guard Double(n - 1) >= minLength else { return nil }
        let m = fitReach
        guard n >= 2 * m + 3 else { return nil }
        let w = quadWeights(m)
        var skip = [Bool](repeating: false, count: n)
        for c in StrokeSmoother.corners(in: even, arm: StrokeSmoothing.cornerArm * s,
                                        angle: StrokeSmoothing.cornerAngle, spacing: s) {
            for j in max(0, c - cornerSkip - m)...min(n - 1, c + cornerSkip + m) { skip[j] = true }
        }
        var sum = 0.0
        var count = 0
        for i in m..<(n - m) where !skip[i] {
            var fx = 0.0, fy = 0.0
            for k in -m...m {
                fx += w[k + m] * even[i + k].x
                fy += w[k + m] * even[i + k].y
            }
            let d = Vec2(even[i]).distance(to: Vec2(fx, fy)) / s
            sum += d * d
            count += 1
        }
        return count > 0 ? (sum, count) : nil
    }

    /// What the stabilizer test found.
    public struct Result: Codable, Hashable, Sendable {
        /// How much the hand shakes (RMS, screen points).
        public var shake: Double
        /// The smoothing that suits it.
        public var amount: Double
        /// 0 (very shaky) to 100 (rock steady).
        public var steadiness: Int
        /// A few words for how steady the hand is.
        public var level: String
        /// Each traced line's shake (nil if it was too short to measure).
        public var lines: [Double?]
    }

    /// Measures a stabilizer test: `lines` are the raw touches of each traced guide (canvas pixels).
    /// Nil until enough was drawn.
    public static func measure(_ lines: [[StrokePoint]], scale: Double = 1) -> Result? {
        var sum = 0.0
        var count = 0
        var used = 0
        var each: [Double?] = []
        for pts in lines {
            guard let r = lineShake(pts, scale: scale) else {
                each.append(nil)
                continue
            }
            each.append((r.sum / Double(r.count)).squareRoot())
            sum += r.sum
            count += r.count
            used += 1
        }
        guard used >= minLines, count > 0 else { return nil }
        let shake = (sum / Double(count)).squareRoot()
        return Result(shake: shake, amount: recommendedAmount(shake: shake), steadiness: steadiness(shake: shake),
                      level: levelName(shake: shake), lines: each)
    }
}
