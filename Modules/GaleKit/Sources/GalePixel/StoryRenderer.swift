import Foundation
import GaleFormat

/// Draws a pixel story at any moment: the scene's art made big, speech bubbles, the caption bar
/// with typewriter text, and fades, wipes or circle reveals between scenes.
/// The same picture is used for playing in the app, GIF, video and the storyboard.
public struct StoryRenderer: Sendable {
    public let story: PixelStory
    public let timing: StoryTiming
    public let layout: Layout
    private let colors: [Pixel32]

    /// Where everything goes in the output picture. Text and bubbles line up on a grid of `textScale` pixels.
    public struct Layout: Hashable, Sendable {
        /// Output pixels per art pixel.
        public let artScale: Int
        /// Output pixels per font dot.
        public let textScale: Int
        public let artWidth: Int
        public let artHeight: Int
        /// Height of the caption bar under the art (0 when no scene has a caption).
        public let barHeight: Int
        public let width: Int
        public let height: Int
        /// Most letters on one caption line.
        public let captionChars: Int

        public init(story: PixelStory, maxSide: Int, evenSize: Bool = false) {
            let side = max(story.width, story.height)
            artScale = max(1, maxSide / side)
            artWidth = story.width * artScale
            artHeight = story.height * artScale
            textScale = max(1, artWidth / 170)
            let pad = 3 * textScale
            let chars = max(4, (artWidth - 2 * pad) / (PixelFont.advance * textScale))
            captionChars = chars
            let lines = story.scenes.map { scene -> Int in
                let text = scene.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? 0 : min(4, PixelFont.wrap(text, maxChars: chars).count)
            }.max() ?? 0
            var bar = lines == 0 ? 0 : 2 * pad + ((lines - 1) * PixelFont.lineHeight + PixelFont.capHeight + 2) * textScale
            var h = artHeight + bar
            if evenSize && h % 2 == 1 { bar += 1; h += 1 }
            barHeight = bar
            width = evenSize && artWidth % 2 == 1 ? artWidth + 1 : artWidth
            height = h
        }
    }

    /// `maxSide`: biggest the art may be, in output pixels. `evenSize` makes both sides even (videos need it).
    public init(story: PixelStory, maxSide: Int = 720, evenSize: Bool = false) {
        self.story = story
        timing = StoryTiming(story)
        layout = Layout(story: story, maxSide: maxSide, evenSize: evenSize)
        colors = PixelRender.colors(story)
    }

    public static let barColor = Pixel32(26, 28, 44)
    public static let barText = Pixel32(255, 241, 232)
    public static let barEdge = Pixel32(124, 58, 237)
    public static let ink = Pixel32(20, 20, 28)
    public static let bubbleFill = Pixel32.white
    public static let signFill = Pixel32(255, 236, 39)

    // MARK: Whole story

    /// The story `time` seconds in. With `loop`, time wraps around to the start.
    public func image(at time: Double, loop: Bool = true) -> RGBAImage {
        let (s, local) = timing.locate(time, loop: loop)
        return image(scene: s, local: local)
    }

    /// One scene `local` seconds after it starts, including the transition into it.
    public func image(scene s: Int, local: Double) -> RGBAImage {
        guard story.scenes.indices.contains(s) else { return RGBAImage(width: layout.width, height: layout.height, fill: .black) }
        let now = sceneImage(s, local: local)
        let scene = story.scenes[s]
        let p = local / StoryTiming.transitionSeconds
        guard scene.transition != .cut, p < 1 else { return now }
        let before: RGBAImage
        if s > 0, timing.spans.indices.contains(s - 1) {
            before = sceneImage(s - 1, local: timing.spans[s - 1].duration)
        } else {
            before = RGBAImage(width: layout.width, height: layout.height, fill: .black)
        }
        return StoryRenderer.transition(scene.transition, from: before, to: now, progress: p)
    }

    /// Mixes two same-size pictures for a transition at progress 0...1.
    public static func transition(_ kind: PixelTransition, from a: RGBAImage, to b: RGBAImage, progress: Double) -> RGBAImage {
        let p = min(1, max(0, progress))
        switch kind {
        case .cut:
            return b
        case .fade:
            // Steps of 1/8 keep the colors few, like old consoles fading.
            let stepped = (p * 8).rounded(.down) / 8
            return a.crossfade(to: b, stepped)
        case .wipe:
            var out = a
            let edge = Int(Double(b.width) * p)
            for y in 0..<b.height {
                let start = y * b.width * 4
                let count = min(edge, b.width) * 4
                if count > 0 { out.bytes.replaceSubrange(start..<(start + count), with: b.bytes[start..<(start + count)]) }
            }
            return out
        case .iris:
            var out = a
            let cx = Double(b.width) / 2, cy = Double(b.height) / 2
            let r = (cx * cx + cy * cy).squareRoot() * p
            let r2 = r * r
            // Blocky circle: test in 4-pixel cells so the edge looks like pixel art.
            let cell = max(1, min(b.width, b.height) / 48)
            for y in Swift.stride(from: 0, to: b.height, by: cell) {
                for x in Swift.stride(from: 0, to: b.width, by: cell) {
                    let dx = Double(x) + Double(cell) / 2 - cx, dy = Double(y) + Double(cell) / 2 - cy
                    guard dx * dx + dy * dy <= r2 else { continue }
                    for yy in y..<min(b.height, y + cell) {
                        let start = (yy * b.width + x) * 4
                        let count = (min(b.width, x + cell) - x) * 4
                        out.bytes.replaceSubrange(start..<(start + count), with: b.bytes[start..<(start + count)])
                    }
                }
            }
            return out
        }
    }

    // MARK: One scene

    /// The art of one frame of a scene, made big, with nothing on top.
    public func art(scene s: Int, frame f: Int) -> RGBAImage {
        let scene = story.scenes[s]
        let fi = min(max(0, f), scene.frames.count - 1)
        let grid = PixelRender.frame(scene.frames[fi].cells, width: story.width, height: story.height, colors: colors,
                                     background: PixelRender.background(story, scene: scene))
        return grid.scaled(by: layout.artScale)
    }

    func sceneImage(_ s: Int, local: Double) -> RGBAImage {
        let scene = story.scenes[s]
        var img = RGBAImage(width: layout.width, height: layout.height, fill: StoryRenderer.barColor)
        img.draw(art(scene: s, frame: StoryTiming.frameIndex(scene, local: local)), x: 0, y: 0)

        let typed = timing.typed(scene: s, local: local)
        let caption = scene.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionShown = min(typed, caption.count)
        // Bubbles type after the caption, one after another. A bubble pops in when its turn comes.
        var left = typed - caption.count
        for bubble in scene.bubbles {
            let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard left > 0 else { break }
            drawBubble(bubble, text: text, into: &img, visible: left)
            left -= text.count
        }
        if layout.barHeight > 0 {
            drawCaption(caption, into: &img, visible: captionShown, done: typed >= StoryTiming.letters(scene), local: local)
        }
        return img
    }

    private func drawCaption(_ text: String, into img: inout RGBAImage, visible: Int, done: Bool, local: Double) {
        let t = layout.textScale
        let top = layout.artHeight
        img.fill(x: 0, y: top, w: layout.width, h: t, StoryRenderer.barEdge)
        guard !text.isEmpty else { return }
        let lines = Array(PixelFont.wrap(text, maxChars: layout.captionChars).prefix(4))
        let pad = 3 * t
        // Lines are typed with the wrapped text, so the words never jump to the next line mid-word.
        let shownLetters = visible >= text.count ? PixelFont.typedLength(lines) : visible
        PixelFont.drawLines(lines, into: &img, x: pad, y: top + pad + t, width: layout.artWidth - 2 * pad, scale: t,
                            color: StoryRenderer.barText, centered: true, visible: shownLetters)
        // Blinking "more" arrow once the words are all there.
        if done && Int(local * 2.5) % 2 == 0 {
            let ax = layout.artWidth - pad - 5 * t, ay = layout.height - pad - 3 * t
            img.fill(x: ax, y: ay, w: 5 * t, h: t, StoryRenderer.barText)
            img.fill(x: ax + t, y: ay + t, w: 3 * t, h: t, StoryRenderer.barText)
            img.fill(x: ax + 2 * t, y: ay + 2 * t, w: t, h: t, StoryRenderer.barText)
        }
    }

    // MARK: Speech bubbles

    /// The cells (in text-scale units) a bubble covers, and where its text goes. Exposed for tests and the editor.
    public struct BubbleShape: Hashable, Sendable {
        /// Cells of the whole shape (box, tail, dots) in units of `textScale` pixels from the art's top left.
        public var cells: Set<GridPoint>
        public var box: (x: Int, y: Int, w: Int, h: Int)
        public var lines: [String]
        public var textOrigin: GridPoint

        public static func == (a: BubbleShape, b: BubbleShape) -> Bool {
            a.cells == b.cells && a.box == b.box && a.lines == b.lines && a.textOrigin == b.textOrigin
        }

        public func hash(into h: inout Hasher) {
            h.combine(box.x); h.combine(box.y); h.combine(box.w); h.combine(box.h); h.combine(lines); h.combine(textOrigin)
        }
    }

    public func bubbleShape(_ bubble: SpeechBubble, text: String) -> BubbleShape {
        let t = layout.textScale
        let gw = layout.artWidth / t, gh = layout.artHeight / t
        let maxChars = max(6, min(18, (gw * 7 / 10 - 6) / PixelFont.advance))
        let lines = PixelFont.wrap(text, maxChars: maxChars)
        let size = PixelFont.size(lines: lines)
        let bw = min(gw, size.width + 6), bh = min(gh, size.height + 6)
        var bx = Int((bubble.x * Double(gw)).rounded()) - bw / 2
        var by = Int((bubble.y * Double(gh)).rounded()) - bh / 2
        bx = min(max(1, bx), max(1, gw - bw - 1))
        by = min(max(1, by), max(1, gh - bh - 1))

        var cells = Set<GridPoint>()
        // Box with its corners cut, so it looks round in pixels.
        for y in by..<(by + bh) {
            for x in bx..<(bx + bw) {
                let corner = (x == bx || x == bx + bw - 1) && (y == by || y == by + bh - 1)
                if !corner { cells.insert(GridPoint(x, y)) }
            }
        }
        if bubble.style == .shout {
            // Spikes all around.
            for x in Swift.stride(from: bx + 2, to: bx + bw - 2, by: 4) {
                cells.insert(GridPoint(x, by - 1))
                cells.insert(GridPoint(x + 1, by + bh))
            }
            for y in Swift.stride(from: by + 2, to: by + bh - 2, by: 4) {
                cells.insert(GridPoint(bx - 1, y))
                cells.insert(GridPoint(bx + bw, y + 1))
            }
        }

        let tip = (x: bubble.tailX * Double(gw), y: bubble.tailY * Double(gh))
        let insideBox = tip.x >= Double(bx) && tip.x <= Double(bx + bw) && tip.y >= Double(by) && tip.y <= Double(by + bh)
        if bubble.style != .sign && !insideBox {
            // Nearest point on the box to the tip: the tail starts there.
            let nx = min(max(tip.x, Double(bx) + 2.5), Double(bx + bw) - 2.5)
            let ny = min(max(tip.y, Double(by) + 2.5), Double(by + bh) - 2.5)
            var base = (x: nx, y: ny)
            var along = (x: 1.0, y: 0.0)
            if tip.y >= Double(by + bh) { base.y = Double(by + bh) - 0.5 }
            else if tip.y <= Double(by) { base.y = Double(by) + 0.5 }
            else if tip.x >= Double(bx + bw) { base.x = Double(bx + bw) - 0.5; along = (0, 1) }
            else { base.x = Double(bx) + 0.5; along = (0, 1) }
            let dx = tip.x - base.x, dy = tip.y - base.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let reach = min(dist, 9)
            let end = (x: base.x + dx / max(0.001, dist) * reach, y: base.y + dy / max(0.001, dist) * reach)
            if bubble.style == .thought {
                // Two shrinking puffs toward the speaker.
                let mid = (x: base.x + (end.x - base.x) * 0.45, y: base.y + (end.y - base.y) * 0.45)
                let m = GridPoint(Int(mid.x.rounded(.down)), Int(mid.y.rounded(.down)))
                for d in [GridPoint(0, 0), GridPoint(1, 0), GridPoint(-1, 0), GridPoint(0, 1), GridPoint(0, -1)] {
                    cells.insert(GridPoint(m.x + d.x, m.y + d.y))
                }
                cells.insert(GridPoint(Int(end.x.rounded(.down)), Int(end.y.rounded(.down))))
            } else {
                let half = bubble.style == .shout ? 1.0 : 1.6
                let b1 = (x: base.x - along.x * half, y: base.y - along.y * half)
                let b2 = (x: base.x + along.x * half, y: base.y + along.y * half)
                let minX = Int(min(b1.x, b2.x, end.x).rounded(.down)) - 1, maxX = Int(max(b1.x, b2.x, end.x).rounded(.up)) + 1
                let minY = Int(min(b1.y, b2.y, end.y).rounded(.down)) - 1, maxY = Int(max(b1.y, b2.y, end.y).rounded(.up)) + 1
                func sign(_ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
                    (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
                }
                for y in minY...maxY {
                    for x in minX...maxX {
                        let p = (x: Double(x) + 0.5, y: Double(y) + 0.5)
                        let d1 = sign(p, b1, b2), d2 = sign(p, b2, end), d3 = sign(p, end, b1)
                        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
                        if !(neg && pos) { cells.insert(GridPoint(x, y)) }
                    }
                }
            }
        }
        cells = cells.filter { $0.x >= 0 && $0.y >= 0 && $0.x < gw && $0.y < gh }
        return BubbleShape(cells: cells, box: (bx, by, bw, bh), lines: lines, textOrigin: GridPoint(bx + 3, by + 3))
    }

    private func drawBubble(_ bubble: SpeechBubble, text: String, into img: inout RGBAImage, visible: Int) {
        let t = layout.textScale
        let shape = bubbleShape(bubble, text: text)
        let fill = bubble.style == .sign ? StoryRenderer.signFill : StoryRenderer.bubbleFill
        for c in shape.cells {
            let edge = !shape.cells.contains(GridPoint(c.x + 1, c.y)) || !shape.cells.contains(GridPoint(c.x - 1, c.y))
                || !shape.cells.contains(GridPoint(c.x, c.y + 1)) || !shape.cells.contains(GridPoint(c.x, c.y - 1))
            img.fill(x: c.x * t, y: c.y * t, w: t, h: t, edge ? StoryRenderer.ink : fill)
        }
        let shown = visible >= text.count ? PixelFont.typedLength(shape.lines) : visible
        PixelFont.drawLines(shape.lines, into: &img, x: shape.textOrigin.x * t, y: shape.textOrigin.y * t,
                            width: (shape.box.w - 6) * t, scale: t, color: StoryRenderer.ink, centered: true, visible: shown)
    }

    // MARK: Export helpers

    /// Pictures and how long each shows (in hundredths of a second), sampled `perSecond` times a second
    /// with repeats merged. Covers the whole story once.
    public func frames(perSecond: Double = 25, progress: ((Double) -> Void)? = nil) -> [(image: RGBAImage, centiseconds: Int)] {
        let step = 1 / max(1, perSecond)
        let count = max(1, Int((timing.total / step).rounded(.up)))
        var out: [(RGBAImage, Int)] = []
        var lastStart = 0.0
        for i in 0..<count {
            let t = Double(i) * step
            let img = image(at: t, loop: false)
            if let last = out.last, last.0 == img {
                continue
            }
            if !out.isEmpty {
                out[out.count - 1].1 = max(2, Int(((t - lastStart) * 100).rounded()))
            }
            out.append((img, 0))
            lastStart = t
            progress?(Double(i + 1) / Double(count))
        }
        if !out.isEmpty {
            out[out.count - 1].1 = max(2, Int(((timing.total - lastStart) * 100).rounded()))
        }
        return out
    }
}
