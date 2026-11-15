import Foundation
import GaleFormat

/// Finds the separate "things" in a drawing (a tree, a cloud, a face) so Gale can save each one
/// to the stash by itself, ready to drag into other frames.
public enum StashDetector {
    /// Groups strokes whose boxes touch or come within `gap` pixels of each other.
    public static func clusters(_ strokes: [Stroke], gap: Double = 24) -> [[Stroke]] {
        let drawn = strokes.filter { $0.brush.kind != .eraser && !$0.points.isEmpty }
        let n = drawn.count
        guard n > 0 else { return [] }
        let boxes = drawn.map { Geometry.bounds(of: $0).inset(by: -gap / 2) }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        // Sweep along x so big drawings don't compare every pair.
        let order = (0..<n).sorted { boxes[$0].minX < boxes[$1].minX }
        var active: [Int] = []
        for i in order {
            active.removeAll { boxes[$0].maxX < boxes[i].minX }
            for j in active where boxes[i].intersects(boxes[j]) { union(i, j) }
            active.append(i)
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(i) }
        // Keep drawing order inside each group; groups ordered by their first stroke.
        let erasers = strokes.filter { $0.brush.kind == .eraser }
        return groups.values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
            .map { idxs in
                var members = idxs.map { drawn[$0] }
                // Erasers that touch the group belong to it (they shaped it).
                let box = Geometry.bounds(of: members)
                let touching = erasers.filter { Geometry.bounds(of: $0).intersects(box) }
                if !touching.isEmpty {
                    let ids = Set(members.map(\.id)).union(touching.map(\.id))
                    members = strokes.filter { ids.contains($0.id) }
                }
                return members
            }
    }

    /// Is this group big enough to be worth saving?
    public static func isWorthSaving(_ group: [Stroke]) -> Bool {
        let drawn = group.filter { $0.brush.kind != .eraser }
        let size = Geometry.bounds(of: drawn).maxSide
        let points = drawn.reduce(0) { $0 + $1.points.count }
        if drawn.count >= 2 && size >= 40 && points >= 8 { return true }
        return drawn.count == 1 && size >= 150 && points >= 12
    }
}

public enum SmartStash {
    public struct Plan: Sendable {
        /// New or changed stash items to save.
        public var upserts: [StashItem] = []
    }

    /// Works out which stash items to add or update for one cel.
    /// A drawing that grows updates its stash item instead of making a new copy.
    public static func plan(cel: Cel, existing: [StashItem], projectID: String, frameID: String, layerID: String,
                            now: Date = Date(), name: (Int) -> String = { "Drawing \($0)" }) -> Plan {
        var plan = Plan()
        let mine = existing.filter { $0.sourceProject == projectID && $0.sourceLayer == layerID }
        var claimed = Set<String>()
        var counter = existing.count
        for group in StashDetector.clusters(cel.strokes) where StashDetector.isWorthSaving(group) {
            let ids = Set(group.map(\.id))
            // An item that already holds most of these strokes (or most of whose strokes are here) is the same thing.
            let match = mine.filter { !claimed.contains($0.id) }.max { a, b in
                overlap(Set(a.sourceStrokes), ids) < overlap(Set(b.sourceStrokes), ids)
            }
            if let m = match, overlap(Set(m.sourceStrokes), ids) >= 0.5 {
                claimed.insert(m.id)
                if Set(m.sourceStrokes) == ids && m.sourceFrame == frameID { continue }
                var updated = makeItem(group: group, cel: cel, projectID: projectID, frameID: frameID, layerID: layerID,
                                       name: m.name, now: now)
                updated.id = m.id
                updated.created = m.created
                updated.pinned = m.pinned
                updated.auto = m.auto
                plan.upserts.append(updated)
            } else {
                counter += 1
                plan.upserts.append(makeItem(group: group, cel: cel, projectID: projectID, frameID: frameID,
                                             layerID: layerID, name: name(counter), now: now))
            }
        }
        return plan
    }

    /// How much two sets of stroke ids are the same thing (0...1).
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = Double(a.intersection(b).count)
        return max(shared / Double(a.count), shared / Double(b.count))
    }

    /// A stash item from strokes, moved so its box starts at 0,0. Fills inside the box come along.
    public static func makeItem(group: [Stroke], cel: Cel, projectID: String, frameID: String, layerID: String,
                                name: String, now: Date = Date(), auto: Bool = true) -> StashItem {
        let box = Geometry.bounds(of: group.filter { $0.brush.kind != .eraser })
        let fills = cel.fills.filter { box.contains(Geometry.bounds(ofPath: $0.path).center) }
        let strokes = StrokeTransform.translate(group, dx: -box.minX, dy: -box.minY)
        let movedFills = StrokeTransform.translate(fills, dx: -box.minX, dy: -box.minY)
        var item = StashItem(name: name, auto: auto, bounds: box.xywh, strokes: strokes, fills: movedFills,
                             sourceProject: projectID, sourceFrame: frameID, sourceLayer: layerID,
                             sourceStrokes: group.map(\.id), created: now)
        item.updated = now
        return item
    }

    /// Puts a stash item into a cel with its center at `center`. Returns the new strokes.
    @discardableResult
    public static func place(_ item: StashItem, at center: Vec2, into cel: inout Cel, scale: Double = 1) -> [Stroke] {
        let w = item.width, h = item.height
        var strokes = item.strokes
        var fills = item.fills
        if scale != 1, scale > 0 {
            strokes = StrokeTransform.scale(strokes, by: scale, around: Vec2(w / 2, h / 2))
            fills = StrokeTransform.scale(fills, by: scale, around: Vec2(w / 2, h / 2))
        }
        let dx = center.x - w / 2
        let dy = center.y - h / 2
        strokes = StrokeTransform.freshIDs(StrokeTransform.translate(strokes, dx: dx, dy: dy))
        fills = StrokeTransform.freshIDs(StrokeTransform.translate(fills, dx: dx, dy: dy))
        for f in fills { cel.append(f) }
        var added: [Stroke] = []
        for s in strokes {
            cel.append(s)
            added.append(cel.strokes[cel.strokes.count - 1])
        }
        return added
    }

    /// Auto-saved items to remove so the stash doesn't grow forever (pinned and hand-saved ones stay).
    public static func itemsToPrune(_ items: [StashItem], keepAuto: Int = 80) -> [String] {
        let autos = items.filter { $0.auto && !$0.pinned }.sorted { $0.updated > $1.updated }
        guard autos.count > keepAuto else { return [] }
        return autos[keepAuto...].map(\.id)
    }
}
