import AVFoundation
import Foundation
import GaleFormat
import Photos
import SwiftUI

/// Saves the movie as an MP4 file.
@MainActor
final class StudioExporter: ObservableObject {
    enum State: Equatable {
        case idle
        case working
        case done(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var savedToPhotos = false
    @Published var photosMessage: String?
    @Published private(set) var isSavingToPhotos = false

    private var task: Task<Void, Never>?
    private var session: StudioBox<AVAssetExportSession>?

    var isWorking: Bool { state == .working }

    func start(project: GaleProject, folder: URL) {
        guard state != .working else { return }
        state = .working
        progress = 0
        savedToPhotos = false
        photosMessage = nil
        task = Task { [weak self] in
            await self?.run(project: project, folder: folder)
        }
    }

    private func run(project: GaleProject, folder: URL) async {
        do {
            let built = try await StudioMovieBuilder.build(project: project, folder: folder, maxSide: 3840)
            if Task.isCancelled { state = .idle; return }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("gale-export", isDirectory: true)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let safe = GaleIO.safeName(project.name).trimmingCharacters(in: .whitespaces)
            let url = out.appendingPathComponent("\(safe.isEmpty ? "My Movie" : safe).mp4")

            guard let export = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw StudioError.message("This iPad or iPhone can't make the movie.")
            }
            export.outputURL = url
            export.outputFileType = .mp4
            export.videoComposition = built.videoComposition
            export.audioMix = built.audioMix
            export.audioTimePitchAlgorithm = .spectral
            export.shouldOptimizeForNetworkUse = true
            let box = StudioBox(export)
            session = box

            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.progress = Double(box.value.progress)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                box.value.exportAsynchronously {
                    done.resume()
                }
            }
            poll.cancel()
            session = nil

            switch box.value.status {
            case .completed:
                progress = 1
                state = .done(url)
            case .cancelled:
                state = .idle
            default:
                let why = box.value.error?.localizedDescription ?? "Something went wrong."
                state = .failed("The movie couldn't be saved. \(why)")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        session?.value.cancelExport()
        task?.cancel()
        if state == .working { state = .idle }
    }

    func reset() {
        cancel()
        state = .idle
        progress = 0
        savedToPhotos = false
        photosMessage = nil
    }

    /// Adds the finished movie to the Photos app (only asks to add, never to read).
    func saveToPhotos(_ url: URL) async {
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            photosMessage = "Gale isn't allowed to save to Photos. You can turn it on in Settings > Gale > Photos."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            savedToPhotos = true
            photosMessage = "Saved to Photos!"
        } catch {
            photosMessage = "Couldn't save to Photos. \(error.localizedDescription)"
        }
    }
}

/// The "Save my movie" sheet: make the MP4, then share it or put it in Photos.
struct StudioExportSheet: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var exporter: StudioExporter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch exporter.state {
                case .idle:
                    idle
                case .working:
                    working
                case .done(let url):
                    done(url)
                case .failed(let message):
                    failed(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Save Movie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(exporter.isWorking ? "Stop" : "Close") {
                        if exporter.isWorking {
                            exporter.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(exporter.isWorking)
    }

    private var sizeText: String {
        let s = StudioMath.renderSize(canvasWidth: document.project.canvas.width,
                                      canvasHeight: document.project.canvas.height, maxSide: 3840)
        return "\(s.width) × \(s.height)"
    }

    private var idle: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 54))
                .foregroundStyle(Theme.gradient)
            Text("Make a video file of your movie")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("MP4 • \(sizeText) • \(StudioMath.timeLabel(StudioMath.movieLength(document.project), tenths: true)) long")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                exporter.start(project: document.project, folder: document.folder)
            } label: {
                Label("Make my movie", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var working: some View {
        VStack(spacing: 16) {
            ProgressView(value: min(1, max(0, exporter.progress)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
            Text("Making your movie… \(Int((min(1, max(0, exporter.progress)) * 100).rounded()))%")
                .font(.headline)
            Text("Keep Gale open until it's done.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("Your movie is ready!")
                .font(.title3.weight(.semibold))
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Button {
                Task { await exporter.saveToPhotos(url) }
            } label: {
                Label(exporter.savedToPhotos ? "Saved to Photos" : "Save to Photos",
                      systemImage: exporter.savedToPhotos ? "checkmark" : "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(exporter.savedToPhotos || exporter.isSavingToPhotos)
            if let message = exporter.photosMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Make it again") { exporter.reset() }
                .font(.subheadline)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Try again") { exporter.reset() }
                .buttonStyle(.borderedProminent)
        }
    }
}
