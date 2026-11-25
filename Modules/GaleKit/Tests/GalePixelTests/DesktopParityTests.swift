import XCTest
import Foundation
@testable import GaleFormat
@testable import GalePixel
@testable import GaleSync

/// The Windows app draws pixel stories with its own JavaScript copy of the renderer.
/// desktop/test/fixtures/pixel-swift.json holds what this Swift code makes for one story, and the desktop
/// tests check the JavaScript makes exactly the same pictures, GIF, sprite sheet and sync objects.
/// This test fails if the Swift side changes without the fixture. To rewrite it, run with GALE_WRITE_FIXTURE=1.
final class DesktopParityTests: XCTestCase {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("desktop/test/fixtures/pixel-swift.json")

    static func fnv(_ bytes: [UInt8]) -> String {
        var h: UInt32 = 2166136261
        for b in bytes { h ^= UInt32(b); h = h &* 16777619 }
        let s = String(h, radix: 16)
        return String(repeating: "0", count: 8 - s.count) + s
    }

    static func fixtureStory() -> PixelStory {
        var s = PixelStory(width: 24, height: 18, palette: .sweetie16)
        var g = PixelGrid(width: 24, height: 18)
        g.drawLine(GridPoint(0, 0), GridPoint(23, 17), color: 3, size: 2, mirrorX: true)
        g.drawEllipse(GridPoint(4, 3), GridPoint(14, 11), color: 6)
        g.drawRect(GridPoint(16, 1), GridPoint(22, 6), color: 9, filled: true)
        g.floodFill(GridPoint(9, 7), color: 12)
        s.scenes[0].frames[0].cells = g.cells
        s.scenes[0].caption = "Once upon a time, a tiny frog \u{2014} called \u{201C}Pip\u{201D} \u{2014} wanted to see the sea\u{2026} Caf\u{E9}!"
        s.scenes[0].transition = .iris
        s.scenes[0].bubbles = [
            SpeechBubble(text: "Ribbit! Ribbit ribbit, said the frog loudly", x: 0.3, y: 0.2, tailX: 0.5, tailY: 0.9),
            SpeechBubble(text: "hmm", x: 0.8, y: 0.7, tailX: 0.1, tailY: 0.6, style: .thought),
        ]
        s.insertFrame(PixelFrame(hold: 3, cells: g.flippedHorizontally().cells), scene: 0, after: nil)
        s.insertFrame(PixelFrame(hold: 1, cells: g.shifted(dx: 3, dy: -2).cells), scene: 0, after: 0)
        var two = PixelScene(name: "Sea", fps: 6, loops: 3, background: 11, caption: "The end.\nOr is it?", transition: .fade,
                             frames: [PixelFrame(cells: g.flippedVertically().cells)])
        two.bubbles = [SpeechBubble(text: "WOW", x: 0.5, y: 0.5, tailX: 0.95, tailY: 0.5, style: .shout),
                       SpeechBubble(text: "Beach", x: 0.15, y: 0.85, style: .sign)]
        s.insertScene(two, after: nil)
        var three = PixelScene(name: "Wipe", fps: 12, loops: 1, transition: .wipe, frames: [PixelFrame(cells: g.cells)])
        three.bubbles = [SpeechBubble(text: "left", x: 0.7, y: 0.3, tailX: 0.02, tailY: 0.35)]
        s.insertScene(three, after: nil)
        s.paper = RGBA(hex: "#FFF1E8FF")!
        return s
    }

    /// Everything the desktop checks, worked out from `s` (ids don't matter here).
    static func results(_ s: PixelStory) -> [String: Any] {
        var g = PixelGrid(width: 24, height: 18)
        g.drawLine(GridPoint(0, 0), GridPoint(23, 17), color: 3, size: 2, mirrorX: true)
        g.drawEllipse(GridPoint(4, 3), GridPoint(14, 11), color: 6)
        g.drawRect(GridPoint(16, 1), GridPoint(22, 6), color: 9, filled: true)
        let filled = g.floodFill(GridPoint(9, 7), color: 12)
        let r = StoryRenderer(story: s, maxSide: 200)
        var times: [Double] = [0, 0.1, 0.25, 0.4, 0.75, 1.3, 2.2, 3.7]
        for span in r.timing.spans {
            times += [span.start + 0.05, span.start + 0.2, span.start + 0.45, span.start + span.duration * 0.7]
        }
        times.append(r.timing.total - 0.001)
        let images: [[String: Any]] = times.map { t in
            let img = r.image(at: t, loop: false)
            return ["t": t, "w": img.width, "h": img.height, "hash": fnv(img.bytes)]
        }
        let frames = r.frames(perSecond: 25)
        var gif = GIFEncoder(width: r.layout.width, height: r.layout.height)
        for f in frames { gif.add(f.image, centiseconds: f.centiseconds) }
        let gifData = gif.finish()
        let sheet = SpriteSheet.render(s, scene: 0, scale: 3, transparent: false)
        let editor = PixelRender.editorFrame(s, scene: 0, frame: 1, onion: PixelOnion(on: true, before: 1, after: 1, opacity: 0.5))
        var shapes: [[String: Any]] = []
        for scene in s.scenes {
            for b in scene.bubbles {
                let sh = r.bubbleShape(b, text: b.text)
                let cells = sh.cells.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map { [$0.x, $0.y] }
                shapes.append(["text": b.text, "cells": cells, "box": [sh.box.x, sh.box.y, sh.box.w, sh.box.h], "lines": sh.lines])
            }
        }
        var switched = s
        switched.switchPalette(to: .gameBoy)
        var resized = s
        resized.resize(width: 30, height: 10)
        return [
            "filled": filled,
            "layout": ["artScale": r.layout.artScale, "textScale": r.layout.textScale, "width": r.layout.width,
                       "height": r.layout.height, "barHeight": r.layout.barHeight, "captionChars": r.layout.captionChars],
            "spans": r.timing.spans.map { [$0.start, $0.duration, $0.typeStart] },
            "total": r.timing.total,
            "images": images,
            "frames": frames.map { [fnv($0.image.bytes), $0.centiseconds] as [Any] },
            "gif": ["size": gifData.count, "hash": fnv([UInt8](gifData))],
            "sheet": ["w": sheet.image.width, "h": sheet.image.height, "hash": fnv(sheet.image.bytes),
                      "json": SpriteSheet.json(s, scene: 0, layout: sheet.layout, imageName: "frog \"1\".png")],
            "editor": fnv(editor.bytes),
            "shapes": shapes,
            "switched": switched.scenes.map { sc in sc.frames.map { PixelRuns.encode($0.cells) } },
            "switchedBackgrounds": switched.scenes.map(\.background),
            "resized": resized.scenes.map { sc in sc.frames.map { PixelRuns.encode($0.cells) } },
            "wrapped": PixelFont.wrap("Hello there, this is a looooooooooooong word test\n\nnew para ", maxChars: 10),
            "ellipse": PixelGrid.ellipse(GridPoint(2, 1), GridPoint(9, 6)).map { [$0.x, $0.y] },
        ]
    }

    func testDesktopFixtureMatchesSwift() throws {
        let url = DesktopParityTests.fixtureURL
        if ProcessInfo.processInfo.environment["GALE_WRITE_FIXTURE"] == "1" {
            var p = GaleProject(id: "projfixture", name: "Fixture", pixel: DesktopParityTests.fixtureStory())
            p.created = Date(timeIntervalSince1970: 1_700_000_000)
            p.modified = p.created
            var out = DesktopParityTests.results(p.pixel!)
            out["project"] = try JSONSerialization.jsonObject(with: GaleIO.encode(p))
            out["objects"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncObjects.flatten(p)))
            try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: url)
            return
        }
        let data = try Data(contentsOf: url)
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Read the story back from the fixture (so the ids are the fixture's) and check every result.
        let projectData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(fixture["project"]))
        let p = try GaleIO.decode(GaleProject.self, from: projectData)
        let story = try XCTUnwrap(p.pixel)
        let now = DesktopParityTests.results(story)
        for (key, value) in now {
            let a = try JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys])
            let b = try JSONSerialization.data(withJSONObject: ["v": try XCTUnwrap(fixture[key], key)], options: [.sortedKeys])
            XCTAssertEqual(String(decoding: a, as: UTF8.self), String(decoding: b, as: UTF8.self),
                           "\(key) changed: rewrite the desktop fixture (GALE_WRITE_FIXTURE=1) and make the JavaScript match")
        }
        // The flat sync objects must still be what the desktop expects.
        let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncObjects.flatten(p)))
        let a = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: try XCTUnwrap(fixture["objects"]), options: [.sortedKeys])
        XCTAssertEqual(String(decoding: a, as: UTF8.self), String(decoding: b, as: UTF8.self))
    }
}
