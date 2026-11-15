import Combine
import CoreGraphics
import Foundation
import GaleCore
import GaleFormat
import QuartzCore

/// Plays the animation with hair sway and motion blur, drawing frames ahead of time so it never stutters.
@MainActor
final class AnimationPlayer: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var frameIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var preparing = false

    private var frames: [CGImage?] = []
    private var project: GaleProject?
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var startTick = 0
    private var job: Task<Void, Never>?

    func play(_ project: GaleProject, from frame: Int, maxSide: CGFloat) {
        stop()
        self.project = project
        isPlaying = true
        preparing = true
        frames = Array(repeating: nil, count: project.frames.count)
        let scale = min(1, maxSide / CGFloat(max(project.canvas.width, project.canvas.height)))
        startTick = Playback.tickStarts(project.frames)[min(frame, project.frames.count - 1)]
        frameIndex = frame
        job = Task.detached(priority: .userInitiated) { [weak self] in
            var opts = FrameRenderer.Options()
            opts.hair = true
            opts.motionBlur = true
            // Draw the starting frame first so playback can begin right away.
            let order = Array(frame..<project.frames.count) + Array(0..<frame)
            for i in order {
                if Task.isCancelled { return }
                let img = FrameRenderer.image(project, frameIndex: i, scale: scale, options: opts)
                await MainActor.run { [weak self] in
                    guard let self, self.frames.indices.contains(i) else { return }
                    self.frames[i] = img
                    if i == frame { self.beginClock() }
                }
            }
            await MainActor.run { [weak self] in self?.preparing = false }
        }
    }

    private func beginClock() {
        guard isPlaying, link == nil else { return }
        startTime = CACurrentMediaTime()
        let l = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.step() }, selector: #selector(DisplayLinkTarget.fire))
        l.add(to: .main, forMode: .common)
        link = l
        step()
    }

    private func step() {
        guard let p = project, !p.frames.isEmpty else { return }
        let elapsed = CACurrentMediaTime() - startTime
        let tick = startTick + Playback.tick(atTime: elapsed, fps: p.fps)
        let i = Playback.frameIndex(atTick: tick, frames: p.frames)
        // If a frame isn't drawn yet, keep showing the last one.
        if frames.indices.contains(i), let img = frames[i] {
            if i != frameIndex || image == nil {
                frameIndex = i
                image = img
            }
        }
    }

    func stop() {
        job?.cancel()
        job = nil
        link?.invalidate()
        link = nil
        isPlaying = false
        preparing = false
        image = nil
        frames = []
        project = nil
    }
}

/// CADisplayLink keeps a strong reference to its target, so this small object sits in between.
final class DisplayLinkTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
