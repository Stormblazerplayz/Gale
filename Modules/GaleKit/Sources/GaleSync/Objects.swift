import Foundation
import GaleFormat

/// One change to one field of one object.
public struct SyncOp: Codable, Hashable, Sendable {
    /// Clock timestamp. Bigger wins.
    public var t: String
    /// Device that made it.
    public var a: String
    /// Object id.
    public var o: String
    /// Field name.
    public var k: String
    /// New value.
    public var v: JSONValue

    public init(t: String, a: String, o: String, k: String, v: JSONValue) {
        self.t = t
        self.a = a
        self.o = o
        self.k = k
        self.v = v
    }
}

public typealias SyncObject = [String: JSONValue]

/// Turns a project into the flat objects used for sync and back (see docs/format.md section 4).
public enum SyncObjects {
    public static let typeKey = "$type"
    public static let deletedKey = "$del"

    /// The project as flat objects, keyed by object id.
    public static func flatten(_ p: GaleProject) -> [String: SyncObject] {
        var out: [String: SyncObject] = [:]
        out[p.id] = [
            typeKey: .string("project"),
            "name": .string(p.name),
            "width": .number(p.canvas.width),
            "height": .number(p.canvas.height),
            "background": .string(p.canvas.background.hex),
            "fps": .number(Double(p.fps)),
            "motionBlur": JSONValue.from(p.motionBlur),
            "overlay": .bool(p.movie.overlay),
            "created": JSONValue.from(p.created),
        ]
        for l in p.layers {
            out[l.id] = [typeKey: .string("layer"), "key": .string(l.key), "name": .string(l.name),
                         "visible": .bool(l.visible), "locked": .bool(l.locked), "opacity": .number(l.opacity)]
        }
        for f in p.frames {
            out[f.id] = [typeKey: .string("frame"), "key": .string(f.key), "hold": .number(Double(f.hold))]
            for (layerID, cel) in f.cels {
                for s in cel.strokes {
                    out[s.id] = [typeKey: .string("stroke"), "frame": .string(f.id), "layer": .string(layerID),
                                 "key": .string(s.key), "brush": JSONValue.from(s.brush),
                                 "pts": .array(Stroke.pack(s.rounded.points).map { .number($0) })]
                }
                for fill in cel.fills {
                    out[fill.id] = [typeKey: .string("fill"), "frame": .string(f.id), "layer": .string(layerID),
                                    "key": .string(fill.key), "color": .string(fill.color.hex),
                                    "path": .array(fill.path.map { .number($0) })]
                }
            }
        }
        for h in p.hair {
            out[h.id] = [typeKey: .string("hair"), "layer": .string(h.layer),
                         "polygon": .array(h.polygon.map { .number($0) }), "root": .array(h.root.map { .number($0) }),
                         "stiffness": .number(h.stiffness), "wind": .number(h.wind), "gust": .number(h.gust),
                         "speed": .number(h.speed), "on": .bool(h.on)]
        }
        for t in p.movie.tracks {
            out[t.id] = [typeKey: .string("track"), "key": .string(t.key), "kind": .string(t.kind.rawValue),
                         "name": .string(t.name), "muted": .bool(t.muted), "volume": .number(t.volume)]
        }
        for c in p.movie.clips {
            out[c.id] = [typeKey: .string("clip"), "track": .string(c.track), "media": .string(c.media),
                         "start": .number(c.start), "in": .number(c.inPoint), "duration": .number(c.duration),
                         "speed": .number(c.speed), "volume": .number(c.volume), "fadeIn": .number(c.fadeIn),
                         "fadeOut": .number(c.fadeOut)]
        }
        for m in p.media {
            out[m.id] = [typeKey: .string("media"), "file": .string(m.file), "kind": .string(m.kind.rawValue),
                         "name": .string(m.name), "duration": .number(m.duration), "sha256": .string(m.sha256)]
        }
        return out
    }

    /// Builds a project from flat objects. `projectID` picks the project object.
    public static func build(_ objects: [String: SyncObject], projectID: String) -> GaleProject? {
        func alive(_ o: SyncObject) -> Bool { o[deletedKey]?.bool != true }
        func type(_ o: SyncObject) -> String? { o[typeKey]?.string }
        guard let po = objects[projectID], alive(po), type(po) == "project" else { return nil }

        // Build JSON in project.json shape and let the tolerant decoder fill in anything missing.
        var layers: [JSONValue] = []
        var frames: [String: [String: JSONValue]] = [:]
        var hair: [JSONValue] = []
        var tracks: [JSONValue] = []
        var clips: [JSONValue] = []
        var media: [JSONValue] = []
        var cels: [String: [String: (strokes: [JSONValue], fills: [JSONValue])]] = [:]

        for (id, o) in objects where alive(o) {
            var withID = o
            withID["id"] = .string(id)
            withID[typeKey] = nil
            withID[deletedKey] = nil
            switch type(o) {
            case "layer": layers.append(.object(withID))
            case "frame": frames[id] = withID
            case "hair": hair.append(.object(withID))
            case "track": tracks.append(.object(withID))
            case "clip": clips.append(.object(withID))
            case "media": media.append(.object(withID))
            default: break
            }
        }
        let layerIDs = Set(layers.compactMap { $0.object?["id"]?.string })
        for (id, o) in objects where alive(o) {
            let t = type(o)
            guard t == "stroke" || t == "fill",
                  let f = o["frame"]?.string, let l = o["layer"]?.string,
                  frames[f] != nil, layerIDs.contains(l) else { continue }
            var item = o
            item["id"] = .string(id)
            item[typeKey] = nil
            item[deletedKey] = nil
            item["frame"] = nil
            item["layer"] = nil
            var entry = cels[f]?[l] ?? (strokes: [], fills: [])
            if t == "stroke" { entry.strokes.append(.object(item)) } else { entry.fills.append(.object(item)) }
            cels[f, default: [:]][l] = entry
        }
        var frameList: [JSONValue] = []
        for (id, var f) in frames {
            var celMap: [String: JSONValue] = [:]
            for (l, entry) in cels[id] ?? [:] {
                celMap[l] = .object(["strokes": .array(entry.strokes), "fills": .array(entry.fills)])
            }
            f["cels"] = .object(celMap)
            frameList.append(.object(f))
        }
        let json: [String: JSONValue] = [
            "format": .string(GaleProject.formatName),
            "id": .string(projectID),
            "name": po["name"] ?? .string("Untitled"),
            "created": po["created"] ?? .null,
            "canvas": .object(["width": po["width"] ?? .number(1920), "height": po["height"] ?? .number(1080),
                               "background": po["background"] ?? .string("#FFFFFFFF")]),
            "fps": po["fps"] ?? .number(12),
            "motionBlur": po["motionBlur"] ?? .null,
            "layers": .array(layers),
            "frames": .array(frameList),
            "hair": .array(hair),
            "movie": .object(["overlay": po["overlay"] ?? .bool(false), "tracks": .array(tracks), "clips": .array(clips)]),
            "media": .array(media),
        ]
        guard var p = JSONValue.object(json.filter { $0.value != .null }).decode(GaleProject.self) else { return nil }
        p.normalize()
        return p
    }

    /// The ops that turn `old` into `new`. A new object sends every field, a removed one sends `$del`.
    public static func diff(_ old: [String: SyncObject], _ new: [String: SyncObject], clock: inout HybridClock,
                            now: Date = Date()) -> [SyncOp] {
        var ops: [SyncOp] = []
        func op(_ o: String, _ k: String, _ v: JSONValue) {
            ops.append(SyncOp(t: clock.tick(now: now), a: clock.actor, o: o, k: k, v: v))
        }
        for id in new.keys.sorted() {
            guard let n = new[id] else { continue }
            let o = old[id]
            let wasDeleted = o?[deletedKey]?.bool == true
            if o == nil || wasDeleted {
                // New (or brought back): type first so readers know what it is.
                if let t = n[typeKey] { op(id, typeKey, t) }
                if wasDeleted { op(id, deletedKey, .bool(false)) }
                for k in n.keys.sorted() where k != typeKey { op(id, k, n[k]!) }
            } else if let o {
                for k in n.keys.sorted() where o[k] != n[k] { op(id, k, n[k]!) }
            }
        }
        for id in old.keys.sorted() where new[id] == nil && old[id]?[deletedKey]?.bool != true {
            op(id, deletedKey, .bool(true))
        }
        return ops
    }
}
