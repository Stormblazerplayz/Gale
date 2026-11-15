import SwiftUI
import GaleFormat
import GaleCore
import GaleLearn

/// A small round icon button used under the drawing pads.
struct LearnPadButton: View {
    let symbol: String
    let label: String
    var isOn = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 34)
                .background(isOn ? Theme.accent.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(isOn ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Trace

/// Trace over the gray guide lines.
struct LearnTracePad: View {
    let guide: LearnGuide
    @ObservedObject var ink: LearnInk
    var smoothing = 0.25

    var body: some View {
        VStack(spacing: 10) {
            LearnPaper(aspect: guide.aspect) {
                LearnGuideCanvas(guide: guide, frame: 0, style: .target)
                LearnInkCanvas(strokes: ink.currentStrokes, aspect: guide.aspect)
                LearnLiveCanvas(live: ink.live, aspect: guide.aspect)
                LearnTouchSurface(ink: ink, aspect: guide.aspect, smoothing: smoothing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text("Draw right on top of the gray lines.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                LearnPadButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: ink.canUndo) { ink.undo() }
                LearnPadButton(symbol: "trash", label: "Clear", enabled: !ink.currentStrokes.isEmpty) { ink.clearCurrent() }
            }
        }
    }
}

// MARK: - Frames

/// Draw an animation one frame at a time, with a faint guide and a frosted onion skin.
struct LearnFramesPad: View {
    let guide: LearnGuide
    @ObservedObject var ink: LearnInk
    var smoothing = 0.25

    @State private var showGuide = true
    @State private var showOnion = true
    @State private var previewing = false

    var body: some View {
        VStack(spacing: 10) {
            LearnPaper(aspect: guide.aspect) {
                if previewing {
                    LearnFramesPreview(guide: guide, frames: ink.frames)
                } else {
                    // The guide's scenery (ground, props) is under every frame.
                    LearnGuideCanvas(guide: guide, frame: -1, style: .ghost)
                    if showOnion {
                        LearnOnionLayer(frames: ink.frames, current: ink.current, wrap: guide.loop, aspect: guide.aspect)
                    }
                    if showGuide {
                        LearnGuideCanvas(guide: guide, frame: ink.current, style: .ghost, showNotes: false)
                    }
                    LearnInkCanvas(strokes: ink.currentStrokes, aspect: guide.aspect)
                    LearnLiveCanvas(live: ink.live, aspect: guide.aspect)
                    LearnTouchSurface(ink: ink, aspect: guide.aspect, smoothing: smoothing)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(previewing ? "Playing your frames" : "Frame \(ink.current + 1) of \(ink.frameCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                LearnPadButton(symbol: "chevron.left", label: "Previous frame", enabled: !previewing && ink.current > 0) {
                    ink.select(ink.current - 1)
                }
                LearnPadButton(symbol: "chevron.right", label: "Next frame",
                               enabled: !previewing && ink.current < ink.frameCount - 1) {
                    ink.select(ink.current + 1)
                }
                Spacer(minLength: 0)
                LearnPadButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: !previewing && ink.canUndo) { ink.undo() }
                LearnPadButton(symbol: "trash", label: "Clear this frame",
                               enabled: !previewing && !ink.currentStrokes.isEmpty) { ink.clearCurrent() }
                LearnPadButton(symbol: "eye", label: "Show guide", isOn: showGuide, enabled: !previewing) { showGuide.toggle() }
                LearnPadButton(symbol: "circle.dashed", label: "Onion skin", isOn: showOnion, enabled: !previewing) {
                    showOnion.toggle()
                }
                LearnPadButton(symbol: previewing ? "stop.fill" : "play.fill", label: previewing ? "Stop" : "Play my frames",
                               isOn: previewing, enabled: ink.drawnFrameCount > 0 || previewing) {
                    previewing.toggle()
                }
            }

            LearnFrameStrip(guide: guide, ink: ink, showGuide: showGuide) { i in
                previewing = false
                ink.select(i)
            }
        }
    }
}

/// Little pictures of every frame. Tap one to draw on it.
struct LearnFrameStrip: View {
    let guide: LearnGuide
    @ObservedObject var ink: LearnInk
    let showGuide: Bool
    let select: (Int) -> Void

    private let height: CGFloat = 50

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<ink.frameCount, id: \.self) { i in
                        Button { select(i) } label: { thumb(i) }
                            .buttonStyle(.plain)
                            .id(i)
                            .accessibilityLabel("Frame \(i + 1)\(ink.frames[i].isEmpty ? ", empty" : "")")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
            .onChange(of: ink.current) { _, new in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: height + 8)
    }

    private func thumb(_ i: Int) -> some View {
        let selected = i == ink.current
        return ZStack {
            LearnPalette.paper
            if showGuide {
                LearnGuideCanvas(guide: guide, frame: i, style: .ghost, showNotes: false)
            }
            LearnInkCanvas(strokes: ink.frames[i], aspect: guide.aspect, widthScale: 1.8)
        }
        .frame(width: height * CGFloat(guide.aspect), height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(selected ? Theme.accent : Color.black.opacity(0.12), lineWidth: selected ? 2.5 : 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Text("\(i + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? Color.white : LearnPalette.ink)
                .padding(.horizontal, 4)
                .background(selected ? Theme.accent : Color.white.opacity(0.85), in: Capsule())
                .padding(3)
        }
    }
}

/// Frosted onion skin: earlier frames show through blurred and milky blue (later ones milky orange),
/// on a pane of frosted glass, so they guide you without getting in the way.
struct LearnOnionLayer: View {
    let frames: [[LearnInkStroke]]
    let current: Int
    let wrap: Bool
    let aspect: Double

    static func settings(wrap: Bool) -> OnionSettings {
        OnionSettings(on: true, before: 2, after: 1, opacity: 0.65, falloff: 0.6, frosted: true, blur: 2.5, wrap: wrap)
    }

    static func milky(_ t: RGBA) -> Color {
        Color(.sRGB, red: 0.35 + 0.65 * t.r, green: 0.35 + 0.65 * t.g, blue: 0.35 + 0.65 * t.b, opacity: 1)
    }

    var body: some View {
        let ghosts = OnionSkin.ghosts(current: current, frameCount: frames.count, settings: LearnOnionLayer.settings(wrap: wrap))
            .filter { frames.indices.contains($0.frameIndex) && !frames[$0.frameIndex].isEmpty }
        ZStack {
            if !ghosts.isEmpty {
                Rectangle().fill(.ultraThinMaterial)
            }
            ForEach(ghosts, id: \.frameIndex) { g in
                let strokes = frames[g.frameIndex]
                let tint = LearnOnionLayer.milky(g.tint)
                Canvas { ctx, size in
                    let space = LearnSpace(size: size, aspect: aspect)
                    LearnInkDraw.strokes(strokes, in: &ctx, space: space, color: .white.opacity(0.9), widthScale: 2.6)
                    LearnInkDraw.strokes(strokes, in: &ctx, space: space, color: tint, widthScale: 1.4)
                }
                .blur(radius: CGFloat(g.blur))
                .opacity(g.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Plays back the frames you drew, at the guide's speed.
struct LearnFramesPreview: View {
    let guide: LearnGuide
    let frames: [[LearnInkStroke]]
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let cycle = max(0.05, guide.duration)
            let t = max(0, context.date.timeIntervalSince(start)).truncatingRemainder(dividingBy: cycle)
            let i = guide.frameIndex(atTime: t, speed: 1)
            ZStack {
                LearnGuideCanvas(guide: guide, frame: -1, style: .scenery)
                LearnInkCanvas(strokes: frames.indices.contains(i) ? frames[i] : [], aspect: guide.aspect)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Practice

/// A free page to try things out (like the stabilizer) without being checked.
struct LearnPracticePad: View {
    var showsSmoothing: Bool
    var aspect: Double = LearnGuide.defaultAspect

    @StateObject private var ink = LearnInk(frameCount: 1)
    @State private var smoothing = 0.5

    var body: some View {
        VStack(spacing: 10) {
            LearnPaper(aspect: aspect) {
                LearnInkCanvas(strokes: ink.currentStrokes, aspect: aspect)
                LearnLiveCanvas(live: ink.live, aspect: aspect)
                LearnTouchSurface(ink: ink, aspect: aspect, smoothing: showsSmoothing ? smoothing : 0.2)
            }
            if showsSmoothing {
                HStack(spacing: 10) {
                    Image(systemName: "scribble.variable").foregroundStyle(.secondary)
                    Text("Smoothing")
                        .font(.subheadline.weight(.medium))
                    Slider(value: $smoothing, in: 0...1)
                        .tint(Theme.accent)
                    Text("\(Int((smoothing * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
            }
            HStack(spacing: 10) {
                Text(showsSmoothing ? "Draw a wobbly line, then change the smoothing and draw it again."
                                    : "Scribble here as much as you like. Nothing is checked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                LearnPadButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: ink.canUndo) { ink.undo() }
                LearnPadButton(symbol: "trash", label: "Clear", enabled: !ink.currentStrokes.isEmpty) { ink.clearCurrent() }
            }
        }
    }
}
