import Foundation

/// The desktop hub's address from its pairing QR code: gale://pair?v=1&host=&port=&code=&name=&id=
public struct PairingInfo: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var code: String
    public var name: String
    public var serverID: String

    public init(host: String, port: Int = SyncProtocol.port, code: String, name: String, serverID: String) {
        self.host = host
        self.port = port
        self.code = code
        self.name = name
        self.serverID = serverID
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "gale", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var q: [String: String] = [:]
        for i in items { q[i.name] = i.value ?? "" }
        guard let host = q["host"], !host.isEmpty, let code = q["code"], code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let port = Int(q["port"] ?? "") ?? SyncProtocol.port
        guard (1...65535).contains(port) else { return nil }
        self.init(host: host, port: port, code: code, name: q["name"] ?? "Computer", serverID: q["id"] ?? "")
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    public var url: URL? {
        var c = URLComponents()
        c.scheme = "gale"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "host", value: host),
                        URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "code", value: code),
                        URLQueryItem(name: "name", value: name), URLQueryItem(name: "id", value: serverID)]
        return c.url
    }
}

public enum SyncProtocol {
    public static let version = 1
    public static let port = 47820
    public static let bonjourType = "_gale._tcp"
}

/// A project as the hub lists it.
public struct HubProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var modified: JSONValue?
    public var seq: Int
}

/// Messages on the sync WebSocket. Unknown types decode as `.unknown` and are ignored.
public enum SyncMessage: Sendable, Equatable {
    case hello(deviceId: String, deviceName: String, since: [String: Int])
    case welcome(serverId: String, serverName: String, projects: [HubProject])
    case subscribe(p: String, since: Int)
    case push(p: String, ops: [SyncOp], ref: String)
    case ack(ref: String, seq: Int)
    case ops(p: String, ops: [SyncOp], seq: Int)
    case projects([HubProject])
    case live(p: String, frame: String, layer: String, stroke: JSONValue, done: Bool)
    case presence(deviceId: String, deviceName: String, p: String, frame: String)
    case ping
    case pong
    case unknown(String)

    public func encoded() throws -> Data {
        var o: [String: JSONValue] = [:]
        func ops(_ list: [SyncOp]) -> JSONValue { JSONValue.from(list) }
        switch self {
        case .hello(let d, let n, let since):
            o = ["type": .string("hello"), "deviceId": .string(d), "deviceName": .string(n),
                 "since": .object(since.mapValues { .number(Double($0)) })]
        case .welcome(let s, let n, let p):
            o = ["type": .string("welcome"), "serverId": .string(s), "serverName": .string(n), "projects": JSONValue.from(p)]
        case .subscribe(let p, let since):
            o = ["type": .string("subscribe"), "p": .string(p), "since": .number(Double(since))]
        case .push(let p, let list, let ref):
            o = ["type": .string("push"), "p": .string(p), "ops": ops(list), "ref": .string(ref)]
        case .ack(let ref, let seq):
            o = ["type": .string("ack"), "ref": .string(ref), "seq": .number(Double(seq))]
        case .ops(let p, let list, let seq):
            o = ["type": .string("ops"), "p": .string(p), "ops": ops(list), "seq": .number(Double(seq))]
        case .projects(let p):
            o = ["type": .string("projects"), "projects": JSONValue.from(p)]
        case .live(let p, let f, let l, let s, let done):
            o = ["type": .string("live"), "p": .string(p), "frame": .string(f), "layer": .string(l), "stroke": s, "done": .bool(done)]
        case .presence(let d, let n, let p, let f):
            o = ["type": .string("presence"), "deviceId": .string(d), "deviceName": .string(n), "p": .string(p), "frame": .string(f)]
        case .ping: o = ["type": .string("ping")]
        case .pong: o = ["type": .string("pong")]
        case .unknown(let t): o = ["type": .string(t)]
        }
        return try JSONEncoder().encode(JSONValue.object(o))
    }

    public static func decode(_ data: Data) -> SyncMessage? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data), let o = v.object,
              let type = o["type"]?.string else { return nil }
        func s(_ k: String) -> String { o[k]?.string ?? "" }
        func i(_ k: String) -> Int { Int(o[k]?.number ?? 0) }
        func list(_ k: String) -> [SyncOp] { o[k]?.decode([SyncOp].self) ?? [] }
        func projects(_ k: String) -> [HubProject] { o[k]?.decode([HubProject].self) ?? [] }
        switch type {
        case "hello":
            var since: [String: Int] = [:]
            for (k, v) in o["since"]?.object ?? [:] { since[k] = Int(v.number ?? 0) }
            return .hello(deviceId: s("deviceId"), deviceName: s("deviceName"), since: since)
        case "welcome": return .welcome(serverId: s("serverId"), serverName: s("serverName"), projects: projects("projects"))
        case "subscribe": return .subscribe(p: s("p"), since: i("since"))
        case "push": return .push(p: s("p"), ops: list("ops"), ref: s("ref"))
        case "ack": return .ack(ref: s("ref"), seq: i("seq"))
        case "ops": return .ops(p: s("p"), ops: list("ops"), seq: i("seq"))
        case "projects": return .projects(projects("projects"))
        case "live": return .live(p: s("p"), frame: s("frame"), layer: s("layer"), stroke: o["stroke"] ?? .null, done: o["done"]?.bool ?? false)
        case "presence": return .presence(deviceId: s("deviceId"), deviceName: s("deviceName"), p: s("p"), frame: s("frame"))
        case "ping": return .ping
        case "pong": return .pong
        default: return .unknown(type)
        }
    }
}
