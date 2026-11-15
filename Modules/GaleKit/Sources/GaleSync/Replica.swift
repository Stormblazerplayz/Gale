import Foundation
import GaleFormat

/// A copy of one project's objects that merges ops: for each (object, field) the op with the biggest time wins.
/// Getting ops in any order, or twice, ends in the same place.
public struct SyncReplica: Sendable {
    public private(set) var objects: [String: SyncObject] = [:]
    /// Winning timestamp per "object\u{1}field".
    public private(set) var stamps: [String: String] = [:]
    public let projectID: String

    public init(projectID: String) {
        self.projectID = projectID
    }

    /// Starts from a whole project, as if all of it was written at time `t`.
    public init(project: GaleProject, stamp: String) {
        projectID = project.id
        objects = SyncObjects.flatten(project)
        for (id, o) in objects {
            for k in o.keys { stamps[id + "\u{1}" + k] = stamp }
        }
    }

    /// Merges ops. Returns the ones that won (changed something).
    @discardableResult
    public mutating func apply(_ ops: [SyncOp]) -> [SyncOp] {
        var won: [SyncOp] = []
        for op in ops {
            let key = op.o + "\u{1}" + op.k
            if let have = stamps[key], have >= op.t { continue }
            stamps[key] = op.t
            objects[op.o, default: [:]][op.k] = op.v
            won.append(op)
        }
        return won
    }

    public var project: GaleProject? { SyncObjects.build(objects, projectID: projectID) }

    /// Every winning value as an op (to send a whole project to a new device).
    public var allOps: [SyncOp] {
        var out: [SyncOp] = []
        for (id, o) in objects {
            for (k, v) in o {
                let t = stamps[id + "\u{1}" + k] ?? HybridClock.format(ms: 0, counter: 0, actor: "device")
                let actor = HybridClock.parse(t)?.2 ?? "device"
                out.append(SyncOp(t: t, a: actor, o: id, k: k, v: v))
            }
        }
        return out.sorted { $0.t < $1.t }
    }
}
