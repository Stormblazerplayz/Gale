import Foundation
import GaleFormat

/// Automatic hair sway. You circle the hair and say where it's attached; Gale moves it
/// gently over time. The roots stay put and the tips swing the most, with wind and gusts.
public enum HairSway {
    struct Frame2 {
        var origin: Vec2
        /// Along the root line.
        var along: Vec2
        /// Away from the root, toward the tips.
        var out: Vec2
        var length: Double
    }

    static func frame(of region: HairRegion) -> Frame2? {
        guard region.root.count >= 4, region.polygon.count >= 6 else { return nil }
        let a = Vec2(region.root[0], region.root[1])
        let b = Vec2(region.root[2], region.root[3])
        var along = (b - a).normalized
        if along == .zero { along = Vec2(1, 0) }
        var out = along.perpendicular
        let poly = region.polygon
        var c = Vec2.zero
        let n = poly.count / 2
        for i in 0..<n { c = c + Vec2(poly[2 * i], poly[2 * i + 1]) }
        c = c / Double(n)
        let mid = (a + b) / 2
        if (c - mid).dot(out) < 0 { out = -out }
        var length = 0.0
        for i in 0..<n {
            length = max(length, (Vec2(poly[2 * i], poly[2 * i + 1]) - a).dot(out))
        }
        guard length > 1 else { return nil }
        return Frame2(origin: a, along: along, out: out, length: length)
    }

    /// Sways per second, after stiffness (stiff hair moves faster and less).
    public static func frequency(_ region: HairRegion) -> Double {
        max(0.05, region.speed) * (0.6 + 0.8 * min(1, max(0, region.stiffness)))
    }

    /// One full sway takes this many seconds; the motion repeats exactly after it.
    public static func period(_ region: HairRegion) -> Double { 1 / frequency(region) }

    /// Biggest sideways swing at the very tip, in pixels.
    public static func amplitude(_ region: HairRegion, length: Double) -> Double {
        length * 0.2 * (1 - 0.82 * min(1, max(0, region.stiffness)))
    }

    /// Sideways movement (in units of the amplitude) at distance u (0 root ... 1 tip) and time t.
    static func wave(u: Double, t: Double, region: HairRegion) -> Double {
        let w = 2 * Double.pi * frequency(region)
        let lag = 2.4 * u    // tips lag behind the roots, which gives the whip
        let main = sin(w * t - lag)
        let g = min(1, max(0, region.gust))
        let gusts = g * (0.45 * sin(2 * w * t - 1.7 * lag + 1.3) + 0.25 * sin(3 * w * t - 2.3 * lag + 0.4))
        let wind = min(1, max(-1, region.wind)) * 0.9
        return wind + main * (1 - 0.35 * abs(wind)) + gusts
    }

    /// Moves points that are in the hair region. Points outside stay, with a soft edge so lines don't tear.
    public static func deform(_ points: [StrokePoint], region: HairRegion, time: Double, feather: Double = 18) -> [StrokePoint] {
        guard region.on, let f = frame(of: region) else { return points }
        let box = Geometry.bounds(ofPath: region.polygon).inset(by: -feather)
        let amp = amplitude(region, length: f.length)
        return points.map { p in
            let v = Vec2(p)
            guard box.contains(v) else { return p }
            var weight = 1.0
            if !Geometry.contains(region.polygon, v) {
                let d = Geometry.distanceToOutline(region.polygon, v)
                guard d < feather else { return p }
                weight = 1 - d / feather
            }
            let u = min(1, max(0, (v - f.origin).dot(f.out) / f.length))
            let side = amp * pow(u, 1.6) * wave(u: u, t: time, region: region) * weight
            // Pull tips up a little as they swing, so the hair doesn't look like it stretches.
            let lift = -(side * side) / (2 * f.length) * u
            let moved = v + f.along * side + f.out * lift
            var q = p
            q.x = moved.x
            q.y = moved.y
            return q
        }
    }

    /// A cel with every region for its layer applied.
    public static func deform(_ cel: Cel, regions: [HairRegion], time: Double) -> Cel {
        let active = regions.filter(\.on)
        guard !active.isEmpty else { return cel }
        var out = cel
        out.strokes = cel.strokes.map { s in
            var s = s
            for r in active { s.points = deform(s.points, region: r, time: time) }
            return s
        }
        return out
    }

    /// The regions that act on a layer.
    public static func regions(in project: GaleProject, layer: String) -> [HairRegion] {
        project.hair.filter { $0.on && $0.layer == layer }
    }

    /// Makes `count` cels that play one full sway (for baking the sway into real frames).
    public static func bake(_ cel: Cel, region: HairRegion, fps: Int) -> [Cel] {
        let count = max(2, Int((period(region) * Double(max(1, fps))).rounded()))
        return (0..<count).map { i in
            deform(cel, regions: [region], time: Double(i) / Double(max(1, fps)))
        }
    }

    /// A good root line for a hand-drawn region: the edge of its box on the `side` where the hair is attached.
    public enum AttachSide: String, CaseIterable, Sendable { case top, left, right, bottom }

    public static func root(for polygon: [Double], side: AttachSide) -> [Double] {
        let b = Geometry.bounds(ofPath: polygon)
        switch side {
        case .top: return [b.minX, b.minY, b.maxX, b.minY]
        case .bottom: return [b.minX, b.maxY, b.maxX, b.maxY]
        case .left: return [b.minX, b.minY, b.minX, b.maxY]
        case .right: return [b.maxX, b.minY, b.maxX, b.maxY]
        }
    }
}
