import XCTest
@testable import GaleFormat
@testable import GalePixel
@testable import GaleSync

/// A small real story used by many tests: two scenes, a caption, bubbles and a held frame.
func makeStory() -> PixelStory {
        var s = PixelStory(width: 16, height: 12, palette: .pico8)
        var g = PixelGrid(width: 16, height: 12)
        g.drawLine(GridPoint(0, 0), GridPoint(15, 11), color: 8)
        s.scenes[0].frames[0].cells = g.cells
        s.scenes[0].caption = "Once upon a time, a tiny frog wanted to see the sea."
        s.scenes[0].bubbles = [SpeechBubble(text: "Ribbit!", x: 0.3, y: 0.2, tailX: 0.5, tailY: 0.8)]
        s.insertFrame(PixelFrame(hold: 2, cells: g.flippedHorizontally().cells), scene: 0, after: nil)
        var two = PixelScene(name: "Sea", fps: 6, loops: 3, background: 12, caption: "The end.", transition: .fade,
                             frames: [PixelFrame.blank(width: 16, height: 12)])
        two.bubbles = [SpeechBubble(text: "Wow", style: .shout)]
        s.insertScene(two, after: nil)
        return s
}

final class PixelFormatTests: XCTestCase {
    func story() -> PixelStory { makeStory() }

    func testRunsRoundTrip() {
        let cells: [UInt8] = [0, 0, 0, 5, 5, 1, 0, 0]
        XCTAssertEqual(PixelRuns.encode(cells), [3, 0, 2, 5, 1, 1, 2, 0])
        XCTAssertEqual(PixelRuns.decode([3, 0, 2, 5, 1, 1, 2, 0]), cells)
        XCTAssertEqual(PixelRuns.encode([]), [])
        // Bad pairs are skipped, indexes are clamped, and the limit holds.
        XCTAssertEqual(PixelRuns.decode([2, 300, -1, 4, .nan, 1, 1, 7]), [255, 255, 7])
        XCTAssertEqual(PixelRuns.decode([1_000_000, 3], limit: 5).count, 5)
    }

    func testProjectFileRoundTrip() throws {
        let p = GaleProject(name: "Frog", pixel: story())
        let data = try GaleIO.encode(p)
        let back = try GaleIO.decode(GaleProject.self, from: data)
        XCTAssertEqual(back.pixel, p.pixel)
        XCTAssertTrue(back.isPixelStory)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"runs\""), "frames are stored as runs")
        XCTAssertFalse(json.contains("\"cells\""))
    }

    func testDrawingsHaveNoPixelField() throws {
        let p = GaleProject(name: "Plain")
        let json = String(decoding: try GaleIO.encode(p), as: UTF8.self)
        XCTAssertFalse(json.contains("pixel"))
        XCTAssertNil(try GaleIO.decode(GaleProject.self, from: Data("{\"name\":\"x\"}".utf8)).pixel)
    }

    func testNormalizeFixesBadFiles() throws {
        let raw = """
        {"name": "Broken", "pixel": {"width": 4, "height": 2, "palette": ["#FF0000", "#00FF00"],
          "scenes": [{"name": "A", "fps": 99, "loops": 0, "background": 40,
            "frames": [{"runs": [3, 1, 100, 9]}, {"key": "a0", "runs": []}]}]}}
        """
        let p = try GaleIO.decode(GaleProject.self, from: Data(raw.utf8))
        let s = try XCTUnwrap(p.pixel)
        XCTAssertEqual(s.width, PixelStory.minSide, "sizes are kept at least 8")
        XCTAssertEqual(s.palette[0], .clear, "index 0 is always see-through")
        XCTAssertEqual(s.scenes[0].fps, 30)
        XCTAssertEqual(s.scenes[0].loops, 1)
        XCTAssertEqual(s.scenes[0].background, 0)
        for f in s.scenes[0].frames {
            XCTAssertEqual(f.cells.count, s.cellCount)
            XCTAssertTrue(f.cells.allSatisfy { Int($0) < s.palette.count })
        }
        // An empty story still gets one scene with one frame.
        let empty = try GaleIO.decode(GaleProject.self, from: Data("{\"pixel\": {}}".utf8))
        XCTAssertEqual(empty.pixel?.scenes.count, 1)
        XCTAssertEqual(empty.pixel?.scenes[0].frames.count, 1)
    }

    func testSceneAndFrameOrder() {
        var s = story()
        XCTAssertEqual(s.scenes.map(\.name), ["Scene 1", "Sea"])
        s.moveScene(from: 1, to: 0)
        XCTAssertEqual(s.scenes.map(\.name), ["Sea", "Scene 1"])
        let keys = s.scenes.map(\.key)
        XCTAssertEqual(keys, keys.sorted(), "keys follow the order")
        let firstID = s.scenes[1].frames[0].id
        s.moveFrame(scene: 1, from: 0, to: 1)
        XCTAssertEqual(s.scenes[1].frames[1].id, firstID)
        var copy = s
        copy.normalize()
        XCTAssertEqual(copy.scenes.map(\.id), s.scenes.map(\.id), "sorting by key keeps the moved order")
        XCTAssertEqual(copy.scenes[1].frames.map(\.id), s.scenes[1].frames.map(\.id))
    }

    func testResizeAndSwitchPalette() {
        var s = story()
        let before = s.scenes[0].frames[0].cells
        s.resize(width: 20, height: 8)
        XCTAssertEqual(s.scenes[0].frames[0].cells.count, 160)
        XCTAssertEqual(s.scenes[0].frames[0].cells[0], before[0])
        XCTAssertEqual(s.scenes[0].frames[0].cells[20 + 1], before[16 + 1])
        s.switchPalette(to: .gameBoy)
        XCTAssertEqual(s.palette.count, 5)
        XCTAssertEqual(s.paletteName, "Game Boy")
        XCTAssertTrue(s.scenes.allSatisfy { sc in sc.frames.allSatisfy { $0.cells.allSatisfy { $0 < 5 } } })
        XCTAssertEqual(s.scenes[0].frames[0].cells[0] != 0, true, "ink stays ink")
    }
}

final class PixelToolTests: XCTestCase {
    func testLineHasNoGapsAndHitsBothEnds() {
        for (a, b) in [(GridPoint(0, 0), GridPoint(9, 3)), (GridPoint(5, 9), GridPoint(1, 0)), (GridPoint(3, 3), GridPoint(3, 3))] {
            let pts = PixelGrid.line(a, b)
            XCTAssertEqual(pts.first, a)
            XCTAssertEqual(pts.last, b)
            for (p, q) in zip(pts, pts.dropFirst()) {
                XCTAssertLessThanOrEqual(max(abs(p.x - q.x), abs(p.y - q.y)), 1, "no gaps")
            }
            XCTAssertEqual(pts.count, max(abs(a.x - b.x), abs(a.y - b.y)) + 1, "no doubled cells")
        }
    }

    func testFloodFillStopsAtWallsAndCorners() {
        var g = PixelGrid(width: 5, height: 5)
        // A diagonal wall: the fill must not leak through corners.
        for i in 0..<5 { g[GridPoint(i, i)] = 1 }
        let changed = g.floodFill(GridPoint(4, 0), color: 2)
        XCTAssertEqual(changed, 10)
        XCTAssertEqual(g[GridPoint(0, 4)], 0, "the other side stays empty")
        XCTAssertEqual(g.floodFill(GridPoint(4, 0), color: 2), 0, "same color changes nothing")
        XCTAssertEqual(g.floodFill(GridPoint(9, 9), color: 3), 0, "outside the grid changes nothing")
        // Filling a big empty grid works without running out of stack.
        var big = PixelGrid(width: 256, height: 256)
        XCTAssertEqual(big.floodFill(GridPoint(100, 100), color: 4), 65536)
    }

    func testStampSizeAndMirror() {
        var g = PixelGrid(width: 8, height: 8)
        g.stamp(GridPoint(1, 1), color: 3, size: 3, mirrorX: true)
        XCTAssertEqual(g.inkCount, 18)
        XCTAssertEqual(g[GridPoint(0, 0)], 3)
        XCTAssertEqual(g[GridPoint(7, 0)], 3, "mirrored to the right side")
        var h = PixelGrid(width: 8, height: 8)
        h.stamp(GridPoint(0, 0), color: 1, size: 2)
        XCTAssertEqual(h.inkCount, 4)
        var e = h
        e.stamp(GridPoint(0, 0), color: 0, size: 2)
        XCTAssertEqual(e.inkCount, 0, "erasing is painting with 0")
    }

    func testShapes() {
        var g = PixelGrid(width: 10, height: 10)
        g.drawRect(GridPoint(1, 1), GridPoint(4, 3), color: 2)
        XCTAssertEqual(g.inkCount, 10)
        var f = PixelGrid(width: 10, height: 10)
        f.drawRect(GridPoint(4, 3), GridPoint(1, 1), color: 2, filled: true)
        XCTAssertEqual(f.inkCount, 12)
        let ring = Set(PixelGrid.ellipse(GridPoint(0, 0), GridPoint(8, 8)))
        let disc = Set(PixelGrid.ellipse(GridPoint(0, 0), GridPoint(8, 8), filled: true))
        XCTAssertTrue(ring.isSubset(of: disc))
        XCTAssertTrue(ring.contains(GridPoint(4, 0)) && ring.contains(GridPoint(4, 8)) && ring.contains(GridPoint(0, 4)) && ring.contains(GridPoint(8, 4)))
        XCTAssertFalse(ring.contains(GridPoint(4, 4)))
        for p in ring { XCTAssertTrue(ring.contains(GridPoint(8 - p.x, p.y)), "round shapes are symmetric") }
    }

    func testShiftAndFlip() {
        var g = PixelGrid(width: 4, height: 3)
        g[GridPoint(3, 2)] = 7
        XCTAssertEqual(g.shifted(dx: 1, dy: 1)[GridPoint(0, 0)], 7, "wraps around")
        XCTAssertEqual(g.shifted(dx: 1, dy: 0, wrap: false).inkCount, 0, "falls off without wrap")
        XCTAssertEqual(g.flippedHorizontally()[GridPoint(0, 2)], 7)
        XCTAssertEqual(g.flippedVertically()[GridPoint(3, 0)], 7)
        g.replace(7, with: 2)
        XCTAssertEqual(g[GridPoint(3, 2)], 2)
    }

    func testOnionGhosts() {
        let onion = PixelOnion(on: true, before: 2, after: 1, opacity: 0.4)
        let ghosts = onion.ghosts(current: 2, count: 5)
        XCTAssertEqual(ghosts.map(\.index), [0, 1, 3])
        XCTAssertLessThan(ghosts[0].alpha, ghosts[1].alpha, "farther ghosts are fainter")
        XCTAssertTrue(onion.ghosts(current: 0, count: 5).allSatisfy { $0.index > 0 }, "nothing before the first frame")
        XCTAssertEqual(PixelOnion(on: true, before: 1).ghosts(current: 0, count: 3, loop: true).map(\.index), [2])
        XCTAssertTrue(PixelOnion(on: false).ghosts(current: 2, count: 5).isEmpty)

        var s = PixelStory(width: 8, height: 8, palette: .mono)
        var g = PixelGrid(width: 8, height: 8)
        g[GridPoint(2, 2)] = 1
        s.scenes[0].frames[0].cells = g.cells
        s.insertFrame(PixelFrame.blank(width: 8, height: 8), scene: 0, after: 0)
        let img = PixelRender.editorFrame(s, scene: 0, frame: 1, onion: PixelOnion(on: true, before: 1))
        XCTAssertNotEqual(img[2, 2], Pixel32(s.paper), "the ghost of frame 1 shows on frame 2")
        XCTAssertEqual(img[5, 5], Pixel32(s.paper))
    }
}

final class StoryTests: XCTestCase {
    func testTimingAndLocate() {
        let s = makeStory()
        let timing = StoryTiming(s)
        XCTAssertEqual(timing.spans.count, 2)
        let one = s.scenes[0]
        // Scene 1 has a long caption, so reading time wins over two loops of 3 ticks at 8 fps.
        let letters = StoryTiming.letters(one)
        XCTAssertEqual(letters, one.caption.count + 7)
        XCTAssertEqual(timing.spans[0].duration, StoryTiming.typeDelay + Double(letters) / 24 + StoryTiming.readSeconds, accuracy: 1e-9)
        XCTAssertEqual(timing.spans[1].start, timing.spans[0].duration, accuracy: 1e-9)
        XCTAssertEqual(timing.total, timing.spans[1].end, accuracy: 1e-9)
        XCTAssertEqual(timing.locate(0).scene, 0)
        XCTAssertEqual(timing.locate(timing.spans[1].start + 0.01).scene, 1)
        XCTAssertEqual(timing.locate(timing.total + 0.01).scene, 0, "loops back to the start")
        XCTAssertEqual(timing.locate(timing.total + 5, loop: false).scene, 1, "or stays on the last scene")
        XCTAssertEqual(timing.locate(-.infinity).scene, 0)
        XCTAssertEqual(timing.typed(scene: 0, local: 0), 0)
        XCTAssertEqual(timing.typed(scene: 0, local: StoryTiming.typeDelay + 1), 24)
    }

    func testFrameIndexFollowsHolds() {
        let scene = PixelScene(name: "x", fps: 10, frames: [PixelFrame(hold: 1, cells: [0]), PixelFrame(hold: 3, cells: [0])])
        XCTAssertEqual(StoryTiming.frameIndex(scene, local: 0), 0)
        XCTAssertEqual(StoryTiming.frameIndex(scene, local: 0.15), 1)
        XCTAssertEqual(StoryTiming.frameIndex(scene, local: 0.39), 1)
        XCTAssertEqual(StoryTiming.frameIndex(scene, local: 0.41), 0, "loops")
    }

    func testFontWrapAndGlyphs() {
        XCTAssertEqual(PixelFont.wrap("the quick brown fox", maxChars: 9), ["the quick", "brown fox"])
        XCTAssertEqual(PixelFont.wrap("abcdefghij", maxChars: 4), ["abcd", "efgh", "ij"])
        XCTAssertEqual(PixelFont.wrap("one\ntwo", maxChars: 20), ["one", "two"])
        XCTAssertEqual(PixelFont.wrap("", maxChars: 5), [""])
        XCTAssertEqual(PixelFont.rows(for: "é"), PixelFont.rows(for: "e"), "accents fall back to the plain letter")
        XCTAssertEqual(PixelFont.rows(for: "\u{1F600}"), PixelFont.rows(for: "?"))
        XCTAssertEqual(PixelFont.rows(for: "\u{2019}"), PixelFont.rows(for: "'"))
        for code in 32...126 {
            XCTAssertNotNil(PixelFont.glyphs[UInt32(code)], "every plain keyboard letter has a glyph (\(code))")
        }
        XCTAssertEqual(PixelFont.size(lines: ["ab", "abc"]).width, 17)
        XCTAssertEqual(PixelFont.typedLength(["ab", "cd"]), 5)
    }

    func testRendererLayoutAndPixels() {
        let s = makeStory()
        let r = StoryRenderer(story: s, maxSide: 320)
        XCTAssertEqual(r.layout.artScale, 20)
        XCTAssertEqual(r.layout.artWidth, 320)
        XCTAssertEqual(r.layout.artHeight, 240)
        XCTAssertGreaterThan(r.layout.barHeight, 0, "captions get a bar")
        XCTAssertEqual(r.layout.height, 240 + r.layout.barHeight)
        let even = StoryRenderer(story: s, maxSide: 333, evenSize: true).layout
        XCTAssertEqual(even.width % 2, 0)
        XCTAssertEqual(even.height % 2, 0)

        // The art's first cell (red, index 8) covers a 20 × 20 square.
        let img = r.image(scene: 0, local: 0)
        XCTAssertEqual(img.width, r.layout.width)
        let red = Pixel32(s.palette[8])
        XCTAssertEqual(img[0, 0], red)
        XCTAssertEqual(img[19, 19], red)
        XCTAssertEqual(img[20, 0], Pixel32(s.paper))
        // Nothing typed yet: the bar is plain. Later, letters show up in it.
        func barInk(_ i: RGBAImage) -> Int {
            var n = 0
            for y in (r.layout.artHeight + r.layout.textScale)..<i.height { for x in 0..<i.width where i[x, y] == StoryRenderer.barText { n += 1 } }
            return n
        }
        XCTAssertEqual(barInk(img), 0)
        let later = r.image(scene: 0, local: 2)
        XCTAssertGreaterThan(barInk(later), 0)
        XCTAssertGreaterThan(barInk(r.image(scene: 0, local: 30)), barInk(later), "more letters as time goes on")

        // No captions anywhere: no bar.
        var plain = s
        for i in plain.scenes.indices { plain.scenes[i].caption = " " }
        XCTAssertEqual(StoryRenderer(story: plain, maxSide: 320).layout.barHeight, 0)
    }

    func testBubbleShapeHasTailTowardSpeaker() {
        let s = makeStory()
        let r = StoryRenderer(story: s, maxSide: 320)
        let speech = SpeechBubble(text: "Hello there", x: 0.5, y: 0.2, tailX: 0.5, tailY: 0.9)
        let shape = r.bubbleShape(speech, text: speech.text)
        let box = shape.box
        let below = shape.cells.filter { $0.y >= box.y + box.h }
        XCTAssertFalse(below.isEmpty, "the tail hangs below the box toward the speaker")
        XCTAssertTrue(shape.cells.contains(shape.textOrigin))
        let sign = r.bubbleShape(SpeechBubble(text: "Hello there", x: 0.5, y: 0.2, tailX: 0.5, tailY: 0.9, style: .sign), text: "Hello there")
        XCTAssertTrue(sign.cells.allSatisfy { $0.y < sign.box.y + sign.box.h }, "signs have no tail")
        let shout = r.bubbleShape(SpeechBubble(text: "Hello there", style: .shout), text: "Hello there")
        XCTAssertTrue(shout.cells.contains { $0.y == shout.box.y - 1 }, "shouts have spikes")
        // Bubbles stay inside the picture even at the edge.
        let edge = r.bubbleShape(SpeechBubble(text: "Edge", x: 1, y: 1, tailX: 0, tailY: 0), text: "Edge")
        let gw = r.layout.artWidth / r.layout.textScale, gh = r.layout.artHeight / r.layout.textScale
        XCTAssertTrue(edge.cells.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x < gw && $0.y < gh })
        // The drawn bubble has white inside and dark outline.
        let img = r.image(scene: 0, local: 30)
        let b = r.bubbleShape(s.scenes[0].bubbles[0], text: "Ribbit!")
        let t = r.layout.textScale
        XCTAssertEqual(img[(b.box.x + 1) * t + t / 2, (b.box.y + 1) * t + t / 2], StoryRenderer.bubbleFill)
        XCTAssertEqual(img[(b.box.x + 1) * t, b.box.y * t], StoryRenderer.ink)
    }

    func testTransitions() {
        let a = RGBAImage(width: 10, height: 10, fill: .black)
        let b = RGBAImage(width: 10, height: 10, fill: .white)
        for kind in PixelTransition.allCases {
            XCTAssertEqual(StoryRenderer.transition(kind, from: a, to: b, progress: 1), b, "\(kind) ends on the new scene")
        }
        XCTAssertEqual(StoryRenderer.transition(.fade, from: a, to: b, progress: 0), a)
        XCTAssertEqual(StoryRenderer.transition(.wipe, from: a, to: b, progress: 0), a)
        let half = StoryRenderer.transition(.wipe, from: a, to: b, progress: 0.5)
        XCTAssertEqual(half[2, 5], .white)
        XCTAssertEqual(half[8, 5], .black)
        let iris = StoryRenderer.transition(.iris, from: a, to: b, progress: 0.3)
        XCTAssertEqual(iris[5, 5], .white, "the circle opens from the middle")
        XCTAssertEqual(iris[0, 0], .black)
        // A story whose second scene fades in starts that scene mid-fade.
        let s = makeStory()
        let r = StoryRenderer(story: s, maxSide: 160)
        let start = r.image(scene: 1, local: 0)
        let settled = r.image(scene: 1, local: 1)
        XCTAssertNotEqual(start, settled)
    }

    func testExportFramesCoverTheWholeStory() {
        let s = makeStory()
        let r = StoryRenderer(story: s, maxSide: 96)
        let frames = r.frames(perSecond: 10)
        XCTAssertFalse(frames.isEmpty)
        let total = frames.reduce(0) { $0 + $1.centiseconds }
        XCTAssertEqual(Double(total) / 100, r.timing.total, accuracy: 0.15)
        for (x, y) in zip(frames, frames.dropFirst()) { XCTAssertNotEqual(x.image, y.image, "repeats are merged") }
    }
}

final class ExportTests: XCTestCase {
    /// A small GIF reader for checking the encoder: returns each frame's colors (as indexes resolved to RGB).
    func decodeGIF(_ data: Data) throws -> (width: Int, height: Int, frames: [(pixels: [Pixel32], delay: Int)]) {
        let b = [UInt8](data)
        XCTAssertEqual(Array(b[0..<6]), Array("GIF89a".utf8))
        let w = Int(b[6]) | Int(b[7]) << 8, h = Int(b[8]) | Int(b[9]) << 8
        var i = 13
        var frames: [([Pixel32], Int)] = []
        var delay = 0, transparent: Int?
        func subBlocks() -> [UInt8] {
            var out: [UInt8] = []
            while b[i] != 0 { let n = Int(b[i]); out += b[(i + 1)...(i + n)]; i += n + 1 }
            i += 1
            return out
        }
        while i < b.count {
            switch b[i] {
            case 0x21:
                let label = b[i + 1]
                if label == 0xF9 {
                    let flags = b[i + 3]
                    delay = Int(b[i + 4]) | Int(b[i + 5]) << 8
                    transparent = flags & 1 == 1 ? Int(b[i + 6]) : nil
                }
                i += 2
                _ = subBlocks()
            case 0x2C:
                let packed = b[i + 9]
                i += 10
                var table: [Pixel32] = []
                if packed & 0x80 != 0 {
                    let n = 1 << (Int(packed & 7) + 1)
                    for k in 0..<n { table.append(Pixel32(b[i + k * 3], b[i + k * 3 + 1], b[i + k * 3 + 2])) }
                    i += n * 3
                }
                let minCode = Int(b[i]); i += 1
                let idx = lzwDecode(subBlocks(), minCode: minCode, count: w * h)
                frames.append((idx.map { (v: UInt8) -> Pixel32 in transparent == Int(v) ? Pixel32.clear : table[Int(v)] }, delay))
            case 0x3B:
                return (w, h, frames)
            default:
                XCTFail("Unknown GIF block \(b[i]) at \(i)")
                return (w, h, frames)
            }
        }
        XCTFail("No GIF trailer")
        return (w, h, frames)
    }

    func lzwDecode(_ data: [UInt8], minCode: Int, count: Int) -> [UInt8] {
        let clear = 1 << minCode, end = clear + 1
        var size = minCode + 1
        var dict: [[UInt8]] = []
        func reset() { dict = (0..<(end + 1)).map { $0 < clear ? [UInt8($0)] : [] }; size = minCode + 1 }
        reset()
        var out: [UInt8] = []
        var bitPos = 0
        var prev: [UInt8]?
        while out.count < count {
            var code = 0
            for k in 0..<size {
                let byte = bitPos / 8
                guard byte < data.count else { return out }
                if data[byte] & (1 << (bitPos % 8)) != 0 { code |= 1 << k }
                bitPos += 1
            }
            if code == clear { reset(); prev = nil; continue }
            if code == end { break }
            var entry: [UInt8]
            if code < dict.count { entry = dict[code] } else if let p = prev { entry = p + [p[0]] } else { return out }
            out += entry
            if let p = prev, dict.count < 4096 { dict.append(p + [entry[0]]) }
            if dict.count >= (1 << size) && size < 12 { size += 1 }
            prev = entry
        }
        return out
    }

    func testGIFRoundTripKeepsExactColors() throws {
        var a = RGBAImage(width: 7, height: 5, fill: Pixel32(29, 43, 83))
        a[3, 2] = Pixel32(255, 0, 77)
        a[6, 4] = .clear
        var b = RGBAImage(width: 7, height: 5, fill: .white)
        b[0, 0] = .black
        var enc = GIFEncoder(width: 7, height: 5)
        enc.add(a, centiseconds: 12)
        enc.add(b, centiseconds: 50)
        let gif = try decodeGIF(enc.finish())
        XCTAssertEqual(gif.width, 7)
        XCTAssertEqual(gif.frames.count, 2)
        XCTAssertEqual(gif.frames[0].delay, 12)
        XCTAssertEqual(gif.frames[1].delay, 50)
        for y in 0..<5 { for x in 0..<7 {
            XCTAssertEqual(gif.frames[0].pixels[y * 7 + x], a[x, y].a == 0 ? .clear : a[x, y])
            XCTAssertEqual(gif.frames[1].pixels[y * 7 + x], b[x, y])
        } }
    }

    func testGIFWithLongRunsAndManyColors() throws {
        // Big enough to fill the LZW table and reset it, and more than 256 colors.
        var img = RGBAImage(width: 300, height: 120)
        for y in 0..<120 { for x in 0..<300 { img[x, y] = Pixel32(UInt8(x % 256), UInt8((x * 7 + y * 3) % 256), UInt8(y * 2)) } }
        var enc = GIFEncoder(width: 300, height: 120)
        enc.add(img, centiseconds: 4)
        let gif = try decodeGIF(enc.finish())
        XCTAssertEqual(gif.frames[0].pixels.count, 300 * 120)
        // Colors land within one cube step.
        for k in Swift.stride(from: 0, to: 300 * 120, by: 997) {
            let p = gif.frames[0].pixels[k], q = img[k % 300, k / 300]
            XCTAssertLessThanOrEqual(abs(Int(p.r) - Int(q.r)), 26)
            XCTAssertLessThanOrEqual(abs(Int(p.g) - Int(q.g)), 22)
            XCTAssertLessThanOrEqual(abs(Int(p.b) - Int(q.b)), 26)
        }
        // A long plain picture compresses well.
        var flat = GIFEncoder(width: 256, height: 256)
        flat.add(RGBAImage(width: 256, height: 256, fill: .white), centiseconds: 10)
        XCTAssertLessThan(flat.finish().count, 2000)
    }

    func testWholeStoryAsGIF() throws {
        let s = makeStory()
        let r = StoryRenderer(story: s, maxSide: 64)
        var enc = GIFEncoder(width: r.layout.width, height: r.layout.height)
        let frames = r.frames(perSecond: 8)
        for f in frames { enc.add(f.image, centiseconds: f.centiseconds) }
        let gif = try decodeGIF(enc.finish())
        XCTAssertEqual(gif.frames.count, frames.count)
        XCTAssertEqual(gif.frames.last?.pixels, (0..<(r.layout.width * r.layout.height)).map { frames.last!.image[$0 % r.layout.width, $0 / r.layout.width] })
    }

    func testSpriteSheet() throws {
        let s = makeStory()
        let (img, layout) = SpriteSheet.render(s, scene: 0, scale: 2)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(img.width, 64)
        XCTAssertEqual(img.height, 24)
        XCTAssertEqual(img[0, 0], Pixel32(s.palette[8]))
        XCTAssertEqual(img[33, 0], .clear, "frame 2 is flipped, and empty cells stay see-through")
        XCTAssertEqual(img[63, 0], Pixel32(s.palette[8]))
        XCTAssertEqual(SpriteSheet.layout(frames: 5, cellWidth: 8, cellHeight: 8).columns, 3)
        XCTAssertEqual(SpriteSheet.layout(frames: 5, cellWidth: 8, cellHeight: 8).rows, 2)
        XCTAssertEqual(SpriteSheet.layout(frames: 5, cellWidth: 8, cellHeight: 8, columns: 5).rows, 1)
        let json = SpriteSheet.json(s, scene: 0, layout: layout, imageName: "frog \"1\".png")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["frames"] as? [Any])?.count, 2)
        XCTAssertEqual(parsed["image"] as? String, "frog \"1\".png")
        let opaque = SpriteSheet.render(s, scene: 0, scale: 1, transparent: false).image
        XCTAssertEqual(opaque[1, 0], Pixel32(s.paper))
    }
}

final class PixelSyncTests: XCTestCase {
    func testFlattenAndBuildPixelStory() throws {
        var p = GaleProject(name: "Frog", pixel: makeStory())
        p.created = Date(timeIntervalSince1970: 1_700_000_000)
        let objects = SyncObjects.flatten(p)
        XCTAssertEqual(objects.values.filter { $0["$type"] == JSONValue.string("pxscene") }.count, 2)
        XCTAssertEqual(objects.values.filter { $0["$type"] == JSONValue.string("pxframe") }.count, 3)
        XCTAssertNotNil(objects[p.id]?["pixel"]?.object)
        let back = try XCTUnwrap(SyncObjects.build(objects, projectID: p.id))
        XCTAssertEqual(back.pixel, p.pixel)
    }

    func testDrawingOnOneFrameSendsOneOp() throws {
        let old = GaleProject(name: "Frog", pixel: makeStory())
        var new = old
        new.pixel!.scenes[1].frames[0].cells[5] = 3
        var clock = HybridClock(actor: "ipad-1")
        let ops = SyncObjects.diff(SyncObjects.flatten(old), SyncObjects.flatten(new), clock: &clock)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.o, new.pixel!.scenes[1].frames[0].id)
        XCTAssertEqual(ops.first?.k, "runs")
        var replica = SyncReplica(project: old, stamp: HybridClock.format(ms: 1, counter: 0, actor: "x"))
        replica.apply(ops)
        XCTAssertEqual(try XCTUnwrap(replica.project).pixel, new.pixel)
    }

    func testDeletingASceneDropsItsFrames() throws {
        let old = GaleProject(name: "Frog", pixel: makeStory())
        var new = old
        new.pixel!.scenes.remove(at: 0)
        var objects = SyncObjects.flatten(old)
        objects[old.pixel!.scenes[0].id]?["$del"] = JSONValue.bool(true)
        let built = try XCTUnwrap(SyncObjects.build(objects, projectID: old.id))
        XCTAssertEqual(built.pixel?.scenes.map(\.id), new.pixel?.scenes.map(\.id))
    }

    func testDrawingProjectsStayDrawings() throws {
        let p = GaleProject(name: "Plain")
        let objects = SyncObjects.flatten(p)
        XCTAssertNil(objects[p.id]?["pixel"])
        XCTAssertNil(try XCTUnwrap(SyncObjects.build(objects, projectID: p.id)).pixel)
    }
}
