import SwiftUI
import GaleLearn

/// Watch and listen: a narrated demo that plays beat by beat. Each beat says one thing while its frames
/// play, with onion skin, a motion trail, a timing chart or slow motion laid over the top.
struct LearnWatchStepView: View {
    let step: LearnStep
    @ObservedObject var narrator: LearnNarrator
    /// Bumped by the caption bar's "say it again" button: starts again from the first beat.
    let restartToken: Int

    @State private var beat = 0
    @State private var beatStart = Date()
    @State private var playing = true
    @State private var heldSeconds = 0.0
    @State private var watchedAll = false

    private var beats: [LearnBeat] { step.beats }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LearnStepHeader(step: step, compact: true)
                if let guide = step.guide, !beats.isEmpty {
                    LearnPaper(aspect: guide.aspect) {
                        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playing)) { context in
                            let current = beats[min(beat, beats.count - 1)]
                            let t = playing ? max(0, context.date.timeIntervalSince(beatStart)) : heldSeconds
                            LearnWatchCanvas(guide: guide, beat: current,
                                             frame: LearnMotion.frame(guide, beat: current, seconds: t,
                                                                      speed: current.has(.slow) ? 0.5 : 1))
                        }
                    }
                    .frame(maxWidth: 760)
                    .overlay(alignment: .topTrailing) { badges }
                    controls
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .onAppear { play(0) }
        .onChange(of: restartToken) { _, _ in play(0) }
    }

    /// Little labels for what's being shown ("Slow motion", "Onion skin").
    private var badges: some View {
        let current = beats[min(beat, beats.count - 1)]
        return HStack(spacing: 6) {
            if current.has(.slow) { badge("Slow motion", "tortoise.fill") }
            if current.has(.onion) { badge("Onion skin", "circle.dashed") }
            if current.has(.trail) { badge("Path", "point.topleft.down.to.point.bottomright.curvepath") }
            if current.has(.chart) { badge("Timing chart", "ruler") }
        }
        .padding(8)
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(Theme.accent)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button { play(max(0, beat - 1)) } label: {
                Image(systemName: "backward.end.fill").frame(width: 36, height: 36)
            }
            .disabled(beat == 0)
            .accessibilityLabel("Previous part")

            Button { playing ? pause() : play(beat) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.14), in: Circle())
            }
            .accessibilityLabel(playing ? "Pause" : "Play")

            Button { play(min(beats.count - 1, beat + 1)) } label: {
                Image(systemName: "forward.end.fill").frame(width: 36, height: 36)
            }
            .disabled(beat >= beats.count - 1)
            .accessibilityLabel("Next part")

            HStack(spacing: 6) {
                ForEach(beats.indices, id: \.self) { i in
                    Button { play(i) } label: {
                        Capsule()
                            .fill(i == beat ? Theme.accent : (i < beat || watchedAll ? Theme.accent.opacity(0.4)
                                                                                   : Color.secondary.opacity(0.25)))
                            .frame(width: i == beat ? 22 : 10, height: 10)
                    }
                    .accessibilityLabel("Part \(i + 1) of \(beats.count)")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: beat)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    // MARK: Playing

    private func play(_ i: Int) {
        guard beats.indices.contains(i) else { return }
        beat = i
        beatStart = Date()
        heldSeconds = 0
        playing = true
        var script = 0
        script = narrator.speak([beats[i].say]) {
            // A short breath between beats, then the next one. The last beat keeps looping.
            let mine = script
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                // Only go on if nothing else has spoken since (another step, a check, a pause).
                guard narrator.generation == mine, beat == i, playing else { return }
                if i + 1 < beats.count {
                    play(i + 1)
                } else {
                    watchedAll = true
                }
            }
        }
    }

    private func pause() {
        heldSeconds = max(0, Date().timeIntervalSince(beatStart))
        playing = false
        narrator.stop()
    }
}

/// Draws one frame of a watch step with the beat's overlays.
struct LearnWatchCanvas: View {
    let guide: LearnGuide
    let beat: LearnBeat
    let frame: Int

    var body: some View {
        Canvas { ctx, size in
            let space = LearnSpace(size: size, aspect: guide.aspect)
            LearnDraw.guidePaths(guide.background, in: &ctx, space: space, style: .demo)

            let lo = max(0, beat.range.lowerBound)
            let hi = min(guide.frames.count - 1, beat.range.upperBound)

            // Onion skin: every drawing of the beat, faint, so the spacing shows.
            if beat.has(.onion), lo < hi {
                var ghost = ctx
                ghost.opacity = 0.2
                for i in lo...hi where i != frame {
                    LearnDraw.guidePaths(guide.frames[i].paths, in: &ghost, space: space, style: .demo)
                }
            }

            if guide.frames.indices.contains(frame) {
                LearnDraw.guidePaths(guide.frames[frame].paths, in: &ctx, space: space, style: .demo)
                LearnDraw.notes(guide.frames[frame].notes, in: &ctx, space: space)
            }

            if beat.has(.trail), lo < hi { drawTrail(&ctx, space: space, lo: lo, hi: hi) }
            if beat.has(.chart), lo < hi { drawChart(&ctx, space: space, lo: lo, hi: hi) }
        }
        .accessibilityHidden(true)
    }

    /// The path the tracked point takes, with a dot for every drawing.
    private func drawTrail(_ ctx: inout GraphicsContext, space: LearnSpace, lo: Int, hi: Int) {
        let pts = LearnMotion.trail(guide, range: lo...hi)
        guard pts.count > 1 else { return }
        let s = space.scale
        var line = Path()
        line.move(to: space.point(pts[0]))
        for p in pts.dropFirst() { line.addLine(to: space.point(p)) }
        ctx.stroke(line, with: .color(Theme.accent.opacity(0.55)),
                   style: StrokeStyle(lineWidth: max(1.5, s * 0.004), lineCap: .round, lineJoin: .round,
                                      dash: [max(3, s * 0.01), max(3, s * 0.008)]))
        for (k, p) in pts.enumerated() {
            let isNow = lo + k == frame
            let r = max(3, s * (isNow ? 0.014 : 0.008))
            let c = space.point(p)
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(isNow ? Theme.accent : Theme.accent.opacity(0.6)))
            if isNow { ctx.stroke(dot, with: .color(.white), lineWidth: max(1, s * 0.003)) }
        }
    }

    /// An animator's timing chart along the bottom: one tick per drawing, spaced like the motion.
    private func drawChart(_ ctx: inout GraphicsContext, space: LearnSpace, lo: Int, hi: Int) {
        let pts = LearnMotion.trail(guide, range: lo...hi)
        let chart = LearnMotion.chart(pts)
        guard chart.count > 1 else { return }
        let s = space.scale
        let rect = space.rect
        let x0 = rect.minX + rect.width * 0.12
        let x1 = rect.maxX - rect.width * 0.12
        let y = rect.maxY - s * 0.075
        let box = CGRect(x: x0 - s * 0.04, y: y - s * 0.06, width: (x1 - x0) + s * 0.08, height: s * 0.12)
        ctx.fill(Path(roundedRect: box, cornerRadius: s * 0.02), with: .color(.white.opacity(0.9)))
        var base = Path()
        base.move(to: CGPoint(x: x0, y: y))
        base.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(base, with: .color(LearnPalette.ink.opacity(0.7)), lineWidth: max(1, s * 0.003))
        for (k, v) in chart.enumerated() {
            let x = x0 + (x1 - x0) * CGFloat(v)
            let isNow = lo + k == frame
            let isKey = k == 0 || k == chart.count - 1
            let h = s * (isKey ? 0.04 : 0.025)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: y - h))
            tick.addLine(to: CGPoint(x: x, y: y + h * 0.4))
            ctx.stroke(tick, with: .color(isNow ? Theme.accent : LearnPalette.ink),
                       lineWidth: max(1.2, s * (isNow ? 0.006 : 0.0035)))
        }
        if let kind = LearnMotion.spacing(of: LearnMotion.gaps(pts)) {
            let label = Text(LearnMotion.label(kind))
                .font(.system(size: min(15, max(9, s * 0.024)), weight: .semibold, design: .rounded))
                .foregroundColor(Theme.accent)
            ctx.draw(label, at: CGPoint(x: (x0 + x1) / 2, y: y + s * 0.018), anchor: .top)
        }
    }
}
