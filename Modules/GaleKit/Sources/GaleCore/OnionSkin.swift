import Foundation
import GaleFormat

/// Onion skin settings: which nearby frames show through, and how.
public struct OnionSettings: Codable, Hashable, Sendable {
    public var on: Bool
    /// Frames before the current one (0...5).
    public var before: Int
    /// Frames after the current one (0...5).
    public var after: Int
    /// Opacity of the nearest ghost (0...1).
    public var opacity: Double
    /// Each step further away is this much as strong (0...1).
    public var falloff: Double
    /// Frosted glass: ghosts are blurred and milky, so they guide without getting in the way.
    public var frosted: Bool
    /// Blur radius in screen points for the nearest frosted ghost.
    public var blur: Double
    /// At the ends of the animation, wrap around (handy for loops like walk cycles).
    public var wrap: Bool

    public init(on: Bool = true, before: Int = 2, after: Int = 1, opacity: Double = 0.5, falloff: Double = 0.6,
                frosted: Bool = true, blur: Double = 3, wrap: Bool = false) {
        self.on = on
        self.before = before
        self.after = after
        self.opacity = opacity
        self.falloff = falloff
        self.frosted = frosted
        self.blur = blur
        self.wrap = wrap
    }
}

/// One ghost frame to draw under the current frame.
public struct OnionGhost: Hashable, Sendable {
    public enum Side: String, Sendable { case before, after }

    public var frameIndex: Int
    /// -1 = the frame just before, +2 = two frames after.
    public var offset: Int
    public var opacity: Double
    /// 0 = sharp.
    public var blur: Double
    public var side: Side
    /// Ghost tint: frames before are a cool blue, frames after a warm orange.
    public var tint: RGBA {
        side == .before ? RGBA(0.25, 0.55, 1.0) : RGBA(1.0, 0.55, 0.2)
    }
}

public enum OnionSkin {
    /// Ghosts to draw, farthest first (so the nearest ends up on top).
    public static func ghosts(current: Int, frameCount: Int, settings: OnionSettings) -> [OnionGhost] {
        guard settings.on, frameCount > 1, current >= 0, current < frameCount else { return [] }
        var out: [OnionGhost] = []
        var used = Set([current])
        func add(_ offset: Int, side: OnionGhost.Side) {
            var idx = current + offset
            if settings.wrap {
                idx = ((idx % frameCount) + frameCount) % frameCount
            }
            guard idx >= 0, idx < frameCount, !used.contains(idx) else { return }
            used.insert(idx)
            let d = Double(abs(offset))
            let opacity = min(1, max(0, settings.opacity)) * pow(min(1, max(0, settings.falloff)), d - 1)
            let blur = settings.frosted ? max(0, settings.blur) * (1 + 0.6 * (d - 1)) : 0
            out.append(OnionGhost(frameIndex: idx, offset: offset, opacity: opacity, blur: blur, side: side))
        }
        let before = min(5, max(0, settings.before))
        let after = min(5, max(0, settings.after))
        // Nearest first so wrapping never lets a far ghost steal a near frame's spot.
        for d in 1...max(1, max(before, after)) {
            if d <= before { add(-d, side: .before) }
            if d <= after { add(d, side: .after) }
        }
        return out.sorted { abs($0.offset) > abs($1.offset) }
    }
}
