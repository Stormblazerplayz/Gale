import Foundation
import GaleCore
import GaleFormat

/// Saved loops (walk cycles and more) and the smart stash. Shared by every project.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var loops: [LoopItem] = []
    @Published private(set) var stash: [StashItem] = []

    let root: URL
    private var loopsFolder: URL { root.appendingPathComponent("loops") }
    private var stashFolder: URL { root.appendingPathComponent("stash") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("loops"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("stash"), withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        loops = Self.readAll(LoopItem.self, in: loopsFolder).sorted { $0.created > $1.created }
        stash = Self.readAll(StashItem.self, in: stashFolder).sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }

    private static func readAll<T: Decodable>(_ type: T.Type, in folder: URL) -> [T] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? GaleIO.decode(T.self, from: data)
        }
    }

    // MARK: Loops

    func save(_ loop: LoopItem) {
        try? GaleIO.encode(loop).write(to: loopsFolder.appendingPathComponent("\(loop.id).json"), options: .atomic)
        reload()
    }

    func delete(loop: LoopItem) {
        try? FileManager.default.removeItem(at: loopsFolder.appendingPathComponent("\(loop.id).json"))
        reload()
    }

    func rename(loop: LoopItem, to name: String) {
        var l = loop
        l.name = name
        save(l)
    }

    // MARK: Stash

    func save(_ item: StashItem) {
        try? GaleIO.encode(item).write(to: stashFolder.appendingPathComponent("\(item.id).json"), options: .atomic)
    }

    func saveStash(_ items: [StashItem]) {
        guard !items.isEmpty else { return }
        for item in items { save(item) }
        // Keep the auto stash from growing forever. Pinned and hand-saved items always stay.
        let all = Self.readAll(StashItem.self, in: stashFolder)
        for id in SmartStash.itemsToPrune(all, keepAuto: 120) {
            try? FileManager.default.removeItem(at: stashFolder.appendingPathComponent("\(id).json"))
        }
        reload()
    }

    func delete(stash item: StashItem) {
        try? FileManager.default.removeItem(at: stashFolder.appendingPathComponent("\(item.id).json"))
        reload()
    }

    func togglePin(_ item: StashItem) {
        var s = item
        s.pinned.toggle()
        s.auto = s.pinned ? false : s.auto
        save(s)
        reload()
    }

    func rename(stash item: StashItem, to name: String) {
        var s = item
        s.name = name
        s.auto = false
        save(s)
        reload()
    }

    /// Looks at the cel you just changed and quietly saves the drawings in it.
    func autoStash(cel: Cel, projectID: String, frameID: String, layerID: String) {
        let existing = stash
        let plan = SmartStash.plan(cel: cel, existing: existing, projectID: projectID, frameID: frameID, layerID: layerID)
        saveStash(plan.upserts)
    }
}
