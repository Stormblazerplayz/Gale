import Foundation
import GaleFormat

/// Automatic motion blur: finds the things that moved since the last frame and
/// gives them a fading trail behind them, like a fast camera would.
public enum MotionBlur {
    public struct Sample: Hashable, Sendable {
        /// Where to draw the faded copy, relative to where the thing is now.
        public var offset: Vec2
        public var alpha: Double
    }

    public struct Trail: Hashable, Sendable {
        /// The strokes that moved (as they are in this frame).
        public var strokes: [Stroke]
        /// How far they moved since the last frame.
        public var motion: Vec2
        /// Faded copies, farthest first.
        public var samples: [Sample]
    }

    /// Trails for one layer. `previous` is the same layer on the frame before.
    public static func trails(previous: Cel?, current: Cel, settings: MotionBlurSettings, minMove: Double = 3) -> [Trail] {
        guard settings.on, let previous, settings.amount > 0 else { return [] }
        let before = StashDetector.clusters(previous.strokes)
        let now = StashDetector.clusters(current.strokes)
        guard !before.isEmpty, !now.isEmpty else { return [] }

        struct Info {
            var center: Vec2
            var size: Double
        }
        func info(_ g: [Stroke]) -> Info {
            let drawn = g.filter { $0.brush.kind != .eraser }
            return Info(center: Geometry.centroid(of: drawn), size: max(1, Geometry.bounds(of: drawn).diagonal))
        }
        let a = before.map(info)
        let b = now.map(info)

        // Match each thing now to the thing it most likely was before (closest, similar size).
        var pairs: [(cost: Double, i: Int, j: Int)] = []
        for (j, nb) in b.enumerated() {
            for (i, na) in a.enumerated() {
                let ratio = max(na.size, nb.size) / min(na.size, nb.size)
                let dist = na.center.distance(to: nb.center)
                let onlyOne = a.count == 1 && b.count == 1
                if !onlyOne && (ratio > 2.2 || dist > max(220, 2.5 * nb.size)) { continue }
                pairs.append((dist + (ratio - 1) * nb.size * 0.5, i, j))
            }
        }
        pairs.sort { $0.cost < $1.cost }
        var usedA = Set<Int>(), usedB = Set<Int>()
        var out: [Trail] = []
        let n = min(16, max(2, settings.samples))
        let amount = min(1, max(0, settings.amount))
        for p in pairs where !usedA.contains(p.i) && !usedB.contains(p.j) {
            usedA.insert(p.i)
            usedB.insert(p.j)
            let motion = b[p.j].center - a[p.i].center
            guard motion.length >= minMove else { continue }
            var samples: [Sample] = []
            for k in stride(from: n, through: 1, by: -1) {
                let t = Double(k) / Double(n)
                samples.append(Sample(offset: -motion * (amount * t), alpha: 0.55 * (1 - t * 0.85) / Double(n).squareRoot()))
            }
            out.append(Trail(strokes: now[p.j], motion: motion, samples: samples))
        }
        return out
    }
}
