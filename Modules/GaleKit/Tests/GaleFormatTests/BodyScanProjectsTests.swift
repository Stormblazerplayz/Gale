import XCTest
@testable import GaleFormat

/// The 3D body scan was taken out of Gale (Nov 2026). Projects and stash items it made are plain
/// Gale files, so they must keep opening and saving exactly like any other project.
final class BodyScanProjectsTests: XCTestCase {
    /// Builds a project the way the body scan's "turnaround" did: a "Guides" layer under the
    /// "Concept" layer, four held frames (front, 3/4, side, back) and a "Draw here" layer on top.
    func makeScanStyleProject() -> GaleProject {
        var p = GaleProject(name: "Space Ranger turnaround",
                            canvas: GaleCanvas(width: 1920, height: 1080, background: .white), fps: 12)
        p.created = Date(timeIntervalSince1970: 1_790_000_000)
        p.modified = p.created
        p.normalize()
        p.layers[0].name = "Concept"
        let concept = p.layers[0].id
        let guides = Layer(key: OrderKey.between(nil, p.layers[0].key) ?? "Zz", name: "Guides", opacity: 0.7)
        p.layers.insert(guides, at: 0)
        p.frames[0].hold = 6
        while p.frames.count < 4 { p.insertFrame(Frame(hold: 6), after: nil) }
        let pencil = Brush(kind: .pencil, color: RGBA(hex: "#333340")!, size: 3, opacity: 1)
        for i in 0..<4 {
            let x = Double(200 + i * 420)
            var body = Cel()
            body.append(Stroke(brush: pencil, points: [StrokePoint(x: x, y: 200, pressure: 0.75),
                                                       StrokePoint(x: x + 40, y: 600, pressure: 0.75),
                                                       StrokePoint(x: x, y: 950, pressure: 0.75)]).rounded)
            body.append(Fill(color: RGBA(hex: "#E68050")!, path: [x, 200, x + 80, 200, x + 80, 400, x, 400]))
            p.frames[i].cels[concept] = body
            var lines = Cel()
            lines.append(Stroke(brush: pencil, points: [StrokePoint(x: 80, y: 200, pressure: 0.7),
                                                        StrokePoint(x: 1840, y: 200, pressure: 0.7)]).rounded)
            p.frames[i].cels[guides.id] = lines
        }
        p.addLayer(name: "Draw here")
        return p
    }

    func testScanMadeProjectsStillSaveAndOpen() throws {
        let p = makeScanStyleProject()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-scan-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try GaleIO.writeProject(p, to: folder)
        let back = try GaleIO.readProject(at: folder)

        XCTAssertEqual(back, p)
        XCTAssertEqual(back.layers.map(\.name), ["Guides", "Concept", "Draw here"])
        XCTAssertEqual(back.layers.map(\.key), back.layers.map(\.key).sorted(), "Layer order must survive saving")
        XCTAssertEqual(back.layers[0].opacity, 0.7, accuracy: 0.0001)
        XCTAssertEqual(back.frames.count, 4)
        XCTAssertEqual(back.totalTicks, 24)
        XCTAssertEqual(back.frames[3].cel(back.layers[1].id).strokes.count, 1)
        XCTAssertEqual(back.frames[3].cel(back.layers[1].id).fills.count, 1)
        XCTAssertEqual(back.frames[0].cel(back.layers[1].id).strokes.first?.brush.kind, .pencil)
    }

    func testOldScanProjectFileOpens() throws {
        // A project.json written by an older Gale that still had the body scan.
        let json = #"""
        {"format":"gale/1","name":"Hero","created":"2026-10-01T18:00:00Z","modified":"2026-10-02T18:00:00Z","canvas":{"width":1080,"height":1920,"background":"#FFFFFFFF"},"fps":12,
         "layers":[{"id":"c1","key":"a0","name":"Concept"},{"id":"d1","key":"a1","name":"Draw here"}],
         "frames":[{"id":"f1","key":"a0","hold":1,"cels":{"c1":{"strokes":[{"brush":{"kind":"pencil","size":3},"pts":[10,20,0.75,30,40,0.75]}],
                    "fills":[{"color":"#E68050FF","path":[0,0,10,0,10,10]}]}}}]}
        """#
        let p = try GaleIO.decode(GaleProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "Hero")
        XCTAssertEqual(p.layers.map(\.name), ["Concept", "Draw here"])
        XCTAssertEqual(p.frames.count, 1)
        XCTAssertEqual(p.frames[0].cel("c1").strokes.count, 1)
        XCTAssertEqual(p.frames[0].cel("c1").strokes.first?.brush.kind, .pencil)
        XCTAssertEqual(p.frames[0].cel("c1").fills.count, 1)
        // And it saves again without losing anything.
        let again = try GaleIO.decode(GaleProject.self, from: GaleIO.encode(p))
        XCTAssertEqual(again, p)
    }

    func testScanStashItemsStillOpen() throws {
        // The body scan could save a character to the stash. Those items are ordinary stash items.
        let stroke = Stroke(brush: Brush(kind: .pencil, size: 3),
                            points: [StrokePoint(x: 0, y: 0, pressure: 0.6), StrokePoint(x: 120, y: 300, pressure: 0.6)]).rounded
        let item = StashItem(name: "Space Ranger", auto: false, bounds: [10, 20, 120, 300], strokes: [stroke],
                             created: Date(timeIntervalSince1970: 1_790_000_000))
        let back = try GaleIO.decode(StashItem.self, from: GaleIO.encode(item))
        XCTAssertEqual(back, item)
        XCTAssertEqual(back.strokes.first?.brush.kind, .pencil)
    }
}
