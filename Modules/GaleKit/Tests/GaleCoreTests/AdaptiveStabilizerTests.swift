import XCTest
@testable import GaleCore
@testable import GaleFormat

/// A shape drawn through `corners` with a shaky hand, sampled like a touch screen (every 2.5 pixels, 150 pixels a second).
/// Same numbers as the computer app's tests, so both apps are checked on the same lines.
func shakyPolyline(_ corners: [(Double, Double)], seed: UInt64, wobble: Double = 1.2) -> [StrokePoint] {
    var rng = SeededRandom(seed)
    var pts: [StrokePoint] = []
    var t = 0.0
    let step = 2.5, speed = 150.0
    for c in 0..<(corners.count - 1) {
        let a = corners[c], b = corners[c + 1]
        let length = hypot(b.0 - a.0, b.1 - a.1)
        let n = max(2, Int((length / step).rounded()))
        for k in 0..<n {
            let f = Double(k) / Double(n)
            pts.append(StrokePoint(x: a.0 + (b.0 - a.0) * f + rng.signed() * wobble,
                                   y: a.1 + (b.1 - a.1) * f + rng.signed() * wobble, pressure: 0.5, time: t))
            t += step / speed
        }
    }
    let e = corners[corners.count - 1]
    pts.append(StrokePoint(x: e.0, y: e.1, pressure: 0.5, time: t))
    return pts
}

/// How far the line misses its worst corner (the ends don't count).
func worstCornerCut(_ out: [StrokePoint], _ corners: [(Double, Double)]) -> Double {
    corners.dropFirst().dropLast().map { c in
        out.map { hypot($0.x - c.0, $0.y - c.1) }.min() ?? .infinity
    }.max() ?? 0
}

/// Average turn (degrees) between steps 4 pixels apart: lower is smoother.
func roughness(_ pts: [StrokePoint]) -> Double {
    let e = StrokeShape.resample(pts, spacing: 4)
    var sum = 0.0
    var count = 0
    for i in 1..<(e.count - 1) {
        let a = Vec2(e[i]) - Vec2(e[i - 1]), b = Vec2(e[i + 1]) - Vec2(e[i])
        guard a.length >= 1, b.length >= 1 else { continue }
        sum += acos(max(-1, min(1, a.normalized.dot(b.normalized)))) * 180 / Double.pi
        count += 1
    }
    return sum / Double(max(1, count))
}

/// A circle or wave drawn with a hand tremor (slow drift plus jitter), at touch-screen speed.
func trembling(_ path: (Double) -> Vec2, seed: UInt64, jitter: Double, drift: Double, samples: Int = 300) -> [StrokePoint] {
    var rng = SeededRandom(seed)
    var dx = 0.0, dy = 0.0
    return (0...samples).map { i in
        let t = Double(i) / Double(samples)
        dx += (rng.signed() * drift - dx) * 0.2
        dy += (rng.signed() * drift - dy) * 0.2
        let p = path(t)
        return StrokePoint(x: p.x + dx + rng.signed() * jitter, y: p.y + dy + rng.signed() * jitter,
                           pressure: 0.5, time: Double(i) / 120)
    }
}

let zigzagCorners: [(Double, Double)] = [(100, 300), (160, 220), (220, 300), (280, 220), (340, 300), (400, 220)]
let squareCorners: [(Double, Double)] = [(100, 100), (300, 100), (300, 300), (100, 300), (100, 120)]
let triangleCorners: [(Double, Double)] = [(100, 300), (200, 120), (300, 300), (100, 300)]
let starCorners: [(Double, Double)] = (0...10).map { i in
    let a = -Double.pi / 2 + Double(i) * Double.pi / 5
    let r = i % 2 == 0 ? 150.0 : 60.0
    return (300 + r * cos(a), 300 + r * sin(a))
}

final class AdaptiveStabilizerTests: XCTestCase {
    func testCornersStaySharpEvenWithStrongSmoothing() {
        for (name, shape) in [("zigzag", zigzagCorners), ("square", squareCorners), ("triangle", triangleCorners)] {
            for amount in [0.5, 0.75, 1.0] {
                for seed: UInt64 in [1, 2, 3, 4, 5] {
                    let raw = shakyPolyline(shape, seed: seed)
                    let cut = worstCornerCut(StrokeSmoothing.finish(raw, amount: amount), shape)
                    XCTAssertLessThan(cut, 4.5, "\(name) at \(amount), seed \(seed): a corner was cut by \(cut) pixels")
                }
            }
        }
    }

    func testStarsKeepTheirPoints() {
        // A star's tips are very sharp; its inner corners only turn 70 degrees, so they're the hardest to tell from shake.
        for amount in [0.5, 0.75, 0.85, 1.0] {
            var old = 0.0, new = 0.0
            for seed: UInt64 in [1, 2, 3, 4, 5] {
                let raw = shakyPolyline(starCorners, seed: seed)
                old = max(old, worstCornerCut(StrokeSmoothing.finish(raw, amount: amount, adaptive: false), starCorners))
                new = max(new, worstCornerCut(StrokeSmoothing.finish(raw, amount: amount), starCorners))
            }
            XCTAssertLessThan(new, 7.5, "star at \(amount): a corner was cut by \(new) pixels")
            XCTAssertLessThan(new, old, "star at \(amount): adaptive \(new) vs off \(old)")
        }
    }

    func testKeepCornersSharpBeatsTheOldWay() {
        // With "Keep corners sharp" off, strong smoothing cuts across corners like before.
        var old = 0.0, new = 0.0
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            let raw = shakyPolyline(squareCorners, seed: seed)
            old = max(old, worstCornerCut(StrokeSmoothing.finish(raw, amount: 1, adaptive: false), squareCorners))
            new = max(new, worstCornerCut(StrokeSmoothing.finish(raw, amount: 1), squareCorners))
        }
        XCTAssertGreaterThan(old, 8, "the old way should round the corners off")
        XCTAssertLessThan(new, old / 2.5, "adaptive cut \(new) vs old \(old)")
    }

    func testBrushSnapsToEachCornerWhileDrawing() {
        let raw = shakyPolyline(squareCorners, seed: 1)
        let s = StrokeStabilizer(amount: 1)
        _ = s.begin(raw[0])
        for p in raw.dropFirst() { s.add(p) }
        s.end()
        XCTAssertEqual(s.corners, 3, "a square drawn in one stroke has 3 corners in the middle")
        XCTAssertLessThan(worstCornerCut(s.points, squareCorners), 4)
    }

    func testShakyCurvesDontGetFakeCorners() {
        let circle: (Double) -> Vec2 = { t in Vec2(300 + 120 * cos(t * 2 * .pi), 300 + 120 * sin(t * 2 * .pi)) }
        let wave: (Double) -> Vec2 = { t in Vec2(100 + 400 * t, 300 + 60 * sin(t * 3 * .pi)) }
        for (name, path) in [("circle", circle), ("wave", wave)] {
            for seed: UInt64 in [1, 2, 3, 4, 5, 6] {
                for amount in [0.6, 0.85, 1.0] {
                    let raw = trembling(path, seed: seed, jitter: 0.8, drift: 1.6)
                    let s = StrokeStabilizer(amount: amount)
                    _ = s.begin(raw[0])
                    for p in raw.dropFirst() { s.add(p) }
                    s.end()
                    XCTAssertEqual(s.corners, 0, "\(name) seed \(seed) at \(amount) snapped to a corner that isn't there")
                }
            }
        }
    }

    func testPauseLetsTheBrushCatchUp() {
        let s = StrokeStabilizer(amount: 1)
        _ = s.begin(StrokePoint(x: 0, y: 0, time: 0))
        var t = 0.0
        for i in 1...100 {
            t += 1.0 / 120
            s.add(StrokePoint(x: Double(i) * 2, y: 0, time: t))
        }
        // Hold the pen still for a moment, then draw straight down.
        for _ in 0..<30 {
            t += 1.0 / 120
            s.add(StrokePoint(x: 200, y: 0, time: t))
        }
        for i in 1...60 {
            t += 1.0 / 120
            s.add(StrokePoint(x: 200, y: Double(i) * 2, time: t))
        }
        s.end()
        let miss = s.points.map { hypot($0.x - 200, $0.y) }.min() ?? .infinity
        XCTAssertLessThan(miss, 1, "the line should reach where the pen stopped, but missed by \(miss)")
    }

    func testOffBehavesLikeTheOldStabilizer() {
        let raw = shakyPolyline(zigzagCorners, seed: 3)
        let s = StrokeStabilizer(amount: 1, adaptive: false)
        var drawn = s.begin(raw[0])
        for p in raw.dropFirst() { drawn += s.add(p) }
        drawn += s.end()
        XCTAssertEqual(s.corners, 0)
        // Nothing is ever redrawn when it's off, so the pieces add up to the whole line.
        XCTAssertEqual(drawn, s.points)
    }

    func testPiecesAddUpWhenNothingSnaps() {
        // Light smoothing has no string, so there's nothing to snap: what you get piece by piece is the whole line.
        let raw = shakyPolyline(zigzagCorners, seed: 2)
        let s = StrokeStabilizer(amount: StrokeSmoothing.defaultAmount)
        var drawn = s.begin(raw[0])
        for p in raw.dropFirst() { drawn += s.add(p) }
        drawn += s.end()
        XCTAssertEqual(drawn, s.points)
    }

    func testDefaultSmoothingStillRoundsWobbles() {
        // The finishing step smooths a shaky wave at least as well with "Keep corners sharp" on.
        var on = 0.0, off = 0.0
        let wave: (Double) -> Vec2 = { t in Vec2(100 + 400 * t, 300 + 60 * sin(t * 3 * .pi)) }
        for seed: UInt64 in [1, 2, 3, 4, 5, 6] {
            let raw = trembling(wave, seed: seed, jitter: 0.6, drift: 1)
            on += roughness(StrokeSmoothing.finish(raw, amount: StrokeSmoothing.defaultAmount))
            off += roughness(StrokeSmoothing.finish(raw, amount: StrokeSmoothing.defaultAmount, adaptive: false))
        }
        XCTAssertLessThanOrEqual(on, off * 1.02, "adaptive roughness \(on / 6) vs \(off / 6)")
    }

    func testLongSteadyCurvesGetExtraSmoothing() {
        let wave = trembling({ t in Vec2(100 + 400 * t, 300 + 60 * sin(t * 3 * .pi)) }, seed: 4, jitter: 0.6, drift: 1)
        let even = StrokeShape.resample(wave, spacing: 1)
        let f = StrokeSmoother.adaptiveFactors(even, arm: 6, angle: 60, spacing: 1, length: 500, scale: 1)
        XCTAssertGreaterThan(f[even.count / 2], 1.05, "the middle of a long gentle wave should get more smoothing")
        // A long, nearly straight line gets the most.
        let straight = trembling({ t in Vec2(100 + 400 * t, 300) }, seed: 4, jitter: 0.6, drift: 1)
        let evenStraight = StrokeShape.resample(straight, spacing: 1)
        let fs = StrokeSmoother.adaptiveFactors(evenStraight, arm: 6, angle: 60, spacing: 1, length: 400, scale: 1)
        XCTAssertGreaterThan(fs[evenStraight.count / 2], 1.4)
        // But not a short line.
        let short = Array(even.prefix(30))
        let g = StrokeSmoother.adaptiveFactors(short, arm: 6, angle: 60, spacing: 1, length: 29, scale: 1)
        XCTAssertTrue(g.allSatisfy { $0 <= 1.0001 }, "short lines never get extra smoothing")
    }

    func testSoftCornersGetLessSmoothing() {
        // A 45 degree bend isn't a corner, but you drew it on purpose, so it's smoothed less.
        var pts: [StrokePoint] = []
        for i in 0...100 { pts.append(StrokePoint(x: Double(i), y: 0)) }
        for i in 1...100 { pts.append(StrokePoint(x: 100 + Double(i) * cos(.pi / 4), y: Double(i) * sin(.pi / 4))) }
        let even = StrokeShape.resample(pts, spacing: 1)
        let f = StrokeSmoother.adaptiveFactors(even, arm: 6, angle: 60, spacing: 1, length: 200, scale: 1)
        let bendIndex = even.indices.min { abs(even[$0].x - 100) + abs(even[$0].y) < abs(even[$1].x - 100) + abs(even[$1].y) }!
        XCTAssertLessThan(f[bendIndex], 0.9, "the bend got \(f[bendIndex]) of normal smoothing")
    }

    func testZoomedOutCornersStaySharp() {
        let zig = shakyPolyline(zigzagCorners, seed: 5).map { p -> StrokePoint in
            var q = p
            q.x *= 4
            q.y *= 4
            return q
        }
        let big = zigzagCorners.map { ($0.0 * 4, $0.1 * 4) }
        let cut = worstCornerCut(StrokeSmoothing.finish(zig, amount: 1, scale: 4), big)
        XCTAssertLessThan(cut, 18, "zoomed out, a corner was cut by \(cut) canvas pixels (4.5 screen points allowed)")
    }
}

final class StabilizerCalibrationTests: XCTestCase {
    /// A guide traced in a 300 point tall box, with a hand that wanders `drift` and jitters `jitter` points.
    func traced(_ guide: StabilizerCalibration.Guide, seed: UInt64, jitter: Double, drift: Double, scale: Double = 1) -> [StrokePoint] {
        let size = 300.0
        let even = StrokeShape.resample(guide.points.map { StrokePoint(x: $0.x * size, y: $0.y * size) }, spacing: 2.5)
        var rng = SeededRandom(seed)
        var dx = 0.0, dy = 0.0
        return even.enumerated().map { i, p in
            dx += (rng.signed() * drift - dx) * 0.2
            dy += (rng.signed() * drift - dy) * 0.2
            return StrokePoint(x: (p.x + dx + rng.signed() * jitter) * scale, y: (p.y + dy + rng.signed() * jitter) * scale,
                               pressure: 0.5, time: Double(i) / 120)
        }
    }

    func testThereAreFourGuides() {
        XCTAssertEqual(StabilizerCalibration.guides.map(\.id), ["line", "circle", "wave", "zigzag"])
        for g in StabilizerCalibration.guides {
            XCTAssertGreaterThan(g.points.count, 50)
            for p in g.points {
                XCTAssertTrue((0...StabilizerCalibration.aspect).contains(p.x) && (0...1).contains(p.y), "\(g.id) leaves its box")
            }
        }
    }

    func testSteadyHandGetsLightSmoothing() {
        let lines = StabilizerCalibration.guides.map { traced($0, seed: 1, jitter: 0.05, drift: 0.05) }
        let r = StabilizerCalibration.measure(lines)!
        XCTAssertLessThan(r.shake, 0.1)
        XCTAssertLessThanOrEqual(r.amount, 0.15)
        XCTAssertEqual(r.level, "Rock steady")
        XCTAssertGreaterThan(r.steadiness, 75)
        // The zigzag's corners aren't counted as shake.
        XCTAssertLessThan(r.lines[3]!, 0.1)
    }

    func testShakierHandsGetMoreSmoothing() {
        var last = -1.0
        var lastShake = -1.0
        for (jitter, drift) in [(0.1, 0.2), (0.3, 0.6), (0.6, 1.2), (1.0, 2.0), (1.6, 3.2)] {
            let lines = StabilizerCalibration.guides.map { traced($0, seed: 3, jitter: jitter, drift: drift) }
            let r = StabilizerCalibration.measure(lines)!
            XCTAssertGreaterThan(r.shake, lastShake)
            XCTAssertGreaterThanOrEqual(r.amount, last)
            last = r.amount
            lastShake = r.shake
        }
        XCTAssertGreaterThan(last, 0.5, "a very shaky hand should get strong smoothing")
    }

    func testZoomDoesntChangeTheResult() {
        let one = StabilizerCalibration.measure(StabilizerCalibration.guides.map { traced($0, seed: 2, jitter: 0.4, drift: 0.8) })!
        let four = StabilizerCalibration.measure(StabilizerCalibration.guides.map { traced($0, seed: 2, jitter: 0.4, drift: 0.8, scale: 4) },
                                                 scale: 4)!
        XCTAssertEqual(one.shake, four.shake, accuracy: 0.05)
    }

    func testNeedsAtLeastTwoLines() {
        let one = [traced(StabilizerCalibration.guides[0], seed: 1, jitter: 0.3, drift: 0.5)]
        XCTAssertNil(StabilizerCalibration.measure(one))
        // A dot doesn't count as a line.
        let dot = [StrokePoint(x: 5, y: 5), StrokePoint(x: 6, y: 5), StrokePoint(x: 6, y: 6)]
        XCTAssertNil(StabilizerCalibration.measure([one[0], dot]))
        XCTAssertNil(StabilizerCalibration.lineShake(dot))
    }

    func testTableAndWords() {
        XCTAssertEqual(StabilizerCalibration.recommendedAmount(shake: 0), 0.08)
        XCTAssertEqual(StabilizerCalibration.recommendedAmount(shake: 0.17), 0.25)
        XCTAssertEqual(StabilizerCalibration.recommendedAmount(shake: 5), 1)
        XCTAssertEqual(StabilizerCalibration.recommendedAmount(shake: .nan), 0.08)
        var prev = 0.0
        for i in 0...150 {
            let a = StabilizerCalibration.recommendedAmount(shake: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(a, prev)
            prev = a
        }
        XCTAssertEqual(StabilizerCalibration.steadiness(shake: 0), 100)
        XCTAssertEqual(StabilizerCalibration.levelName(shake: 0.25), "A little shaky")
        XCTAssertEqual(StabilizerCalibration.levelName(shake: 2), "Very shaky")
        // Quadratic fit weights add up to 1 and fit a parabola exactly.
        let w = StabilizerCalibration.quadWeights(10)
        XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-9)
        let fit = (-10...10).enumerated().reduce(0.0) { $0 + w[$1.offset] * Double($1.element * $1.element) }
        XCTAssertEqual(fit, 0, accuracy: 1e-9)
    }
}
