import GaleFormat
import Photos
import SwiftUI

/// Save the animation as a video, a GIF or a picture, then share it.
struct ExportSheet: View {
    @ObservedObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AnimationExporter.Kind = .mp4
    @State private var repeats = 3
    @State private var quality = 1920.0
    @State private var progress: Double?
    @State private var result: URL?
    @State private var message: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Save as", selection: $kind) {
                        ForEach(AnimationExporter.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    if kind == .mp4 {
                        Stepper("Play it \(repeats) times", value: $repeats, in: 1...30)
                        Picker("Size", selection: $quality) {
                            Text("Small (720)").tag(720.0)
                            Text("HD (1080)").tag(1080.0)
                            Text("Full (1920)").tag(1920.0)
                            Text("Big (3840)").tag(3840.0)
                        }
                    }
                } footer: {
                    Text("Hair sway and motion blur are included.")
                }
                Section {
                    if let progress {
                        ProgressView(value: progress) { Text("Making it…") }
                        Button("Stop", role: .destructive) { job?.cancel() }
                    } else {
                        Button {
                            start()
                        } label: {
                            Label("Make it", systemImage: "wand.and.stars")
                        }
                    }
                    if let result {
                        ShareLink(item: result) {
                            Label("Share or save to Files", systemImage: "square.and.arrow.up")
                        }
                        if kind != .gif {
                            Button { saveToPhotos(result) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                        }
                    }
                    if let message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { job?.cancel(); dismiss() } } }
            .onChange(of: kind) { _, _ in result = nil; message = nil }
        }
    }

    private func start() {
        let p = document.project
        let k = kind, r = repeats, q = quality
        let frame = document.currentFrame
        result = nil
        message = nil
        progress = 0
        job = Task {
            do {
                let url: URL
                switch k {
                case .mp4:
                    url = try await AnimationExporter.exportMP4(p, repeats: r, maxSide: q) { v in
                        Task { @MainActor in progress = v }
                    }
                case .gif:
                    url = try await AnimationExporter.exportGIF(p) { v in
                        Task { @MainActor in progress = v }
                    }
                case .png:
                    url = try AnimationExporter.exportPNG(p, frameIndex: frame)
                }
                result = url
                message = "Ready!"
            } catch is CancellationError {
                message = "Stopped."
            } catch {
                message = "That didn't work: \(error.localizedDescription)"
            }
            progress = nil
        }
    }

    private func saveToPhotos(_ url: URL) {
        let isVideo = url.pathExtension.lowercased() == "mp4"
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in message = "Gale needs permission to add to Photos. You can turn it on in Settings." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { ok, _ in
                Task { @MainActor in message = ok ? "Saved to Photos." : "Couldn't save to Photos." }
            }
        }
    }
}
