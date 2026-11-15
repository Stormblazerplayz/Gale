import Foundation

/// Undo and redo by keeping copies of the whole thing before each change.
/// Projects are value types that share unchanged parts, so a copy is cheap.
public struct UndoStack<T> {
    public private(set) var past: [T] = []
    public private(set) var future: [T] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Call with the state from just before a change.
    public mutating func record(_ before: T) {
        past.append(before)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    /// Returns the state to go back to, given the state now.
    public mutating func undo(current: T) -> T? {
        guard let last = past.popLast() else { return nil }
        future.append(current)
        return last
    }

    public mutating func redo(current: T) -> T? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    public mutating func clear() {
        past.removeAll()
        future.removeAll()
    }
}
