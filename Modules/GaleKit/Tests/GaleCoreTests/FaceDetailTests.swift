import XCTest
@testable import GaleCore
import GaleFormat

/// Small strokes (eyes, mouths, noses) and corners have to come out the way they were drawn,
/// even with smoothing on. These are the strokes that make up a face.
final class FaceDetailTests: XCTestCase {
    let light = StrokeSmoothing.defaultAmount

    /// A small circle, like an eye, drawn at 120 touches a second.
    func circle(radius r: Double, samples n: Int, wobble: Double = 0, seed: UInt64 = 1) -> [StrokePoint] {
        var rng = SeededRandom(seed)
        return (0...n).map { i in
            let a = Double(i) / Double(n) * 2 * Double.pi
            return StrokePoint(x: 200 + cos(a) * r + rng.signed() * wobble, y: 200 + sin(a) * r + rng.signed() * wobble,
                               pressure: 0.5, time: Double(i) / 120)
        }
    }

    /// Points along straight lines through `corners`, `step` pixels apart.
    func polyline(_ corners: [Vec2], step: Double = 1.5, wobble: Double = 0, seed: UInt64 = 2) -> [StrokePoint] {
        var rng = SeededRandom(seed)
        var pts: [StrokePoint] = []
        var t = 0.0
        for c in 0..<(corners.count - 1) {
            let a = corners[c], b = corners[c + 1]
            let n = max(1, Int(a.distance(to: b) / step))
            for k in 0..<n {
                let p = Vec2.lerp(a, b, Double(k) / Double(n))
                pts.append(StrokePoint(x: p.x + rng.signed() * wobble, y: p.y + rng.signed() * wobble, pressure: 0.5, time: t))
                t += 1.0 / 120
            }
        }
        let end = corners[corners.count - 1]
        pts.append(StrokePoint(x: end.x, y: end.y, pressure: 0.5, time: t))
        return pts
    }

    func nearest(_ pts: [StrokePoint], to c: Vec2) -> Double {
        pts.map { Vec2($0).distance(to: c) }.min() ?? .infinity
    }

    func pathLength(_ pts: [StrokePoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        var l = 0.0
        for i in 1..<pts.count { l += Vec2(pts[i - 1]).distance(to: Vec2(pts[i])) }
        return l
    }

    // MARK: Eyes

    func testSmallEyeStaysRound() {
        for r in [5.0, 8.0, 12.0] {
            let raw = circle(radius: r, samples: Int(r * 4))
            let out = StrokeSmoothing.finish(raw, amount: light)
            let worst = out.map { abs(Vec2($0).distance(to: Vec2(200, 200)) - r) }.max() ?? .infinity
            XCTAssertLessThan(worst, max(0.5, r * 0.06), "a \(r) pixel eye came out \(worst) pixels off")
            // It closes: the line ends where the pen lifted.
            XCTAssertEqual(out.last!.x, raw.last!.x, accuracy: 0.001)
            XCTAssertEqual(out.last!.y, raw.last!.y, accuracy: 0.001)
        }
    }

    func testEyeStaysRoundWithAShakyHand() {
        let raw = circle(radius: 10, samples: 40, wobble: 0.5)
        let out = StrokeSmoothing.finish(raw, amount: light)
        let worst = out.map { abs(Vec2($0).distance(to: Vec2(200, 200)) - 10) }.max() ?? .infinity
        XCTAssertLessThan(worst, 1, "shaky 10 pixel eye came out \(worst) pixels off")
    }

    func testEyeSurvivesStrongSmoothingToo() {
        // Even with the slider turned way up, a small eye is still an eye, not a blob.
        let raw = circle(radius: 10, samples: 40)
        for amount in [0.55, 1.0] {
            let out = StrokeSmoothing.finish(raw, amount: amount)
            let worst = out.map { abs(Vec2($0).distance(to: Vec2(200, 200)) - 10) }.max() ?? .infinity
            XCTAssertLessThan(worst, 3.5, "at \(amount) a 10 pixel eye came out \(worst) pixels off")
        }
    }

    // MARK: Mouths and short strokes

    func testSmileKeepsItsDepth() {
        // A small smile: 40 pixels wide, 10 pixels deep.
        let raw = (0...30).map { i -> StrokePoint in
            let t = Double(i) / 30
            return StrokePoint(x: 180 + t * 40, y: 200 + 10 * sin(t * Double.pi), pressure: 0.5, time: Double(i) / 120)
        }
        let out = StrokeSmoothing.finish(raw, amount: light)
        let deepest = out.map(\.y).max() ?? 0
        XCTAssertEqual(deepest, 210, accuracy: 0.6, "the smile got flattened to \(deepest - 200) pixels deep")
    }

    func testShortStrokeKeepsItsLength() {
        for len in [4.0, 8.0, 15.0] {
            let raw = polyline([Vec2(100, 100), Vec2(100 + len, 100)], step: 1)
            let out = StrokeSmoothing.finish(raw, amount: light)
            XCTAssertEqual(out.first!.x, 100, accuracy: 0.001)
            XCTAssertEqual(out.last!.x, 100 + len, accuracy: 0.001)
            XCTAssertEqual(pathLength(out), len, accuracy: 0.3, "a \(len) pixel stroke came out \(pathLength(out)) long")
        }
    }

    func testLineReachesWhereThePenLifted() {
        // With heavy smoothing the brush trails behind, but it always catches up when you lift.
        let raw = polyline([Vec2(0, 0), Vec2(120, 0), Vec2(120, 80)], step: 3)
        for amount in [0.0, light, 0.6, 1.0] {
            let out = StrokeSmoothing.finish(raw, amount: amount)
            XCTAssertEqual(out.last!.x, 120, accuracy: 0.001, "amount \(amount)")
            XCTAssertEqual(out.last!.y, 80, accuracy: 0.001, "amount \(amount)")
        }
    }

    // MARK: Corners

    func testRightAngleCornerStaysSharp() {
        let corner = Vec2(140, 100)
        let raw = polyline([Vec2(100, 100), corner, Vec2(140, 140)])
        let out = StrokeSmoothing.finish(raw, amount: light)
        XCTAssertLessThan(nearest(out, to: corner), 0.5, "the corner was cut by \(nearest(out, to: corner)) pixels")
        XCTAssertGreaterThan(StrokeShape.sharpestBend(out, spacing: 2), 70, "the corner got rounded off")
    }

    func testEyeCornerStaysSharpWithAShakyHand() {
        // An almond eye: two curves meeting in pointed corners, drawn with a little shake.
        let left = Vec2(170, 200), right = Vec2(230, 200)
        var shape: [Vec2] = []
        for i in 0...12 { let t = Double(i) / 12; shape.append(Vec2(170 + 60 * t, 200 - 12 * sin(t * Double.pi))) }
        for i in 1...12 { let t = Double(i) / 12; shape.append(Vec2(230 - 60 * t, 200 + 12 * sin(t * Double.pi))) }
        let raw = polyline(shape, step: 1.5, wobble: 0.4)
        let out = StrokeSmoothing.finish(raw, amount: light)
        XCTAssertLessThan(nearest(out, to: right), 1.5, "the outer corner was cut by \(nearest(out, to: right)) pixels")
        XCTAssertEqual(out.first!.x, raw.first!.x, accuracy: 0.001)
        XCTAssertLessThan(nearest(out, to: left), 1, "the inner corner moved")
    }

    func testCornerDetectionIgnoresHandShake() {
        // A straight line with shake has no corners.
        var rng = SeededRandom(8)
        let raw = (0...200).map { i in
            StrokePoint(x: Double(i) * 2 + rng.signed() * 1.5, y: 100 + rng.signed() * 1.5, pressure: 0.5)
        }
        let even = StrokeShape.resample(raw, spacing: 1)
        let found = StrokeSmoother.corners(in: even, arm: StrokeSmoothing.cornerArm, angle: StrokeSmoothing.cornerAngle, spacing: 1)
        XCTAssertTrue(found.isEmpty, "found \(found.count) corners in a straight shaky line")
    }

    func testCornerDetectionFindsEveryCorner() {
        let raw = polyline([Vec2(0, 0), Vec2(60, 0), Vec2(60, 60), Vec2(0, 60), Vec2(0, 10)], step: 2)
        let even = StrokeShape.resample(raw, spacing: 1)
        let found = StrokeSmoother.corners(in: even, arm: StrokeSmoothing.cornerArm, angle: StrokeSmoothing.cornerAngle, spacing: 1)
        XCTAssertEqual(found.count, 3, "a box outline has 3 corners between its ends")
    }

    // MARK: The slider

    func testOffDrawsExactly() {
        let raw = circle(radius: 10, samples: 40, wobble: 1)
        let out = StrokeSmoothing.finish(raw, amount: 0)
        XCTAssertEqual(out.count, raw.count)
        for (a, b) in zip(out, raw) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
        }
    }

    func testDefaultIsLight() {
        XCTAssertLessThanOrEqual(StrokeSmoothing.defaultAmount, 0.3)
        XCTAssertGreaterThan(StrokeSmoothing.defaultAmount, 0)
        // A few screen points of smoothing, not a big blur.
        XCTAssertLessThan(StrokeSmoother.radius(amount: StrokeSmoothing.defaultAmount), 6)
    }

    func testSliderLabel() {
        XCTAssertEqual(StrokeSmoothing.label(0), "Off")
        XCTAssertEqual(StrokeSmoothing.label(0.25), "25%")
        XCTAssertEqual(StrokeSmoothing.label(1), "100%")
        XCTAssertEqual(StrokeSmoothing.label(-1), "Off")
    }
}
