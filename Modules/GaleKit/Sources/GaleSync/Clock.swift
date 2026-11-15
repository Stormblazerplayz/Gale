import Foundation

/// Hybrid logical clock: "<13-digit ms>:<5-digit counter>:<actor>". Later edits always get bigger strings.
public struct HybridClock: Sendable {
    public let actor: String
    public private(set) var ms: Int64 = 0
    public private(set) var counter: Int = 0

    public init(actor: String) {
        self.actor = HybridClock.cleanActor(actor)
    }

    public static func cleanActor(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let c = String(s.filter { allowed.contains($0) }.prefix(40))
        return c.isEmpty ? "device" : c
    }

    /// A timestamp for a new local edit.
    public mutating func tick(now: Date = Date()) -> String {
        let wall = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        if wall > ms {
            ms = wall
            counter = 0
        } else {
            counter += 1
            if counter > 99_999 {
                ms += 1
                counter = 0
            }
        }
        return HybridClock.format(ms: ms, counter: counter, actor: actor)
    }

    /// Moves the clock past a timestamp we received, so our next edit wins over it.
    public mutating func observe(_ t: String) {
        guard let (m, c, _) = HybridClock.parse(t) else { return }
        if m > ms || (m == ms && c > counter) {
            ms = m
            counter = c
        }
    }

    public static func format(ms: Int64, counter: Int, actor: String) -> String {
        let m = String(max(0, min(ms, 9_999_999_999_999)))
        let c = String(max(0, min(counter, 99_999)))
        return String(repeating: "0", count: 13 - m.count) + m + ":" + String(repeating: "0", count: 5 - c.count) + c + ":" + actor
    }

    public static func parse(_ t: String) -> (Int64, Int, String)? {
        let parts = t.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 13, parts[1].count == 5,
              let m = Int64(parts[0]), let c = Int(parts[1]) else { return nil }
        return (m, c, String(parts[2]))
    }
}
