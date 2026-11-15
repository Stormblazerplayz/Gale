import AVFoundation
import CoreTransferable
import Foundation
import GaleFormat
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A movie picked from Photos, copied to a temporary file we own.
struct StudioPickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gale-pick-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = received.file.lastPathComponent.isEmpty ? "Video.mov" : received.file.lastPathComponent
            let dest = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return StudioPickedMovie(url: dest)
        }
    }
}

/// Every change the studio makes to the movie. All go through `document.edit`, so they can be undone.
@MainActor
enum StudioActions {
    // MARK: Adding

    /// How long a new clip of this media should be (seconds of source).
    static func naturalLength(of media: MediaItem) -> Double {
        switch media.kind {
        case .image: return StudioMath.defaultPictureLength
        case .video, .audio: return media.duration
        }
    }

    /// Puts a media item on the timeline at `time` on a track with room (a new track if none has room).
    /// Returns the new clip.
    @discardableResult
    static func addClip(_ document: ProjectDocument, media: MediaItem, at time: Double) -> Clip? {
        let length = naturalLength(of: media)
        guard length > 0.01 else { return nil }
        let kind: TrackKind = media.kind == .audio ? .audio : .video
        return place(document, media: media.id, kind: kind, length: length, at: time)
    }

    /// Puts the drawing itself on a video track as a clip.
    @discardableResult
    static func addAnimation(_ document: ProjectDocument, at time: Double) -> Clip? {
        let length = StudioMath.animationLength(document.project)
        return place(document, media: Clip.animation, kind: .video, length: length, at: time)
    }

    private static func place(_ document: ProjectDocument, media: String, kind: TrackKind, length: Double, at time: Double) -> Clip? {
        var made: Clip?
        let start = max(0, time)
        document.edit { p in
            let trackID: String
            if let t = StudioMath.trackWithRoom(kind: kind, start: start, length: length, in: p.movie) {
                trackID = t.id
            } else {
                trackID = p.addTrack(kind: kind, name: StudioMath.newTrackName(kind: kind, in: p.movie)).id
            }
            let clip = Clip(track: trackID, media: media, start: start, inPoint: 0, duration: length)
            p.movie.clips.append(clip)
            made = clip
        }
        return made
    }

    /// Adds a sound you recorded at `start`. `skip` seconds at the front are cut off
    /// (the time the microphone and speaker take, so it lines up with the video).
    @discardableResult
    static func addRecording(_ document: ProjectDocument, media: MediaItem, at start: Double, skip: Double) -> Clip? {
        let total = media.duration
        let cut = min(max(0, skip), max(0, total - StudioMath.minClipLength))
        let length = total - cut
        guard length > 0.01 else { return nil }
        var made: Clip?
        document.edit { p in
            let trackID: String
            if let t = StudioMath.trackWithRoom(kind: .audio, start: start, length: length, in: p.movie) {
                trackID = t.id
            } else {
                trackID = p.addTrack(kind: .audio, name: StudioMath.newTrackName(kind: .audio, in: p.movie)).id
            }
            let clip = Clip(track: trackID, media: media.id, start: max(0, start), inPoint: cut, duration: length)
            p.movie.clips.append(clip)
            made = clip
        }
        return made
    }

    /// What kind of media a file is, from its name. nil = Gale can't use it.
    static func kind(of url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    /// Copies a file into the project and puts it on the timeline. Returns the new clip.
    static func importFile(_ document: ProjectDocument, url: URL, kind: MediaKind, name: String?, at time: Double) async throws -> Clip? {
        var media = try await document.importMedia(from: url, kind: kind, name: name)
        if media.kind == .video {
            // A "video" with no picture (like some .mp4 songs) goes on a sound track.
            let asset = AVURLAsset(url: document.mediaURL(media))
            let pictures = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let sounds = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if pictures.isEmpty && !sounds.isEmpty {
                let id = media.id
                document.edit { p in
                    if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].kind = .audio }
                }
                media.kind = .audio
            }
        }
        if media.kind != .image && media.duration <= 0.01 {
            throw StudioError.message("That file has no video or sound in it.")
        }
        return addClip(document, media: media, at: time)
    }

    /// Brings in things picked in Photos, one after another from `time`.
    /// Returns how many could not be added.
    static func importPhotos(_ document: ProjectDocument, items: [PhotosPickerItem], at time: Double) async -> (added: Int, failed: Int) {
        var t = time
        var added = 0, failed = 0
        for item in items {
            do {
                let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }
                var clip: Clip?
                if isMovie {
                    guard let movie = try await item.loadTransferable(type: StudioPickedMovie.self) else { failed += 1; continue }
                    defer { try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent()) }
                    clip = try await importFile(document, url: movie.url, kind: .video, name: nil, at: t)
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else { failed += 1; continue }
                    let ext = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension ?? "jpg"
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gale-pick-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let file = folder.appendingPathComponent("Picture.\(ext)")
                    try data.write(to: file)
                    clip = try await importFile(document, url: file, kind: .image, name: "Picture", at: t)
                }
                if let clip {
                    added += 1
                    t = clip.end
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }
        return (added, failed)
    }

    // MARK: Clip edits

    static func clip(_ document: ProjectDocument, _ id: String) -> Clip? {
        document.project.movie.clips.first { $0.id == id }
    }

    /// Changes one clip. `undoable` false is for slider drags (call `document.checkpoint()` when the drag starts).
    static func updateClip(_ document: ProjectDocument, _ id: String, undoable: Bool = true, _ change: @escaping (inout Clip) -> Void) {
        document.edit(undoable: undoable) { p in
            guard let i = p.movie.clips.firstIndex(where: { $0.id == id }) else { return }
            change(&p.movie.clips[i])
        }
    }

    /// Cuts the clip at the playhead. Returns the id of the new right half.
    @discardableResult
    static func split(_ document: ProjectDocument, _ id: String, at time: Double) -> String? {
        guard let c = clip(document, id), let (left, right) = StudioMath.split(c, at: time, newID: GaleID.make()) else { return nil }
        document.edit { p in
            guard let i = p.movie.clips.firstIndex(where: { $0.id == id }) else { return }
            p.movie.clips[i] = left
            p.movie.clips.append(right)
        }
        return right.id
    }

    /// A copy right after the clip (or the next free spot on its track). Returns the copy's id.
    @discardableResult
    static func duplicate(_ document: ProjectDocument, _ id: String) -> String? {
        guard let c = clip(document, id) else { return nil }
        var copy = c
        copy.id = GaleID.make()
        let occupied = StudioMath.occupied(onTrack: c.track, in: document.project.movie)
        copy.start = StudioMath.freeStart(desired: c.end, length: c.length, occupied: occupied)
        document.edit { p in p.movie.clips.append(copy) }
        return copy.id
    }

    static func delete(_ document: ProjectDocument, _ id: String) {
        document.edit { p in p.movie.clips.removeAll { $0.id == id } }
    }

    // MARK: Tracks

    @discardableResult
    static func addTrack(_ document: ProjectDocument, kind: TrackKind) -> String? {
        var made: String?
        document.edit { p in
            made = p.addTrack(kind: kind, name: StudioMath.newTrackName(kind: kind, in: p.movie)).id
        }
        return made
    }

    /// Removes a track and every clip on it.
    static func deleteTrack(_ document: ProjectDocument, _ id: String) {
        document.edit { p in
            p.movie.tracks.removeAll { $0.id == id }
            p.movie.clips.removeAll { $0.track == id }
        }
    }

    static func updateTrack(_ document: ProjectDocument, _ id: String, undoable: Bool = true, _ change: @escaping (inout Track) -> Void) {
        document.edit(undoable: undoable) { p in
            guard let i = p.movie.tracks.firstIndex(where: { $0.id == id }) else { return }
            change(&p.movie.tracks[i])
        }
    }

    static func setOverlay(_ document: ProjectDocument, _ on: Bool) {
        document.edit { p in p.movie.overlay = on }
    }
}
