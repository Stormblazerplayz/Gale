import Foundation
import SwiftUI
import GaleFormat

/// The list of projects saved on this device (Documents/Projects/*.gale).
@MainActor
final class ProjectLibrary: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: String
        let url: URL
        var name: String
        var modified: Date
        var width: Double
        var height: Double
        var coverURL: URL { url.appendingPathComponent(GaleIO.coverFile) }
    }

    /// Just the parts of project.json the home screen needs, so opening the list stays fast.
    private struct Header: Decodable {
        var id: String?
        var name: String?
        var modified: Date?
        var canvas: GaleCanvas?
    }

    @Published private(set) var entries: [Entry] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var list: [Entry] = []
        for url in folders where url.pathExtension == GaleIO.projectExtension {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(GaleIO.projectFile)),
                  let header = try? GaleIO.decode(Header.self, from: data) else { continue }
            list.append(Entry(id: header.id ?? url.lastPathComponent,
                              url: url,
                              name: header.name ?? url.deletingPathExtension().lastPathComponent,
                              modified: header.modified ?? Date.distantPast,
                              width: header.canvas?.width ?? 1920,
                              height: header.canvas?.height ?? 1080))
        }
        entries = list.sorted { $0.modified > $1.modified }
    }

    func url(forProjectID id: String) -> URL? {
        entries.first { $0.id == id }?.url
    }

    /// A new folder name that isn't taken yet.
    func freshFolder(for name: String) -> URL {
        let base = GaleIO.safeName(name)
        var url = root.appendingPathComponent(base).appendingPathExtension(GaleIO.projectExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base) \(n)").appendingPathExtension(GaleIO.projectExtension)
            n += 1
        }
        return url
    }

    @discardableResult
    func create(name: String, canvas: GaleCanvas, fps: Int) throws -> URL {
        let project = GaleProject(name: name, canvas: canvas, fps: fps)
        let url = freshFolder(for: name)
        try GaleIO.writeProject(project, to: url)
        reload()
        return url
    }

    /// Saves a project that came from somewhere else (like another device) as a new local project.
    @discardableResult
    func importProject(_ project: GaleProject) throws -> URL {
        if let existing = url(forProjectID: project.id) {
            try GaleIO.writeProject(project, to: existing)
            reload()
            return existing
        }
        let url = freshFolder(for: project.name)
        try GaleIO.writeProject(project, to: url)
        reload()
        return url
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        reload()
    }

    func duplicate(_ entry: Entry) {
        guard var project = try? GaleIO.readProject(at: entry.url) else { return }
        project.id = GaleID.make()
        project.name = project.name + " copy"
        project.created = Date()
        project.modified = Date()
        let url = freshFolder(for: project.name)
        do {
            try FileManager.default.copyItem(at: entry.url, to: url)
            try GaleIO.writeProject(project, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    func rename(_ entry: Entry, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var project = try? GaleIO.readProject(at: entry.url) else { return }
        project.name = clean
        project.modified = Date()
        try? GaleIO.writeProject(project, to: entry.url)
        reload()
    }
}
