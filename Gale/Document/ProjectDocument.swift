import AVFoundation
import Combine
import CryptoKit
import Foundation
import GaleCore
import GaleFormat
import GalePixel
import UIKit

/// One open project. Every change goes through `edit`, which handles undo, saving and live sync.
@MainActor
final class ProjectDocument: ObservableObject {
    let folder: URL
    @Published private(set) var project: GaleProject
    @Published var currentFrame: Int = 0
    @Published var currentLayerID: String
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var lastSaved: Date?

    private var undoStack = UndoStack<GaleProject>(limit: 80)
    private var saveTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?

    /// Called after every local change with the project before and after (live sync listens here).
    var onLocalChange: ((GaleProject, GaleProject) -> Void)?

    init(folder: URL) throws {
        self.folder = folder
        var p = try GaleIO.readProject(at: folder)
        p.normalize()
        project = p
        currentLayerID = p.layers.last?.id ?? ""
    }

    var currentLayer: Layer? { project.layers.first { $0.id == currentLayerID } }
    var frame: Frame { project.frames[min(currentFrame, project.frames.count - 1)] }

    // MARK: Changes

    /// Makes a change. `undoable` false is for things like dragging a slider, where only the start should be undoable.
    func edit(undoable: Bool = true, _ change: (inout GaleProject) -> Void) {
        let before = project
        var after = project
        change(&after)
        guard after != before else { return }
        after.normalize()
        after.modified = Date()
        if undoable { undoStack.record(before) }
        apply(after)
        onLocalChange?(before, after)
        scheduleSave()
    }

    /// Records an undo point now (call when a slider drag starts, then use `edit(undoable: false)`).
    func checkpoint() {
        undoStack.record(project)
        refreshUndoFlags()
    }

    /// A change that came from another device. Not undoable here and not sent back out.
    func applyRemote(_ remote: GaleProject) {
        guard remote != project else { return }
        apply(remote)
        scheduleSave()
    }

    func undo() {
        guard let back = undoStack.undo(current: project) else { return }
        let before = project
        apply(back)
        onLocalChange?(before, back)
        scheduleSave()
    }

    func redo() {
        guard let next = undoStack.redo(current: project) else { return }
        let before = project
        apply(next)
        onLocalChange?(before, next)
        scheduleSave()
    }

    private func apply(_ p: GaleProject) {
        project = p
        if currentFrame >= p.frames.count { currentFrame = max(0, p.frames.count - 1) }
        if !p.layers.contains(where: { $0.id == currentLayerID }) { currentLayerID = p.layers.last?.id ?? "" }
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = undoStack.canUndo
        canRedo = undoStack.canRedo
    }

    // MARK: Handy edits

    /// Adds a stroke to the current frame and layer.
    func addStroke(_ stroke: Stroke) {
        let frameID = frame.id, layerID = currentLayerID
        edit { p in
            guard let fi = p.frameIndex(frameID) else { return }
            var cel = p.frames[fi].cel(layerID)
            cel.append(stroke)
            p.frames[fi].cels[layerID] = cel
        }
    }

    func addFill(_ fill: Fill) {
        let frameID = frame.id, layerID = currentLayerID
        edit { p in
            guard let fi = p.frameIndex(frameID) else { return }
            var cel = p.frames[fi].cel(layerID)
            cel.append(fill)
            p.frames[fi].cels[layerID] = cel
        }
    }

    func updateCurrentCel(_ change: (inout Cel) -> Void) {
        let frameID = frame.id, layerID = currentLayerID
        edit { p in
            guard let fi = p.frameIndex(frameID) else { return }
            var cel = p.frames[fi].cel(layerID)
            change(&cel)
            p.frames[fi].cels[layerID] = cel
        }
    }

    /// New blank frame after the current one (or a copy of it).
    func addFrame(copyCurrent: Bool = false) {
        let source = frame
        var newIndex = currentFrame
        edit { p in
            var f = Frame()
            if copyCurrent {
                f.hold = source.hold
                for (layer, cel) in source.cels {
                    f.cels[layer] = Cel(strokes: StrokeTransform.freshIDs(cel.strokes), fills: StrokeTransform.freshIDs(cel.fills))
                }
            }
            newIndex = p.insertFrame(f, after: currentFrame)
        }
        currentFrame = newIndex
    }

    func deleteFrame(at index: Int) {
        guard project.frames.count > 1, project.frames.indices.contains(index) else {
            // The last frame can't go, so clear it instead.
            edit { p in p.frames[0].cels = [:] }
            return
        }
        edit { p in p.frames.remove(at: index) }
    }

    // MARK: Saving

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let p = project
        let folder = folder
        Task.detached(priority: .utility) {
            try? GaleIO.writeProject(p, to: folder)
            if let story = p.pixel {
                // Pixel stories make their cover from the pixel art itself.
                if let png = story.coverImage().pngData() {
                    try? png.write(to: folder.appendingPathComponent(GaleIO.coverFile), options: .atomic)
                }
            } else if let cover = FrameRenderer.image(p, frameIndex: 0, scale: CGFloat(min(1, 480 / max(p.canvas.width, p.canvas.height)))),
               let png = UIImage(cgImage: cover).pngData() {
                try? png.write(to: folder.appendingPathComponent(GaleIO.coverFile), options: .atomic)
            }
        }
        lastSaved = Date()
    }

    // MARK: Media

    func mediaURL(_ item: MediaItem) -> URL { GaleIO.mediaURL(item, in: folder) }

    func media(_ id: String) -> MediaItem? { project.media.first { $0.id == id } }

    /// Copies a video, audio or picture file into the project and adds it to the media list.
    func importMedia(from source: URL, kind: MediaKind, name: String? = nil) async throws -> MediaItem {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? (kind == .audio ? "m4a" : kind == .video ? "mov" : "png") : source.pathExtension
        let id = GaleID.make()
        let fileName = "\(id).\(ext.lowercased())"
        let mediaFolder = folder.appendingPathComponent(GaleIO.mediaFolder)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let dest = mediaFolder.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: dest)
        let hash = try await Task.detached { try ProjectDocument.sha256(of: dest) }.value
        var duration = 0.0
        if kind != .image {
            let asset = AVURLAsset(url: dest)
            if let d = try? await asset.load(.duration) { duration = max(0, d.seconds.isFinite ? d.seconds : 0) }
        }
        let item = MediaItem(id: id, file: fileName, kind: kind,
                             name: name ?? source.deletingPathExtension().lastPathComponent,
                             duration: duration, sha256: hash)
        edit { p in p.media.append(item) }
        return item
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
