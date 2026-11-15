import Foundation
import GaleFormat

/// Timing math: which frame shows at a given time.
public enum Playback {
    /// The tick each frame starts on.
    public static func tickStarts(_ frames: [Frame]) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(frames.count)
        var t = 0
        for f in frames {
            out.append(t)
            t += max(1, f.hold)
        }
        return out
    }

    public static func totalTicks(_ frames: [Frame]) -> Int {
        frames.reduce(0) { $0 + max(1, $1.hold) }
    }

    /// The frame on screen at `tick`. The animation loops, so any tick works (even negative ones).
    public static func frameIndex(atTick tick: Int, frames: [Frame]) -> Int {
        let total = totalTicks(frames)
        guard total > 0 else { return 0 }
        let t = ((tick % total) + total) % total
        var acc = 0
        for (i, f) in frames.enumerated() {
            acc += max(1, f.hold)
            if t < acc { return i }
        }
        return frames.count - 1
    }

    public static func tick(atTime time: Double, fps: Int) -> Int {
        Int((max(0, time) * Double(max(1, fps)) + 1e-9).rounded(.down))
    }

    public static func frameIndex(atTime time: Double, project: GaleProject) -> Int {
        frameIndex(atTick: tick(atTime: time, fps: project.fps), frames: project.frames)
    }

    /// When frame `index` first appears, in seconds.
    public static func time(ofFrame index: Int, project: GaleProject) -> Double {
        let starts = tickStarts(project.frames)
        guard starts.indices.contains(index) else { return 0 }
        return Double(starts[index]) / Double(max(1, project.fps))
    }

    /// How many ticks to render for an export that plays the animation `repeats` times,
    /// and at least `minimumSeconds` long (so a single swaying drawing still makes a real video).
    public static func exportTicks(project: GaleProject, repeats: Int, minimumSeconds: Double = 0) -> Int {
        let once = max(1, project.totalTicks)
        let base = once * max(1, repeats)
        let minTicks = Int((minimumSeconds * Double(project.fps)).rounded(.up))
        if minTicks > base {
            // Round up to whole plays so loops end cleanly.
            return Int((Double(minTicks) / Double(once)).rounded(.up)) * once
        }
        return base
    }
}
