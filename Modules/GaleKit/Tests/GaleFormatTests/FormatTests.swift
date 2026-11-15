import XCTest
@testable import GaleFormat

final class FormatTests: XCTestCase {
    func testColorHex() {
        XCTAssertEqual(RGBA(hex: "#FF8800")?.hex, "#FF8800FF")
        XCTAssertEqual(RGBA(hex: "#f80")?.hex, "#FF8800FF")
        XCTAssertEqual(RGBA(hex: "00000080")?.a ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertNil(RGBA(hex: "#12"))
        XCTAssertNil(RGBA(hex: "#GGGGGG"))
        XCTAssertEqual(RGBA(2, -1, 0.5).hex, "#FF0080FF")
    }

    func testOrderKeysMatchFractionalIndexing() {
        // Same answers as the rocicorp "fractional-indexing" package.
        XCTAssertEqual(OrderKey.between(nil, nil), "a0")
        XCTAssertEqual(OrderKey.between("a0", nil), "a1")
        XCTAssertEqual(OrderKey.between("a1", nil), "a2")
        XCTAssertEqual(OrderKey.between(nil, "a0"), "Zz")
        XCTAssertEqual(OrderKey.between("a0", "a1"), "a0V")
        XCTAssertEqual(OrderKey.between("a1", "a2"), "a1V")
        XCTAssertEqual(OrderKey.between("a0V", "a1"), "a0l")
        XCTAssertEqual(OrderKey.between("Zz", "a0"), "ZzV")
        XCTAssertEqual(OrderKey.between("Zz", "a1"), "a0")
        XCTAssertEqual(OrderKey.between("az", nil), "b00")
        XCTAssertEqual(OrderKey.between("b00", nil), "b01")
        XCTAssertEqual(OrderKey.between("a0", "a0V"), "a0G")
        XCTAssertNil(OrderKey.between("a1", "a0"))
        XCTAssertNil(OrderKey.between("a0", "a0"))
    }

    func testOrderKeysStayShortWhenAppending() {
        var last: String? = nil
        var keys: [String] = []
        for _ in 0..<5000 {
            let k = OrderKey.between(last, nil)!
            keys.append(k)
            last = k
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertLessThanOrEqual(keys.last!.count, 4)
    }

    func testManyKeysBetween() {
        let ks = OrderKey.keys(between: "a0", and: "a1", count: 50)
        XCTAssertEqual(ks.count, 50)
        XCTAssertEqual(ks, ks.sorted())
        XCTAssertTrue(ks.allSatisfy { $0 > "a0" && $0 < "a1" })
        XCTAssertEqual(Set(ks).count, 50)
        // Inserting at the front over and over keeps working.
        var first = "a0"
        for _ in 0..<500 {
            let k = OrderKey.between(nil, first)!
            XCTAssertLessThan(k, first)
            first = k
        }
    }

    func testStrokePacking() throws {
        let s = Stroke(brush: Brush(kind: .pencil, color: RGBA(1, 0, 0), size: 4),
                       points: [StrokePoint(x: 1.234567, y: 2, pressure: 0.33333, time: 0),
                                StrokePoint(x: 10, y: 20.005, pressure: 1, altitude: 0.5, azimuth: 1, time: 0.0166)])
        let data = try GaleIO.encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"pts\":[1.23,2,0.333"), json)
        let back = try GaleIO.decode(Stroke.self, from: data)
        XCTAssertEqual(back, s.rounded)
        XCTAssertEqual(back.points.count, 2)
        XCTAssertEqual(back.brush.kind, .pencil)
    }

    func testProjectRoundTrip() throws {
        var p = GaleProject(name: "Test", canvas: GaleCanvas(width: 800, height: 600), fps: 24)
        p.created = Date(timeIntervalSince1970: 1_700_000_000)
        p.modified = p.created
        let layer2 = p.addLayer(name: "Color")
        var cel = Cel()
        cel.append(Stroke(brush: Brush(), points: [StrokePoint(x: 1, y: 1), StrokePoint(x: 5, y: 5)]).rounded)
        cel.append(Fill(color: .black, path: [0, 0, 10, 0, 10, 10]))
        p.frames[0].cels[layer2.id] = cel
        p.insertFrame(Frame(hold: 2), after: nil)
        p.hair.append(HairRegion(layer: layer2.id, polygon: [0, 0, 100, 0, 100, 100], root: [0, 0, 100, 0]))
        let track = p.addTrack(kind: .audio, name: "Voice")
        p.media.append(MediaItem(file: "a.m4a", kind: .audio, name: "Voice 1", duration: 3))
        p.movie.clips.append(Clip(track: track.id, media: p.media[0].id, start: 1, inPoint: 0.5, duration: 2))

        let data = try GaleIO.encode(p, pretty: true)
        let back = try GaleIO.decode(GaleProject.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.totalTicks, 3)
        XCTAssertEqual(back.layers.map(\.name), ["Layer 1", "Color"])
        XCTAssertEqual(back.movie.clips[0].length, 2)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"in\" : 0.5"))
    }

    func testOldOrBrokenFilesStillOpen() throws {
        let json = #"{"name":"Old","frames":[{"cels":{"x":{"strokes":[{"pts":[1,2,0.5,1.5,0,0]}]}}}],"brandNewThing":42,"fps":999}"#
        let p = try GaleIO.decode(GaleProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "Old")
        XCTAssertEqual(p.fps, 60)
        XCTAssertEqual(p.layers.count, 1)
        XCTAssertEqual(p.frames.count, 1)
        XCTAssertEqual(p.frames[0].cel("x").strokes.first?.points.first?.x, 1)
        XCTAssertEqual(p.frames[0].cel("x").strokes.first?.brush.kind, .pen)
    }

    func testJavaScriptDates() throws {
        let json = #"{"name":"JS","created":"2026-11-15T18:00:00.123Z","modified":1794765600000}"#
        let p = try GaleIO.decode(GaleProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.created.timeIntervalSince1970, 1_794_765_600.123, accuracy: 0.01)
        XCTAssertEqual(p.modified.timeIntervalSince1970, 1_794_765_600, accuracy: 0.01)
    }

    func testFrameMovesKeepKeysSorted() {
        var p = GaleProject(name: "M")
        for _ in 0..<5 { p.insertFrame(Frame(), after: nil) }
        let ids = p.frames.map(\.id)
        p.moveFrame(from: 0, to: 4)
        XCTAssertEqual(p.frames.map(\.id), Array(ids[1...4]) + [ids[0]] + [ids[5]])
        XCTAssertEqual(p.frames.map(\.key), p.frames.map(\.key).sorted())
        p.moveLayer(from: 0, to: 0)
        p.insertFrame(Frame(), after: -1)
        XCTAssertEqual(p.frames.map(\.key), p.frames.map(\.key).sorted())
    }

    func testLibraryItemsRoundTrip() throws {
        let loop = LoopItem(name: "Walk", kind: .walk, fps: 12, width: 100, height: 100, stride: 40,
                            frames: [LoopFrame(hold: 2, strokes: [Stroke(brush: Brush(), points: [StrokePoint(x: 1, y: 2)]).rounded])],
                            created: Date(timeIntervalSince1970: 1_700_000_000))
        let back = try GaleIO.decode(LoopItem.self, from: GaleIO.encode(loop))
        XCTAssertEqual(back, loop)
        XCTAssertEqual(back.ticks, 2)
        let stash = StashItem(name: "Tree", auto: true, bounds: [1, 2, 3, 4], strokes: [], created: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try GaleIO.decode(StashItem.self, from: GaleIO.encode(stash)), stash)
    }

    func testSafeName() {
        XCTAssertEqual(GaleIO.safeName("My/Cool:Anim"), "My-Cool-Anim")
        XCTAssertEqual(GaleIO.safeName("   "), "Untitled")
    }
}
