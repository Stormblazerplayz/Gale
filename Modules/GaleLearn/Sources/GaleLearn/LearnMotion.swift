import Foundation

/// The maths behind the overlays on watch steps: motion trails, spacing and timing charts.
public enum LearnMotion {
    /// The tracked point on every frame of a range (frames with nothing to track are left out).
    public static func trail(_ guide: LearnGuide, range: ClosedRange<Int>) -> [LearnPoint] {
        let lo = max(0, range.lowerBound)
        let hi = min(guide.frames.count - 1, range.upperBound)
        guard lo <= hi else { return [] }
        return (lo...hi).compactMap { guide.trackPoint(frame: $0) }
    }

    /// How far the point moves from each frame to the next.
    public static func gaps(_ points: [LearnPoint]) -> [Double] {
        guard points.count > 1 else { return [] }
        return (1..<points.count).map { points[$0 - 1].distance(to: points[$0]) }
    }

    /// A timing chart: where each drawing sits between the first (0) and the last (1),
    /// measured along the path. Close ticks are slow, far-apart ticks are fast.
    public static func chart(_ points: [LearnPoint]) -> [Double] {
        let g = gaps(points)
        let total = g.reduce(0, +)
        guard points.count > 1 else { return points.isEmpty ? [] : [0] }
        guard total > 1e-9 else { return Array(repeating: 0, count: points.count) }
        var out: [Double] = [0]
        var run = 0.0
        for d in g {
            run += d
            out.append(min(1, run / total))
        }
        return out
    }

    /// What kind of spacing a list of gaps has, if it's clear enough to name.
    public static func spacing(of gaps: [Double]) -> LearnSpacing? {
        guard gaps.count >= 2, gaps.reduce(0, +) > 1e-6 else { return nil }
        if gaps.count >= 3 && LearnMeasure.matches(gaps, .easeInOut) { return .easeInOut }
        if LearnMeasure.matches(gaps, .easeIn) { return .easeIn }
        if LearnMeasure.matches(gaps, .easeOut) { return .easeOut }
        if LearnMeasure.matches(gaps, .even) { return .even }
        return nil
    }

    /// A short label animators use, for the chart: "Slow in", "Slow out", "Ease in and out", "Even".
    public static func label(_ s: LearnSpacing) -> String {
        switch s {
        case .even: return "Even spacing"
        case .easeIn: return "Speeding up"
        case .easeOut: return "Slowing down"
        case .easeInOut: return "Slow, fast, slow"
        }
    }

    /// The frames a beat plays, as (frame index, how long it stays in ticks) for one pass.
    public static func playlist(_ guide: LearnGuide, beat: LearnBeat) -> [(frame: Int, ticks: Int)] {
        guard !guide.frames.isEmpty else { return [] }
        let lo = min(max(0, beat.range.lowerBound), guide.frames.count - 1)
        let hi = min(max(lo, beat.range.upperBound), guide.frames.count - 1)
        return (lo...hi).map { ($0, max(1, guide.frames[$0].hold)) }
    }

    /// Which frame a beat shows after `seconds` (the beat loops its frames; `speed` 0.5 = half speed).
    /// A beat that holds one drawing always shows that drawing.
    public static func frame(_ guide: LearnGuide, beat: LearnBeat, seconds: Double, speed: Double = 1) -> Int {
        let list = playlist(guide, beat: beat)
        guard let first = list.first else { return 0 }
        guard list.count > 1 else { return first.frame }
        let total = list.reduce(0) { $0 + $1.ticks }
        // Rest a moment on the last drawing so the pose reads before it starts again.
        let rest = max(4, guide.fps / 2)
        let cycle = total + rest
        var t = Int((max(0, seconds) * Double(max(1, guide.fps)) * max(0.05, speed)).rounded(.down)) % max(1, cycle)
        for item in list {
            if t < item.ticks { return item.frame }
            t -= item.ticks
        }
        return list[list.count - 1].frame
    }
}
