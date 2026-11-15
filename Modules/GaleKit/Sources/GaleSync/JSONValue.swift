import Foundation

/// Any JSON value. Ops carry field values as JSON so every device can read them.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n.isFinite ? n : 0) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Turns any Encodable (a brush, a list of numbers...) into a JSONValue.
    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode([value]),
              let arr = try? JSONDecoder().decode([JSONValue].self, from: data), let first = arr.first else { return .null }
        return first
    }

    /// Reads a JSONValue back into a type, or nil if it doesn't fit.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode([self]) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self) {
                let f = ISO8601DateFormatter()
                if let date = f.date(from: s) { return date }
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = f.date(from: s) { return date }
            }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a date")
        }
        return (try? decoder.decode([T].self, from: data))?.first
    }
}
