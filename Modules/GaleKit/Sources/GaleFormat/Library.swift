import Foundation

/// One frame of a saved loop: what the loop's layer shows, and for how long.
public struct LoopFrame: Codable, Hashable, Sendable {
    public var hold: Int
    public var strokes: [Stroke]
    public var fills: [Fill]

    public init(hold: Int = 1, strokes: [Stroke] = [], fills: [Fill] = []) {
        self.hold = max(1, hold)
        self.strokes = strokes
        self.fills = fills
    }

    enum CodingKeys: String, CodingKey { case hold, strokes, fills }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hold = max(1, c.value(.hold, or: 1))
        strokes = c.value(.strokes, or: [])
        fills = c.value(.fills, or: [])
    }
}

public enum LoopKind: String, Codable, CaseIterable, Sendable {
    case walk, run, idle, effect, loop

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = LoopKind(rawValue: s) ?? .loop
    }

    public var title: String {
        switch self {
        case .walk: return "Walk cycle"
        case .run: return "Run cycle"
        case .idle: return "Idle"
        case .effect: return "Effect"
        case .loop: return "Loop"
        }
    }
}

/// A saved animation loop, like a walk cycle. Lives in the library, not in a project,
/// so it can be dropped into any scene.
public struct LoopItem: Codable, Hashable, Identifiable, Sendable {
    public static let formatName = "gale-loop/1"

    public var format: String
    public var id: String
    public var name: String
    public var kind: LoopKind
    public var fps: Int
    /// Size of the canvas the loop was drawn on.
    public var width: Double
    public var height: Double
    /// How far the character moves forward in one cycle, in pixels (for walking across the screen).
    public var stride: Double
    public var frames: [LoopFrame]
    public var created: Date

    public init(id: String = GaleID.make(), name: String, kind: LoopKind, fps: Int, width: Double, height: Double,
                stride: Double = 0, frames: [LoopFrame], created: Date = Date()) {
        format = LoopItem.formatName
        self.id = id
        self.name = name
        self.kind = kind
        self.fps = fps
        self.width = width
        self.height = height
        self.stride = stride
        self.frames = frames
        self.created = created
    }

    enum CodingKeys: String, CodingKey { case format, id, name, kind, fps, width, height, stride, frames, created }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, or: LoopItem.formatName)
        id = c.value(.id, or: GaleID.make())
        name = c.value(.name, or: "Loop")
        kind = c.value(.kind, or: .loop)
        fps = min(60, max(1, c.value(.fps, or: 12)))
        width = c.value(.width, or: 1920)
        height = c.value(.height, or: 1080)
        stride = c.value(.stride, or: 0)
        frames = c.value(.frames, or: [])
        created = c.value(.created, or: Date())
    }

    public var ticks: Int { frames.reduce(0) { $0 + $1.hold } }
}

/// Something you drew that Gale saved by itself (or you saved) so you can drag it into any frame later.
public struct StashItem: Codable, Hashable, Identifiable, Sendable {
    public static let formatName = "gale-stash/1"

    public var format: String
    public var id: String
    public var name: String
    public var created: Date
    public var updated: Date
    /// Saved automatically (true) or on purpose (false). Auto items can be cleaned up; pinned ones never are.
    public var auto: Bool
    public var pinned: Bool
    /// Where it was drawn: x, y, width, height on the original canvas.
    public var bounds: [Double]
    /// Points are relative to the top-left of `bounds`.
    public var strokes: [Stroke]
    public var fills: [Fill]
    /// Where it came from, so a drawing that grows updates its stash item instead of making a copy.
    public var sourceProject: String
    public var sourceFrame: String
    public var sourceLayer: String
    public var sourceStrokes: [String]

    public init(id: String = GaleID.make(), name: String, auto: Bool, pinned: Bool = false, bounds: [Double],
                strokes: [Stroke], fills: [Fill] = [], sourceProject: String = "", sourceFrame: String = "",
                sourceLayer: String = "", sourceStrokes: [String] = [], created: Date = Date()) {
        format = StashItem.formatName
        self.id = id
        self.name = name
        self.created = created
        updated = created
        self.auto = auto
        self.pinned = pinned
        self.bounds = bounds
        self.strokes = strokes
        self.fills = fills
        self.sourceProject = sourceProject
        self.sourceFrame = sourceFrame
        self.sourceLayer = sourceLayer
        self.sourceStrokes = sourceStrokes
    }

    enum CodingKeys: String, CodingKey {
        case format, id, name, created, updated, auto, pinned, bounds, strokes, fills
        case sourceProject, sourceFrame, sourceLayer, sourceStrokes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, or: StashItem.formatName)
        id = c.value(.id, or: GaleID.make())
        name = c.value(.name, or: "Drawing")
        created = c.value(.created, or: Date())
        updated = c.value(.updated, or: created)
        auto = c.value(.auto, or: true)
        pinned = c.value(.pinned, or: false)
        bounds = c.value(.bounds, or: [0, 0, 0, 0])
        strokes = c.value(.strokes, or: [])
        fills = c.value(.fills, or: [])
        sourceProject = c.value(.sourceProject, or: "")
        sourceFrame = c.value(.sourceFrame, or: "")
        sourceLayer = c.value(.sourceLayer, or: "")
        sourceStrokes = c.value(.sourceStrokes, or: [])
    }

    public var width: Double { bounds.count == 4 ? bounds[2] : 0 }
    public var height: Double { bounds.count == 4 ? bounds[3] : 0 }
}
