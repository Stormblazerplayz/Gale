import XCTest
@testable import GaleFormat
@testable import GaleSync

final class SyncTests: XCTestCase {
    func sample() -> GaleProject {
        var p = GaleProject(name: "Sync", canvas: GaleCanvas(width: 800, height: 600), fps: 24)
        p.created = Date(timeIntervalSince1970: 1_700_000_000)
        p.modified = p.created
        let l2 = p.addLayer(name: "Ink")
        var cel = Cel()
        cel.append(Stroke(brush: Brush(kind: .pencil, color: RGBA(1, 0, 0), size: 4), points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3.5, y: 4)]).rounded)
        cel.append(Fill(color: .black, path: [0, 0, 10, 0, 10, 10]))
        p.frames[0].cels[l2.id] = cel
        p.insertFrame(Frame(hold: 3), after: nil)
        p.hair.append(HairRegion(layer: l2.id, polygon: [0, 0, 1, 0, 1, 1], root: [0, 0, 1, 0]))
        let t = p.addTrack(kind: .audio, name: "Voice")
        p.media.append(MediaItem(file: "a.m4a", kind: .audio, name: "Hi", duration: 2, sha256: "ab"))
        p.movie.clips.append(Clip(track: t.id, media: p.media[0].id, start: 1, inPoint: 0.25, duration: 1))
        p.motionBlur.on = true
        return p
    }

    func same(_ a: GaleProject, _ b: GaleProject, file: StaticString = #filePath, line: UInt = #line) {
        var x = a, y = b
        x.modified = y.modified
        XCTAssertEqual(x, y, file: file, line: line)
    }

    func testFlattenAndBuildRoundTrip() throws {
        let p = sample()
        let objects = SyncObjects.flatten(p)
        XCTAssertEqual(objects[p.id]?["$type"], .string("project"))
        let back = try XCTUnwrap(SyncObjects.build(objects, projectID: p.id))
        same(back, p)
    }

    func testDiffRebuildsTheNewProject() throws {
        let old = sample()
        var new = old
        new.name = "Renamed"
        new.frames[1].hold = 1
        let l = new.layers[1].id
        var cel = new.frames[0].cel(l)
        cel.append(Stroke(brush: Brush(), points: [StrokePoint(x: 9, y: 9)]).rounded)
        cel.fills.removeAll()
        new.frames[0].cels[l] = cel
        new.layers.remove(at: 0)

        var clock = HybridClock(actor: "ipad-1")
        var replica = SyncReplica(project: old, stamp: HybridClock.format(ms: 1, counter: 0, actor: "x"))
        let ops = SyncObjects.diff(SyncObjects.flatten(old), SyncObjects.flatten(new), clock: &clock)
        XCTAssertFalse(ops.isEmpty)
        XCTAssertTrue(ops.contains { $0.k == "$del" && $0.v == .bool(true) })
        replica.apply(ops)
        same(try XCTUnwrap(replica.project), new)
        // No change, no ops.
        XCTAssertTrue(SyncObjects.diff(SyncObjects.flatten(new), SyncObjects.flatten(new), clock: &clock).isEmpty)
    }

    func testRepliasAgreeWhateverTheOrder() throws {
        let base = sample()
        let start = HybridClock.format(ms: 1, counter: 0, actor: "x")
        var aClock = HybridClock(actor: "a"), bClock = HybridClock(actor: "b")
        var a1 = base
        a1.name = "From A"
        a1.fps = 12
        var b1 = base
        b1.name = "From B"
        b1.frames[0].hold = 4
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opsA = SyncObjects.diff(SyncObjects.flatten(base), SyncObjects.flatten(a1), clock: &aClock, now: now)
        let opsB = SyncObjects.diff(SyncObjects.flatten(base), SyncObjects.flatten(b1), clock: &bClock, now: now.addingTimeInterval(0.001))
        let all = opsA + opsB
        var results: [GaleProject] = []
        var rng = SystemRandomNumberGenerator()
        for round in 0..<6 {
            var r = SyncReplica(project: base, stamp: start)
            var shuffled = all.shuffled(using: &rng)
            if round % 2 == 0 { shuffled += shuffled.prefix(3) }   // duplicates
            r.apply(shuffled)
            results.append(try XCTUnwrap(r.project))
        }
        for r in results { same(r, results[0]) }
        XCTAssertEqual(results[0].name, "From B")   // B was later
        XCTAssertEqual(results[0].fps, 12)          // A's other change still lands
        XCTAssertEqual(results[0].frames[0].hold, 4)
    }

    func testClock() {
        var c = HybridClock(actor: "ipad k3!")
        XCTAssertEqual(c.actor, "ipadk3")
        let now = Date(timeIntervalSince1970: 1_763_229_600)
        let t1 = c.tick(now: now)
        let t2 = c.tick(now: now)
        let t3 = c.tick(now: now.addingTimeInterval(-5))   // clock went backwards
        XCTAssertEqual(t1, "1763229600000:00000:ipadk3")
        XCTAssertLessThan(t1, t2)
        XCTAssertLessThan(t2, t3)
        c.observe("1999999999999:00007:other")
        XCTAssertEqual(c.tick(now: now), "1999999999999:00008:ipadk3")
        XCTAssertNil(HybridClock.parse("12:3:x"))
    }

    func testStrokeOrphansAreIgnored() throws {
        let p = sample()
        var objects = SyncObjects.flatten(p)
        objects[p.layers[1].id]?["$del"] = .bool(true)
        let back = try XCTUnwrap(SyncObjects.build(objects, projectID: p.id))
        XCTAssertEqual(back.layers.count, 1)
        XCTAssertTrue(back.frames.allSatisfy { $0.cels.values.allSatisfy(\.isEmpty) || $0.cels[p.layers[1].id] == nil })
        objects[p.id]?["$del"] = .bool(true)
        XCTAssertNil(SyncObjects.build(objects, projectID: p.id))
    }

    func testMessagesAndPairing() throws {
        let op = SyncOp(t: "1763229600000:00000:a", a: "a", o: "s1", k: "pts", v: .array([.number(1), .number(2.5)]))
        let msgs: [SyncMessage] = [
            .hello(deviceId: "d", deviceName: "iPad", since: ["p": 3]),
            .push(p: "p", ops: [op], ref: "r1"),
            .ack(ref: "r1", seq: 9),
            .ops(p: "p", ops: [op], seq: 10),
            .live(p: "p", frame: "f", layer: "l", stroke: .object(["id": .string("x")]), done: false),
            .presence(deviceId: "d", deviceName: "iPad", p: "p", frame: "f"),
            .ping, .pong,
        ]
        for m in msgs {
            XCTAssertEqual(SyncMessage.decode(try m.encoded()), m)
        }
        let json = String(decoding: try SyncMessage.ack(ref: "r", seq: 2).encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"seq\":2"), json)
        XCTAssertEqual(SyncMessage.decode(Data(#"{"type":"brandNew"}"#.utf8)), .unknown("brandNew"))

        let info = try XCTUnwrap(PairingInfo(string: "gale://pair?v=1&host=192.168.1.20&port=47820&code=123456&name=Storm%20PC&id=srv1"))
        XCTAssertEqual(info.host, "192.168.1.20")
        XCTAssertEqual(info.name, "Storm PC")
        XCTAssertEqual(PairingInfo(url: try XCTUnwrap(info.url)), info)
        XCTAssertNil(PairingInfo(string: "gale://pair?host=x&code=12"))
        XCTAssertNil(PairingInfo(string: "https://pair?host=x&code=123456"))
    }
}
