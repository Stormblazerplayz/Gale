import Foundation
import GaleFormat

/// When each scene of a pixel story plays, and what shows at any moment.
public struct StoryTiming: Hashable, Sendable {
    /// Letters per second the typewriter shows.
    public static let lettersPerSecond = 24.0
    /// How long a fade, wipe or circle takes.
    public static let transitionSeconds = 0.5
    /// Time to read the words after they finish typing.
    public static let readSeconds = 1.6
    /// A pause before typing starts.
    public static let typeDelay = 0.2
    public static let minSceneSeconds = 0.5
    public static let maxSceneSeconds = 60.0

    public struct Span: Hashable, Sendable {
        public var scene: Int
        public var start: Double
        public var duration: Double
        /// When typing starts, from the scene's start.
        public var typeStart: Double
        public var end: Double { start + duration }
    }

    public let spans: [Span]
    public let total: Double

    public init(_ story: PixelStory) {
        var spans: [Span] = []
        var t = 0.0
        for (i, scene) in story.scenes.enumerated() {
            let typeStart = StoryTiming.typeStart(scene)
            let letters = StoryTiming.letters(scene)
            let reading = letters == 0 ? 0 : typeStart + Double(letters) / StoryTiming.lettersPerSecond + StoryTiming.readSeconds
            let animation = Double(scene.loops) * scene.loopSeconds
            let d = min(StoryTiming.maxSceneSeconds, max(StoryTiming.minSceneSeconds, animation, reading))
            spans.append(Span(scene: i, start: t, duration: d, typeStart: typeStart))
            t += d
        }
        self.spans = spans
        total = t
    }

    static func typeStart(_ scene: PixelScene) -> Double {
        (scene.transition == .cut ? 0 : transitionSeconds) + typeDelay
    }

    /// Letters the typewriter shows in a scene: the caption first, then each bubble in order.
    public static func letters(_ scene: PixelScene) -> Int {
        let parts = [scene.caption] + scene.bubbles.map(\.text)
        return parts.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
    }

    /// Which scene plays at `time` (looped over the story) and how far into it.
    public func locate(_ time: Double, loop: Bool = true) -> (scene: Int, local: Double) {
        guard !spans.isEmpty, total > 0 else { return (0, 0) }
        var t = time.isFinite ? time : 0
        if loop {
            t = t.truncatingRemainder(dividingBy: total)
            if t < 0 { t += total }
        } else {
            t = min(max(0, t), total - 1e-9)
        }
        // Binary search: scenes are in time order.
        var lo = 0, hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spans[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        let s = spans[lo]
        return (s.scene, min(s.duration, max(0, t - s.start)))
    }

    /// Frame of a scene showing `local` seconds after the scene starts (the animation loops).
    public static func frameIndex(_ scene: PixelScene, local: Double) -> Int {
        let total = scene.ticks
        guard total > 0, scene.frames.count > 1 else { return 0 }
        var tick = Int((max(0, local) * Double(scene.fps)).rounded(.down)) % total
        for (i, f) in scene.frames.enumerated() {
            if tick < f.hold { return i }
            tick -= f.hold
        }
        return scene.frames.count - 1
    }

    /// How many letters the typewriter shows `local` seconds into a scene.
    public func typed(scene: Int, local: Double) -> Int {
        guard spans.indices.contains(scene) else { return 0 }
        let t = local - spans[scene].typeStart
        guard t > 0 else { return 0 }
        return Int((t * StoryTiming.lettersPerSecond).rounded(.down))
    }
}
