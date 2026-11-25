import GaleFormat
import GalePixel
import SwiftUI

/// Plays a pixel story full screen on an old TV: scenes in order, words typed out, bubbles popping in.
struct StoryPlayerView: View {
    let story: PixelStory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderer: StoryRenderer
    @State private var start = Date()
    @State private var pausedAt: Double?
    @State private var showControls = true
    @State private var poweredOn = false

    init(story: PixelStory) {
        self.story = story
        _renderer = State(initialValue: StoryRenderer(story: story, maxSide: 360))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pausedAt != nil)) { tl in
                let t = time(at: tl.date)
                VStack(spacing: 16) {
                    television(PixelImageView(image: renderer.image(at: t)))
                    if showControls { controls(t) }
                }
                .padding(20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showControls.toggle() } }
        .overlay(alignment: .topLeading) {
            if showControls {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 16, weight: .black)) }
                    .buttonStyle(RetroButtonStyle(color: Retro.panel))
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("closePlayer")
                    .padding(16)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        // Keep the buttons inside as their own elements, so "closePlayer" isn't renamed to "storyPlayer".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storyPlayer")
        .onAppear {
            start = Date()
            if reduceMotion {
                poweredOn = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { poweredOn = true }
            }
        }
    }

    private func time(at date: Date) -> Double {
        pausedAt ?? date.timeIntervalSince(start)
    }

    /// The picture inside a chunky TV with scanlines. It switches on like an old set: a bright line that opens up.
    private func television(_ picture: some View) -> some View {
        let aspect = CGFloat(renderer.layout.width) / CGFloat(max(1, renderer.layout.height))
        return picture
            .overlay(Scanlines(spacing: 3, opacity: 0.18))
            .overlay(
                RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 80, endRadius: 520)
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .scaleEffect(x: 1, y: poweredOn ? 1 : 0.012)
            .brightness(poweredOn ? 0 : 0.8)
            .aspectRatio(aspect, contentMode: .fit)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(LinearGradient(colors: [Retro.panel, Retro.screen], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(Retro.line, lineWidth: 3))
            )
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(poweredOn ? Retro.mint : Retro.pink).frame(width: 8, height: 8).padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func controls(_ t: Double) -> some View {
        let total = renderer.timing.total
        let looped = total > 0 ? t.truncatingRemainder(dividingBy: total) : 0
        let at = renderer.timing.locate(t)
        return HStack(spacing: 14) {
            Button {
                if let p = pausedAt {
                    start = Date().addingTimeInterval(-p)
                    pausedAt = nil
                } else {
                    pausedAt = t
                }
            } label: {
                Image(systemName: pausedAt == nil ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .black)).frame(width: 24)
            }
            .buttonStyle(RetroButtonStyle(color: Retro.yellow, text: .black))
            .accessibilityLabel(pausedAt == nil ? "Pause" : "Play")
            Button {
                start = Date()
                if pausedAt != nil { pausedAt = 0 }
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 18, weight: .black))
            }
            .buttonStyle(RetroButtonStyle(color: Retro.panel))
            .accessibilityLabel("Start again")
            Slider(value: Binding(
                get: { looped },
                set: { v in
                    if pausedAt != nil { pausedAt = v } else { start = Date().addingTimeInterval(-v) }
                }), in: 0...max(0.01, total))
                .tint(Retro.yellow)
                .accessibilityLabel("Story time")
            PixelLabel(text: String(format: "%d/%d", at.scene + 1, story.scenes.count), color: Retro.sky, dot: 2)
                .accessibilityLabel("Scene \(at.scene + 1) of \(story.scenes.count)")
        }
        .padding(12)
        .background(Retro.panel.opacity(0.9), in: Rectangle())
        .frame(maxWidth: 720)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
