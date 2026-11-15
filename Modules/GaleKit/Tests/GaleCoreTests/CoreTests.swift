import XCTest
@testable import GaleCore
@testable import GaleFormat

/// A tiny repeatable random number maker, so tests give the same answer every time.
struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func signed() -> Double { next() * 2 - 1 }
}

func line(from a: Vec2, to b: Vec2, count: Int, size: Double = 6, kind: BrushKind = .pen) -> Stroke {
    let pts = (0..<count).map { i -> StrokePoint in
        let t = Double(i) / Double(max(1, count - 1))
        let p = Vec2.lerp(a, b, t)
        return StrokePoint(x: p.x, y: p.y, pressure: 0.6, time: t)
    }
    return Stroke(brush: Brush(kind: kind, size: size), points: pts)
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, size: Double = 6) -> [Stroke] {
    [line(from: Vec2(x, y), to: Vec2(x + w, y), count: 20, size: size),
     line(from: Vec2(x + w, y), to: Vec2(x + w, y + h), count: 20, size: size),
     line(from: Vec2(x + w, y + h), to: Vec2(x, y + h), count: 20, size: size),
     line(from: Vec2(x, y + h), to: Vec2(x, y), count: 20, size: size)]
}

final class StabilizerTests: XCTestCase {
    func shakyLine(seed: UInt64, wobble: Double) -> [StrokePoint] {
        var rng = SeededRandom(seed)
        return (0..<240).map { i in
            let x = Double(i) * 2.5
            return StrokePoint(x: x + rng.signed() * wobble * 0.5, y: 300 + rng.signed() * wobble, pressure: 0.5 + rng.signed() * 0.2, time: Double(i) / 120)
        }
    }

    func averageWobble(_ pts: [StrokePoint]) -> Double {
        let inner = pts.dropFirst(10).dropLast(10)
        return inner.reduce(0) { $0 + abs($1.y - 300) } / Double(max(1, inner.count))
    }

    func testShakyHandsBecomeSmooth() {
        let raw = shakyLine(seed: 7, wobble: 8)
        let smooth = StrokeStabilizer.stabilize(raw, amount: 0.8)
        let before = averageWobble(raw)
        let after = averageWobble(smooth)
        XCTAssertGreaterThan(before, 3.5)
        XCTAssertLessThan(after, before * 0.3, "wobble went from \(before) to \(after)")
        // The line still goes the whole way.
        XCTAssertEqual(smooth.first!.x, raw.first!.x, accuracy: 0.001)
        XCTAssertEqual(smooth.last!.x, raw.last!.x, accuracy: 0.5)
        XCTAssertEqual(smooth.last!.y, raw.last!.y, accuracy: 0.5)
    }

    func testMoreSmoothingIsSmoother() {
        let raw = shakyLine(seed: 3, wobble: 6)
        let low = averageWobble(StrokeStabilizer.stabilize(raw, amount: 0.3))
        let high = averageWobble(StrokeStabilizer.stabilize(raw, amount: 0.9))
        XCTAssertLessThan(high, low)
    }

    func testZeroDrawsExactly() {
        let raw = shakyLine(seed: 11, wobble: 5)
        let out = StrokeStabilizer.stabilize(raw, amount: 0)
        // Every point lands exactly where it was touched (points closer than a third of a pixel are skipped).
        XCTAssertGreaterThan(out.count, raw.count - 10)
        var j = 0
        for a in out {
            while j < raw.count, raw[j].x != a.x || raw[j].y != a.y { j += 1 }
            XCTAssertLessThan(j, raw.count, "a point moved")
        }
    }

    func testTinyWigglesInsideTheStringDontMove() {
        let s = StrokeStabilizer(amount: 1)
        _ = s.begin(StrokePoint(x: 100, y: 100))
        var moved: [StrokePoint] = []
        for i in 0..<30 {
            moved += s.add(StrokePoint(x: 100 + Double(i % 3) * 3, y: 100 - Double(i % 2) * 3))
        }
        XCTAssertTrue(moved.isEmpty, "the brush moved \(moved.count) times for tiny wiggles")
    }

    func testFinalSmoothingKeepsEnds() {
        let raw = shakyLine(seed: 5, wobble: 4)
        let out = StrokeSmoother.smooth(raw, amount: 0.8)
        XCTAssertEqual(out.count, raw.count)
        XCTAssertEqual(out.first, raw.first)
        XCTAssertEqual(out.last, raw.last)
        XCTAssertLessThan(averageWobble(out), averageWobble(raw))
    }
}

final class StrokeShapeTests: XCTestCase {
    func testPressureMakesPenWider() {
        let b = Brush(kind: .pen, size: 10)
        let soft = StrokeShape.width(of: StrokePoint(x: 0, y: 0, pressure: 0.1), brush: b, index: 10, count: 30)
        let hard = StrokeShape.width(of: StrokePoint(x: 0, y: 0, pressure: 1), brush: b, index: 10, count: 30)
        XCTAssertGreaterThan(hard, soft * 2)
        XCTAssertEqual(hard, 10, accuracy: 0.01)
    }

    func testLeaningPencilShades() {
        let b = Brush(kind: .pencil, size: 4)
        let upright = StrokeShape.width(of: StrokePoint(x: 0, y: 0, pressure: 0.5, altitude: .pi / 2), brush: b, index: 0, count: 1)
        let leaning = StrokeShape.width(of: StrokePoint(x: 0, y: 0, pressure: 0.5, altitude: 0.3), brush: b, index: 0, count: 1)
        XCTAssertGreaterThan(leaning, upright * 2)
    }

    func testOutlineWrapsTheLine() {
        let s = line(from: Vec2(0, 0), to: Vec2(100, 0), count: 10, size: 10)
        let poly = StrokeShape.outline(of: s)
        XCTAssertGreaterThan(poly.count, 20)
        let flat = poly.flatMap { [$0.x, $0.y] }
        XCTAssertTrue(Geometry.contains(flat, Vec2(50, 0)))
        XCTAssertFalse(Geometry.contains(flat, Vec2(50, 20)))
        // Round ends reach past the end points.
        XCTAssertLessThan(poly.map(\.x).min()!, -0.5)
        XCTAssertGreaterThan(poly.map(\.x).max()!, 100.5)
    }

    func testSinglePointIsADot() {
        let s = Stroke(brush: Brush(size: 8), points: [StrokePoint(x: 5, y: 5, pressure: 1)])
        let poly = StrokeShape.outline(of: s)
        XCTAssertEqual(poly.count, 16)
        XCTAssertTrue(Geometry.contains(poly.flatMap { [$0.x, $0.y] }, Vec2(5, 5)))
    }

    func testDensifyFillsGaps() {
        let pts = [StrokePoint(x: 0, y: 0), StrokePoint(x: 30, y: 0), StrokePoint(x: 30, y: 30)]
        let d = StrokeShape.densify(pts, spacing: 3)
        XCTAssertGreaterThan(d.count, 15)
        for i in 1..<d.count {
            XCTAssertLessThan(Vec2(d[i]).distance(to: Vec2(d[i - 1])), 4.5)
        }
    }
}

final class OnionAndPlaybackTests: XCTestCase {
    func testGhostsFadeWithDistanceAndAreFrosted() {
        let g = OnionSkin.ghosts(current: 5, frameCount: 10, settings: OnionSettings(before: 3, after: 2, opacity: 0.6, falloff: 0.5, frosted: true, blur: 4))
        XCTAssertEqual(g.count, 5)
        XCTAssertEqual(g.map(\.offset), [-3, -2, 2, -1, 1])   // farthest first
        let near = g.first { $0.offset == -1 }!
        let far = g.first { $0.offset == -3 }!
        XCTAssertEqual(near.opacity, 0.6, accuracy: 1e-9)
        XCTAssertEqual(far.opacity, 0.15, accuracy: 1e-9)
        XCTAssertGreaterThan(far.blur, near.blur)
        XCTAssertGreaterThan(near.blur, 0)
        XCTAssertEqual(near.side, .before)
        XCTAssertEqual(g.first { $0.offset == 1 }!.side, .after)
    }

    func testGhostsStopAtEndsUnlessWrapping() {
        let s = OnionSettings(before: 2, after: 2)
        XCTAssertEqual(Set(OnionSkin.ghosts(current: 0, frameCount: 4, settings: s).map(\.frameIndex)), [1, 2])
        var w = s
        w.wrap = true
        XCTAssertEqual(Set(OnionSkin.ghosts(current: 0, frameCount: 4, settings: w).map(\.frameIndex)), [1, 2, 3])
        XCTAssertTrue(OnionSkin.ghosts(current: 0, frameCount: 1, settings: s).isEmpty)
        var off = s
        off.on = false
        XCTAssertTrue(OnionSkin.ghosts(current: 2, frameCount: 4, settings: off).isEmpty)
        var sharp = s
        sharp.frosted = false
        XCTAssertTrue(OnionSkin.ghosts(current: 2, frameCount: 4, settings: sharp).allSatisfy { $0.blur == 0 })
    }

    func testFrameAtTimeUsesHolds() {
        var p = GaleProject(name: "T", fps: 12)
        p.frames[0].hold = 2
        p.insertFrame(Frame(hold: 1), after: nil)
        p.insertFrame(Frame(hold: 3), after: nil)
        XCTAssertEqual(p.totalTicks, 6)
        XCTAssertEqual((0..<8).map { Playback.frameIndex(atTick: $0, frames: p.frames) }, [0, 0, 1, 2, 2, 2, 0, 0])
        XCTAssertEqual(Playback.frameIndex(atTime: 0.25, project: p), 2)
        XCTAssertEqual(Playback.time(ofFrame: 2, project: p), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Playback.frameIndex(atTick: -1, frames: p.frames), 2)
        XCTAssertEqual(Playback.exportTicks(project: p, repeats: 2), 12)
        XCTAssertEqual(Playback.exportTicks(project: p, repeats: 1, minimumSeconds: 1.2), 18)
    }
}

final class LoopTests: XCTestCase {
    func walkProject() -> GaleProject {
        var p = GaleProject(name: "Walk", fps: 12)
        let layer = p.layers[0].id
        for i in 0..<4 {
            if i > 0 { p.insertFrame(Frame(hold: 2), after: nil) }
            var cel = Cel()
            cel.append(line(from: Vec2(100 + Double(i) * 10, 100), to: Vec2(100 + Double(i) * 10, 200), count: 5))
            p.frames[i].cels[layer] = cel
        }
        return p
    }

    func testSaveAndInsertAWalkCycle() throws {
        let p = walkProject()
        let loop = try XCTUnwrap(LoopTools.makeLoop(from: p, layerIDs: [p.layers[0].id], range: 0...3, name: "Walk", kind: .walk, stride: 80))
        XCTAssertEqual(loop.frames.count, 4)
        XCTAssertEqual(loop.ticks, 7)
        XCTAssertEqual(loop.kind, .walk)

        var scene = GaleProject(name: "Scene", fps: 12)
        let layer = scene.addLayer(name: "Character").id
        let touched = LoopTools.insert(loop, into: &scene, layerID: layer, at: 0,
                                       placement: .init(cycles: 3, direction: 1, smoothTravel: false))
        XCTAssertEqual(touched, Array(0..<12))
        XCTAssertEqual(scene.frames.count, 12)
        XCTAssertEqual(scene.frames[1].hold, 2)
        XCTAssertEqual(scene.frames.map(\.key), scene.frames.map(\.key).sorted())
        // Cycle 2 walked 80 px further than cycle 1.
        let x0 = scene.frames[0].cel(layer).strokes[0].points[0].x
        let x4 = scene.frames[4].cel(layer).strokes[0].points[0].x
        XCTAssertEqual(x4 - x0, 80, accuracy: 1e-9)
        // New ids, never the originals.
        XCTAssertNotEqual(scene.frames[0].cel(layer).strokes[0].id, loop.frames[0].strokes[0].id)
        XCTAssertNotEqual(scene.frames[0].cel(layer).strokes[0].id, scene.frames[4].cel(layer).strokes[0].id)
    }

    func testInsertIntoExistingFramesKeepsWhatsThere() throws {
        let p = walkProject()
        let loop = try XCTUnwrap(LoopTools.makeLoop(from: p, layerIDs: [p.layers[0].id], range: 1...2, name: "Bit", kind: .loop))
        var scene = walkProject()
        let layer = scene.layers[0].id
        LoopTools.insert(loop, into: &scene, layerID: layer, at: 1)
        XCTAssertEqual(scene.frames.count, 4)
        XCTAssertEqual(scene.frames[1].cel(layer).strokes.count, 2)
        XCTAssertEqual(scene.frames[0].cel(layer).strokes.count, 1)
        let keys = scene.frames[1].cel(layer).strokes.map(\.key)
        XCTAssertEqual(keys, keys.sorted())
    }

    func testMirrorAndEmptyLoops() throws {
        let p = walkProject()
        let loop = try XCTUnwrap(LoopTools.makeLoop(from: p, layerIDs: [p.layers[0].id], range: 0...0, name: "One", kind: .idle))
        let m = LoopTools.mirrored(loop)
        let b1 = LoopTools.bounds(of: loop), b2 = LoopTools.bounds(of: m)
        XCTAssertEqual(b1.center.x, b2.center.x, accuracy: 1e-6)
        let empty = GaleProject(name: "E")
        XCTAssertNil(LoopTools.makeLoop(from: empty, layerIDs: [empty.layers[0].id], range: 0...0, name: "x", kind: .loop))
    }
}

final class StashTests: XCTestCase {
    func testFindsSeparateThings() {
        var cel = Cel()
        for s in rect(100, 100, 100, 100) { cel.append(s) }          // a box
        for s in rect(600, 400, 80, 80) { cel.append(s) }            // another box far away
        cel.append(line(from: Vec2(1000, 50), to: Vec2(1003, 52), count: 3))  // a speck, not worth saving
        let groups = StashDetector.clusters(cel.strokes)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.filter(StashDetector.isWorthSaving).count, 2)
    }

    func testPlanAddsThenUpdatesInsteadOfDuplicating() {
        var cel = Cel()
        for s in rect(100, 100, 100, 100) { cel.append(s) }
        let first = SmartStash.plan(cel: cel, existing: [], projectID: "p", frameID: "f", layerID: "l")
        XCTAssertEqual(first.upserts.count, 1)
        let item = first.upserts[0]
        XCTAssertEqual(item.bounds[0], 97, accuracy: 0.01)   // box minus half the 6 px line
        XCTAssertTrue(item.strokes.allSatisfy { s in s.points.allSatisfy { $0.x >= 0 && $0.y >= 0 } })

        // Nothing changed: nothing to save.
        XCTAssertTrue(SmartStash.plan(cel: cel, existing: [item], projectID: "p", frameID: "f", layerID: "l").upserts.isEmpty)

        // Add a door to the box: the same stash item updates.
        cel.append(line(from: Vec2(140, 200), to: Vec2(140, 160), count: 8))
        let second = SmartStash.plan(cel: cel, existing: [item], projectID: "p", frameID: "f", layerID: "l")
        XCTAssertEqual(second.upserts.count, 1)
        XCTAssertEqual(second.upserts[0].id, item.id)
        XCTAssertEqual(second.upserts[0].sourceStrokes.count, 5)
    }

    func testPlaceDropsACopyWhereYouWant() {
        var cel = Cel()
        for s in rect(0, 0, 100, 100) { cel.append(s) }
        let item = SmartStash.makeItem(group: cel.strokes, cel: cel, projectID: "p", frameID: "f", layerID: "l", name: "Box")
        var target = Cel()
        let added = SmartStash.place(item, at: Vec2(500, 500), into: &target)
        XCTAssertEqual(added.count, 4)
        XCTAssertEqual(target.strokes.count, 4)
        let b = Geometry.bounds(of: target.strokes)
        XCTAssertEqual(b.center.x, 500, accuracy: 0.5)
        XCTAssertEqual(b.center.y, 500, accuracy: 0.5)
        XCTAssertTrue(Set(target.strokes.map(\.id)).isDisjoint(with: cel.strokes.map(\.id)))
    }

    func testPruneKeepsPinned() {
        let old = Date(timeIntervalSince1970: 0)
        var items: [StashItem] = []
        for i in 0..<5 {
            var it = StashItem(name: "\(i)", auto: true, bounds: [0, 0, 1, 1], strokes: [], created: old.addingTimeInterval(Double(i)))
            it.updated = it.created
            if i == 0 { it.pinned = true }
            items.append(it)
        }
        let gone = SmartStash.itemsToPrune(items, keepAuto: 2)
        XCTAssertEqual(Set(gone), Set([items[1].id, items[2].id]))
    }
}

final class MotionBlurTests: XCTestCase {
    func cel(_ strokes: [Stroke]) -> Cel {
        var c = Cel()
        for s in strokes { c.append(s) }
        return c
    }

    func testMovingThingGetsATrail() {
        let before = cel(rect(100, 100, 50, 50))
        let after = cel(rect(160, 100, 50, 50))
        let trails = MotionBlur.trails(previous: before, current: after, settings: MotionBlurSettings(on: true, amount: 1, samples: 4))
        XCTAssertEqual(trails.count, 1)
        XCTAssertEqual(trails[0].motion.x, 60, accuracy: 0.5)
        XCTAssertEqual(trails[0].samples.count, 4)
        XCTAssertEqual(trails[0].samples.first!.offset.x, -60, accuracy: 0.5)   // farthest first
        XCTAssertLessThan(trails[0].samples.first!.alpha, trails[0].samples.last!.alpha)
    }

    func testStillThingsAndOffSettingsHaveNoTrail() {
        let a = cel(rect(100, 100, 50, 50))
        XCTAssertTrue(MotionBlur.trails(previous: a, current: a, settings: MotionBlurSettings(on: true)).isEmpty)
        let b = cel(rect(300, 100, 50, 50))
        XCTAssertTrue(MotionBlur.trails(previous: a, current: b, settings: MotionBlurSettings(on: false)).isEmpty)
        XCTAssertTrue(MotionBlur.trails(previous: nil, current: b, settings: MotionBlurSettings(on: true)).isEmpty)
    }

    func testTwoThingsMatchTheRightPartners() {
        let before = cel(rect(100, 100, 50, 50) + rect(800, 100, 50, 50))
        let after = cel(rect(120, 100, 50, 50) + rect(800, 160, 50, 50))
        let trails = MotionBlur.trails(previous: before, current: after, settings: MotionBlurSettings(on: true))
        XCTAssertEqual(trails.count, 2)
        let motions = trails.map(\.motion).sorted { $0.x > $1.x }
        XCTAssertEqual(motions[0].x, 20, accuracy: 0.5)
        XCTAssertEqual(motions[1].y, 60, accuracy: 0.5)
    }
}

final class HairSwayTests: XCTestCase {
    let region = HairRegion(layer: "l", polygon: [100, 100, 200, 100, 200, 300, 100, 300], root: [100, 100, 200, 100],
                            stiffness: 0.3, wind: 0, gust: 0.4, speed: 1)

    func testRootsStayAndTipsSwing() {
        let root = StrokePoint(x: 150, y: 100)
        let tip = StrokePoint(x: 150, y: 300)
        var maxRoot = 0.0, maxTip = 0.0
        for i in 0..<48 {
            let t = Double(i) / 24
            let out = HairSway.deform([root, tip], region: region, time: t)
            maxRoot = max(maxRoot, abs(out[0].x - 150))
            maxTip = max(maxTip, abs(out[1].x - 150))
        }
        XCTAssertLessThan(maxRoot, 0.001)
        XCTAssertGreaterThan(maxTip, 15)
    }

    func testOutsideStaysPut() {
        let far = StrokePoint(x: 500, y: 500)
        XCTAssertEqual(HairSway.deform([far], region: region, time: 0.37), [far])
        var off = region
        off.on = false
        let tip = StrokePoint(x: 150, y: 300)
        XCTAssertEqual(HairSway.deform([tip], region: off, time: 0.37), [tip])
    }

    func testLoopsExactly() {
        let tip = [StrokePoint(x: 150, y: 290)]
        let p = HairSway.period(region)
        for t in [0.0, 0.13, 0.5, 0.91] {
            let a = HairSway.deform(tip, region: region, time: t)[0]
            let b = HairSway.deform(tip, region: region, time: t + p)[0]
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func testStiffHairMovesLess() {
        func swing(_ r: HairRegion) -> Double {
            (0..<60).map { i in abs(HairSway.deform([StrokePoint(x: 150, y: 300)], region: r, time: Double(i) / 30)[0].x - 150) }.max()!
        }
        var stiff = region
        stiff.stiffness = 0.95
        XCTAssertLessThan(swing(stiff), swing(region) * 0.5)
    }

    func testWindLeansOneWay() {
        var windy = region
        windy.wind = 1
        windy.gust = 0
        let xs = (0..<30).map { HairSway.deform([StrokePoint(x: 150, y: 300)], region: windy, time: Double($0) / 15)[0].x }
        XCTAssertGreaterThan(xs.reduce(0, +) / Double(xs.count), 155)
    }

    func testBakeMakesOneFullSway() {
        var cel = Cel()
        cel.append(line(from: Vec2(150, 100), to: Vec2(150, 300), count: 20))
        let frames = HairSway.bake(cel, region: region, fps: 12)
        XCTAssertEqual(frames.count, Int((HairSway.period(region) * 12).rounded()))
        XCTAssertNotEqual(frames[0], frames[frames.count / 2])
        XCTAssertEqual(HairSway.root(for: [0, 0, 10, 0, 10, 20], side: .left), [0, 0, 0, 20])
    }
}

final class PaintBucketTests: XCTestCase {
    func testFillsInsideABox() throws {
        var cel = Cel()
        for s in rect(100, 100, 200, 150, size: 4) { cel.append(s) }
        let path = try XCTUnwrap(PaintBucket.fill(cel: cel, canvasWidth: 800, canvasHeight: 600, seed: Vec2(200, 170)))
        let b = Geometry.bounds(ofPath: path)
        // Fills the inside and tucks a little under the lines, but not past them.
        XCTAssertEqual(b.minX, 100, accuracy: 6)
        XCTAssertEqual(b.maxX, 300, accuracy: 6)
        XCTAssertEqual(b.minY, 100, accuracy: 6)
        XCTAssertEqual(b.maxY, 250, accuracy: 6)
        XCTAssertTrue(Geometry.contains(path, Vec2(200, 170)))
        XCTAssertFalse(Geometry.contains(path, Vec2(400, 400)))
    }

    func testSmallGapsStillFill() throws {
        var cel = Cel()
        let r = rect(100, 100, 200, 200, size: 4)
        cel.append(r[0])
        cel.append(r[1])
        cel.append(r[2])
        // Left side stops 5 px short of the corner.
        cel.append(line(from: Vec2(100, 300), to: Vec2(100, 105), count: 20, size: 4))
        let path = try XCTUnwrap(PaintBucket.fill(cel: cel, canvasWidth: 800, canvasHeight: 600, seed: Vec2(200, 200), gapClose: 4))
        XCTAssertLessThan(Geometry.bounds(ofPath: path).width, 230)
    }

    func testTapOnALineDoesNothingAndOutsideFillsTheRest() throws {
        var cel = Cel()
        for s in rect(100, 100, 200, 150, size: 4) { cel.append(s) }
        XCTAssertNil(PaintBucket.fill(cel: cel, canvasWidth: 800, canvasHeight: 600, seed: Vec2(100, 150)))
        let outside = try XCTUnwrap(PaintBucket.fill(cel: cel, canvasWidth: 800, canvasHeight: 600, seed: Vec2(700, 500)))
        XCTAssertGreaterThan(Geometry.bounds(ofPath: outside).width, 780)
        // An empty canvas fills everything.
        XCTAssertNotNil(PaintBucket.fill(cel: Cel(), canvasWidth: 100, canvasHeight: 100, seed: Vec2(50, 50)))
    }
}

final class UndoTests: XCTestCase {
    func testUndoRedo() {
        var u = UndoStack<Int>(limit: 3)
        var value = 0
        for v in 1...5 {
            u.record(value)
            value = v
        }
        XCTAssertEqual(u.past.count, 3)
        value = u.undo(current: value)!
        XCTAssertEqual(value, 4)
        value = u.undo(current: value)!
        XCTAssertEqual(value, 3)
        value = u.redo(current: value)!
        XCTAssertEqual(value, 4)
        u.record(value)
        XCTAssertFalse(u.canRedo)
    }
}

final class StrokeRoundingTests: XCTestCase {
    /// A quick zigzag drawn with a shaky finger: sharp corners plus small wobbles, sampled like a real touch screen.
    func shakyZigzag(seed: UInt64) -> [StrokePoint] {
        var rng = SeededRandom(seed)
        var pts: [StrokePoint] = []
        let corners: [(Double, Double)] = [(100, 300), (160, 220), (220, 300), (280, 220), (340, 300), (400, 220)]
        var t = 0.0
        for c in 0..<(corners.count - 1) {
            let a = corners[c], b = corners[c + 1]
            let steps = 30
            for k in 0..<steps {
                let f = Double(k) / Double(steps)
                pts.append(StrokePoint(x: a.0 + (b.0 - a.0) * f + rng.signed() * 1.2,
                                       y: a.1 + (b.1 - a.1) * f + rng.signed() * 1.2,
                                       pressure: 0.5, time: t))
                t += 1.0 / 120
            }
        }
        pts.append(StrokePoint(x: 400, y: 220, pressure: 0.5, time: t))
        return pts
    }

    /// The same steps the canvas takes when you lift your finger.
    func finish(_ raw: [StrokePoint], amount: Double, scale: Double = 1) -> [StrokePoint] {
        let st = StrokeStabilizer.stabilize(raw, amount: amount, scale: scale)
        return StrokeSmoother.round(StrokeShape.dedupe(st), radius: StrokeSmoother.radius(amount: amount, scale: scale))
    }

    func testCornersAndWobblesGetRounded() {
        let raw = shakyZigzag(seed: 9)
        let before = StrokeShape.sharpestBend(raw)
        let after = StrokeShape.sharpestBend(finish(raw, amount: 0.55))
        XCTAssertGreaterThan(before, 60, "the test line should start out jagged")
        XCTAssertLessThan(after, 30, "sharpest bend went from \(before) to \(after) degrees")
    }

    func testRoundingWorksZoomedOut() {
        // Zoomed out, canvas pixels are bigger on screen, so the same hand wobble is many canvas pixels.
        let raw = shakyZigzag(seed: 4).map { p -> StrokePoint in
            var q = p
            q.x *= 4
            q.y *= 4
            return q
        }
        let after = StrokeShape.sharpestBend(finish(raw, amount: 0.55, scale: 4), spacing: 16)
        XCTAssertLessThan(after, 30, "sharpest bend \(after) degrees")
    }

    func testRoundingKeepsEnds() {
        let raw = shakyZigzag(seed: 2)
        let out = StrokeSmoother.round(raw, radius: 10)
        XCTAssertEqual(out.first!.x, raw.first!.x, accuracy: 0.001)
        XCTAssertEqual(out.first!.y, raw.first!.y, accuracy: 0.001)
        XCTAssertEqual(out.last!.x, raw.last!.x, accuracy: 0.001)
        XCTAssertEqual(out.last!.y, raw.last!.y, accuracy: 0.001)
    }

    func testResampleIsEven() {
        let line = [StrokePoint(x: 0, y: 0), StrokePoint(x: 0.3, y: 0), StrokePoint(x: 10, y: 0), StrokePoint(x: 10.2, y: 0), StrokePoint(x: 20, y: 0)]
        let even = StrokeShape.resample(line, spacing: 2)
        XCTAssertEqual(even.count, 11)
        for i in 1..<even.count {
            XCTAssertEqual(even[i].x - even[i - 1].x, 2, accuracy: 0.001)
        }
    }

    func testOutlineEdgesAreSmooth() {
        let pts = finish(shakyZigzag(seed: 6), amount: 0.55)
        let stroke = Stroke(brush: Brush(kind: .pen, color: .black, size: 10), points: pts)
        let poly = StrokeShape.outline(of: stroke)
        // Walk one edge (the first half of the outline) and look for sudden jumps in direction.
        let edge = Array(poly.prefix(poly.count / 2 - 10)).map { StrokePoint(x: $0.x, y: $0.y) }
        let bend = StrokeShape.sharpestBend(Array(edge.dropFirst(10)), spacing: 4)
        XCTAssertLessThan(bend, 40, "edge bend \(bend) degrees")
    }
}
