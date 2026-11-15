import Foundation
import GaleFormat

/// Saving animation loops (like walk cycles) and dropping them into scenes.
public enum LoopTools {
    /// Makes a loop from frames `range` of the project. The chosen layers are flattened into one, back to front.
    public static func makeLoop(from project: GaleProject, layerIDs: [String], range: ClosedRange<Int>,
                                name: String, kind: LoopKind, stride: Double = 0) -> LoopItem? {
        let lo = max(0, range.lowerBound)
        let hi = min(project.frames.count - 1, range.upperBound)
        guard lo <= hi else { return nil }
        let wanted = Set(layerIDs)
        let order = project.layers.filter { wanted.contains($0.id) && $0.visible }.map(\.id)
        guard !order.isEmpty else { return nil }
        var frames: [LoopFrame] = []
        for i in lo...hi {
            let f = project.frames[i]
            var strokes: [Stroke] = []
            var fills: [Fill] = []
            for lid in order {
                let cel = f.cel(lid)
                fills += cel.fills
                strokes += cel.strokes
            }
            frames.append(LoopFrame(hold: f.hold, strokes: rekey(strokes), fills: rekey(fills)))
        }
        guard frames.contains(where: { !$0.strokes.isEmpty || !$0.fills.isEmpty }) else { return nil }
        return LoopItem(name: name, kind: kind, fps: project.fps, width: project.canvas.width, height: project.canvas.height,
                        stride: stride, frames: frames)
    }

    /// Where a loop's drawing sits (all frames together).
    public static func bounds(of loop: LoopItem) -> Box {
        loop.frames.reduce(Box.empty) { box, f in
            box.union(Geometry.bounds(of: f.strokes)).union(f.fills.reduce(Box.empty) { $0.union(Geometry.bounds(ofPath: $1.path)) })
        }
    }

    public struct Placement: Hashable, Sendable {
        /// How many times the loop plays.
        public var cycles: Int
        /// Moves the whole loop.
        public var offset: Vec2
        /// Scales the loop around its center.
        public var scale: Double
        /// Walk across the screen: each cycle moves `loop.stride` pixels this way (+1 right, -1 left, 0 stay).
        public var direction: Double
        /// Mirror the loop (for walking the other way).
        public var mirrored: Bool
        /// Spread each cycle's move over its frames, so the walk glides instead of jumping once per cycle.
        public var smoothTravel: Bool

        public init(cycles: Int = 1, offset: Vec2 = .zero, scale: Double = 1, direction: Double = 0, mirrored: Bool = false, smoothTravel: Bool = true) {
            self.cycles = max(1, cycles)
            self.offset = offset
            self.scale = scale
            self.direction = direction
            self.mirrored = mirrored
            self.smoothTravel = smoothTravel
        }
    }

    /// Drops a loop into the project on `layerID`, starting at frame `start`.
    /// Missing frames are added at the end. Strokes already there stay; the loop draws on top.
    /// Returns the frame indexes it drew on.
    @discardableResult
    public static func insert(_ loop: LoopItem, into project: inout GaleProject, layerID: String, at start: Int,
                              placement: Placement = Placement()) -> [Int] {
        guard !loop.frames.isEmpty, project.layerIndex(layerID) != nil else { return [] }
        let box = bounds(of: loop)
        let center = box.isEmpty ? Vec2(loop.width / 2, loop.height / 2) : box.center
        var touched: [Int] = []
        var index = max(0, min(start, project.frames.count))
        let perCycle = loop.frames.count
        for cycle in 0..<placement.cycles {
            for (j, lf) in loop.frames.enumerated() {
                var strokes = lf.strokes
                var fills = lf.fills
                if placement.mirrored {
                    strokes = StrokeTransform.flipHorizontally(strokes, axis: center.x)
                    fills = StrokeTransform.flipHorizontally(fills, axis: center.x)
                }
                if placement.scale != 1, placement.scale > 0 {
                    strokes = StrokeTransform.scale(strokes, by: placement.scale, around: center)
                    fills = StrokeTransform.scale(fills, by: placement.scale, around: center)
                }
                let progress = placement.smoothTravel ? Double(cycle) + Double(j) / Double(perCycle) : Double(cycle)
                let travel = loop.stride * placement.scale * placement.direction * progress
                let dx = placement.offset.x + travel
                let dy = placement.offset.y
                strokes = StrokeTransform.freshIDs(StrokeTransform.translate(strokes, dx: dx, dy: dy))
                fills = StrokeTransform.freshIDs(StrokeTransform.translate(fills, dx: dx, dy: dy))

                if index >= project.frames.count {
                    index = project.insertFrame(Frame(hold: lf.hold), after: project.frames.count - 1)
                }
                var cel = project.frames[index].cel(layerID)
                for f in fills { cel.append(f) }
                for s in strokes { cel.append(s) }
                project.frames[index].cels[layerID] = cel
                touched.append(index)
                index += 1
            }
        }
        return touched
    }

    /// The loop facing the other way.
    public static func mirrored(_ loop: LoopItem) -> LoopItem {
        var l = loop
        let axis = bounds(of: loop).center.x
        l.frames = loop.frames.map { f in
            LoopFrame(hold: f.hold,
                      strokes: StrokeTransform.flipHorizontally(f.strokes, axis: axis),
                      fills: StrokeTransform.flipHorizontally(f.fills, axis: axis))
        }
        return l
    }

    static func rekey(_ strokes: [Stroke]) -> [Stroke] {
        var cel = Cel()
        for s in strokes { cel.append(s) }
        return cel.strokes
    }

    static func rekey(_ fills: [Fill]) -> [Fill] {
        var cel = Cel()
        for f in fills { cel.append(f) }
        return cel.fills
    }
}
