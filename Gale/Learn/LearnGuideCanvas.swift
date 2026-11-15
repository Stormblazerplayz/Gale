import SwiftUI
import GaleLearn

/// Maps lesson space (1 unit tall, `aspect` wide, y down) into a view, centred and fitted.
struct LearnSpace {
    let size: CGSize
    let aspect: Double

    var scale: CGFloat { max(1, min(size.width / CGFloat(max(0.1, aspect)), size.height)) }
    var origin: CGPoint {
        CGPoint(x: (size.width - CGFloat(aspect) * scale) / 2, y: (size.height - scale) / 2)
    }
    var rect: CGRect { CGRect(origin: origin, size: CGSize(width: CGFloat(aspect) * scale, height: scale)) }

    func point(_ p: LearnPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale)
    }

    func unit(_ p: CGPoint) -> LearnPoint {
        LearnPoint(Double((p.x - origin.x) / scale), Double((p.y - origin.y) / scale))
    }
}

/// Fixed colours: the drawing paper is always white, so lines look the same in light and dark mode.
enum LearnPalette {
    static let paper = Color(red: 0.995, green: 0.993, blue: 1.0)
    static let ink = Color(red: 0.13, green: 0.11, blue: 0.2)
    static let target = Color(red: 0.78, green: 0.79, blue: 0.84)
    static let helper = Color(red: 0.55, green: 0.57, blue: 0.64)
}

/// How a guide is drawn.
enum LearnGuideStyle {
    /// Watching: dark lines, purple highlights, dashed helpers.
    case demo
    /// The gray lines you trace over.
    case target
    /// A faint hint under a frame you're drawing.
    case ghost
    /// Small pictures in the frame strip.
    case thumbnail
    /// The guide's background (ground lines, props) under a page you draw on.
    case scenery
}

enum LearnDraw {
    static func path(_ pts: [LearnPoint], closed: Bool, space: LearnSpace) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: space.point(first))
        for q in pts.dropFirst() { p.addLine(to: space.point(q)) }
        if closed && pts.count > 2 { p.closeSubpath() }
        return p
    }

    static func guidePaths(_ paths: [LearnPath], in ctx: inout GraphicsContext, space: LearnSpace, style: LearnGuideStyle) {
        let s = space.scale
        for item in paths where !item.points.isEmpty {
            let color: Color
            var width = CGFloat(item.width) * s
            var dash: [CGFloat] = []
            switch (style, item.role) {
            case (.demo, .ink):
                color = LearnPalette.ink
                width = max(1.5, width)
            case (.demo, .accent):
                color = Theme.accent
                width = max(1.5, width * 1.1)
            case (.demo, .guide):
                color = LearnPalette.helper.opacity(0.75)
                width = max(1, width)
                dash = [max(4, s * 0.012), max(3, s * 0.01)]
            case (.target, .ink):
                color = LearnPalette.target
                width = max(6, CGFloat(max(item.width, 0.022)) * s)
            case (.target, .accent):
                color = Theme.accent.opacity(0.35)
                width = max(4, CGFloat(max(item.width, 0.016)) * s)
            case (.target, .guide):
                color = LearnPalette.helper.opacity(0.55)
                width = max(1, width)
                dash = [max(4, s * 0.012), max(3, s * 0.01)]
            case (.ghost, .ink):
                color = Theme.accent.opacity(0.16)
                width = max(4, CGFloat(max(item.width, 0.02)) * s)
            case (.ghost, .accent):
                color = Theme.accent.opacity(0.12)
                width = max(3, width)
            case (.ghost, .guide):
                color = LearnPalette.helper.opacity(0.35)
                width = max(1, width)
                dash = [max(4, s * 0.012), max(3, s * 0.01)]
            case (.thumbnail, .ink):
                color = LearnPalette.ink.opacity(0.85)
                width = max(0.8, width)
            case (.thumbnail, .accent):
                color = Theme.accent
                width = max(0.8, width)
            case (.thumbnail, .guide):
                color = LearnPalette.helper.opacity(0.5)
                width = max(0.5, width * 0.7)
            case (.scenery, .ink):
                color = LearnPalette.helper.opacity(0.6)
                width = max(1, width)
            case (.scenery, .accent):
                color = Theme.accent.opacity(0.3)
                width = max(1, width)
            case (.scenery, .guide):
                color = LearnPalette.helper.opacity(0.45)
                width = max(1, width)
                dash = [max(4, s * 0.012), max(3, s * 0.01)]
            }
            if item.points.count == 1 {
                let c = space.point(item.points[0])
                let r = max(1, width / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            } else {
                ctx.stroke(path(item.points, closed: item.closed, space: space), with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            }
        }
    }

    static func notes(_ notes: [LearnNote], in ctx: inout GraphicsContext, space: LearnSpace) {
        guard !notes.isEmpty else { return }
        let fontSize = min(22, max(11, space.scale * 0.04))
        let bounds = space.rect
        for note in notes {
            let text = Text(note.text).font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundColor(LearnPalette.ink)
            let resolved = ctx.resolve(text)
            let measured = resolved.measure(in: CGSize(width: bounds.width * 0.6, height: bounds.height))
            var c = space.point(LearnPoint(note.x, note.y))
            let halfW = measured.width / 2 + 6, halfH = measured.height / 2 + 3
            c.x = min(max(c.x, bounds.minX + halfW), bounds.maxX - halfW)
            c.y = min(max(c.y, bounds.minY + halfH), bounds.maxY - halfH)
            let box = CGRect(x: c.x - halfW, y: c.y - halfH, width: 2 * halfW, height: 2 * halfH)
            ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(.white.opacity(0.85)))
            ctx.draw(resolved, in: CGRect(x: c.x - measured.width / 2, y: c.y - measured.height / 2,
                                          width: measured.width, height: measured.height))
        }
    }
}

/// One frame of a guide (its background is drawn under every frame).
struct LearnGuideCanvas: View {
    let guide: LearnGuide
    var frame: Int = 0
    var style: LearnGuideStyle = .demo
    var showNotes = true

    var body: some View {
        Canvas { ctx, size in
            let space = LearnSpace(size: size, aspect: guide.aspect)
            let backgroundStyle: LearnGuideStyle = (style == .target || style == .ghost) ? .scenery : style
            LearnDraw.guidePaths(guide.background, in: &ctx, space: space, style: backgroundStyle)
            guard guide.frames.indices.contains(frame) else { return }
            let f = guide.frames[frame]
            LearnDraw.guidePaths(f.paths, in: &ctx, space: space, style: style)
            if showNotes { LearnDraw.notes(f.notes, in: &ctx, space: space) }
        }
        .accessibilityHidden(true)
    }
}

/// A sheet of white paper the size of the lesson page.
struct LearnPaper<Content: View>: View {
    let aspect: Double
    let content: Content

    init(aspect: Double, @ViewBuilder content: () -> Content) {
        self.aspect = aspect
        self.content = content()
    }

    var body: some View {
        ZStack {
            LearnPalette.paper
            content
        }
        .aspectRatio(CGFloat(aspect), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// Plays an animated guide, with play/pause, speed and frame-by-frame stepping.
struct LearnGuidePlayer: View {
    let guide: LearnGuide
    var style: LearnGuideStyle = .demo

    @State private var playing = true
    @State private var speed = 1.0
    @State private var startDate = Date()
    @State private var heldTime = 0.0

    private var isAnimated: Bool { guide.frames.count > 1 }
    /// A guide that doesn't loop rests on its last frame for a moment before it starts again.
    private var cycle: Double { guide.loop ? guide.duration : guide.duration + 1.2 }

    var body: some View {
        VStack(spacing: 8) {
            LearnPaper(aspect: guide.aspect) {
                if isAnimated {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playing)) { context in
                        LearnGuideCanvas(guide: guide, frame: frameIndex(at: context.date), style: style)
                    }
                } else {
                    LearnGuideCanvas(guide: guide, frame: 0, style: style)
                }
            }
            if isAnimated { controls }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                if playing {
                    heldTime = playhead(at: Date())
                } else {
                    startDate = Date()
                }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(playing ? "Pause" : "Play")

            if !playing {
                Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .accessibilityLabel("Previous frame")
                Text("Frame \(frameIndex(at: Date()) + 1) of \(guide.frames.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .accessibilityLabel("Next frame")
            }
            Spacer(minLength: 0)
            Menu {
                ForEach([0.25, 0.5, 1.0], id: \.self) { s in
                    Button {
                        heldTime = playhead(at: Date())
                        startDate = Date()
                        speed = s
                    } label: {
                        if s == speed { Label(speedName(s), systemImage: "checkmark") } else { Text(speedName(s)) }
                    }
                }
            } label: {
                Label(speedName(speed), systemImage: "tortoise")
                    .font(.footnote.weight(.medium))
            }
        }
        .buttonStyle(.borderless)
        .tint(Theme.accent)
        .padding(.horizontal, 4)
    }

    private func speedName(_ s: Double) -> String {
        s == 1 ? "Normal speed" : (s == 0.5 ? "Half speed" : "Slow motion")
    }

    /// Guide time in seconds (already sped up or slowed down).
    private func playhead(at date: Date) -> Double {
        guard playing else { return heldTime }
        return heldTime + max(0, date.timeIntervalSince(startDate)) * speed
    }

    private func frameIndex(at date: Date) -> Int {
        let c = max(0.001, cycle)
        let t = playhead(at: date).truncatingRemainder(dividingBy: c)
        return guide.frameIndex(atTime: min(t, max(0, guide.duration - 0.0001)), speed: 1)
    }

    private func startTime(ofFrame i: Int) -> Double {
        let ticks = guide.frames.prefix(max(0, i)).reduce(0) { $0 + max(1, $1.hold) }
        return Double(ticks) / Double(max(1, guide.fps))
    }

    private func step(_ delta: Int) {
        let n = guide.frames.count
        guard n > 0 else { return }
        let i = ((frameIndex(at: Date()) + delta) % n + n) % n
        heldTime = startTime(ofFrame: i) + 0.0005
    }
}
