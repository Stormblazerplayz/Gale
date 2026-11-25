import AVFoundation
import GaleFormat
import GalePixel
import Photos
import SwiftUI

/// Saves a pixel story as a GIF or video, a scene as a sprite sheet for games, or one frame as a picture.
struct PixelExportSheet: View {
    let story: PixelStory
    let name: String
    let scene: Int
    let frame: Int
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case gif, mp4, sheet, png
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gif: return "Animated GIF (whole story)"
            case .mp4: return "Video, MP4 (whole story)"
            case .sheet: return "Sprite sheet (this scene, for games)"
            case .png: return "Picture of this frame (PNG)"
            }
        }
    }

    enum Size: Int, CaseIterable, Identifiable {
        case small = 360, medium = 540, large = 720, huge = 1080
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            case .huge: return "Huge"
            }
        }
    }

    @State private var kind = Kind.gif
    @State private var size = Size.medium
    @State private var scale = 4
    @State private var progress: Double?
    @State private var results: [URL] = []
    @State private var message: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Make", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: kind) { _, _ in results = [] }
                }
                Section {
                    switch kind {
                    case .gif, .mp4:
                        Picker("Size", selection: $size) {
                            ForEach(Size.allCases) { s in
                                let r = StoryRenderer.Layout(story: story, maxSide: s.rawValue, evenSize: kind == .mp4)
                                Text("\(s.title) (\(r.width) × \(r.height))").tag(s)
                            }
                        }
                        Text("About \(String(format: "%.1f", StoryTiming(story).total)) seconds long.")
                            .foregroundStyle(.secondary)
                    case .sheet, .png:
                        Stepper("Each pixel: \(scale) × \(scale)", value: $scale, in: 1...16)
                        if kind == .sheet {
                            Text("Comes with a small JSON file listing where each frame is and how long it shows.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        run()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(progress != nil)
                    .accessibilityIdentifier("runPixelExport")
                    if let progress {
                        ProgressView(value: progress)
                        Button("Stop", role: .destructive) { job?.cancel() }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
                if !results.isEmpty {
                    Section("Ready") {
                        ForEach(results, id: \.self) { url in
                            ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                        }
                        if kind != .sheet, let first = results.first {
                            Button {
                                saveToPhotos(first)
                            } label: {
                                Label("Save to Photos", systemImage: "photo.on.rectangle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { job?.cancel(); dismiss() } }
            }
        }
    }

    private func run() {
        results = []
        message = nil
        progress = 0
        let story = story, name = name, scene = scene, frame = frame, kind = kind, maxSide = size.rawValue, scale = scale
        let report: @Sendable (Double) -> Void = { p in Task { @MainActor in if progress != nil { progress = p } } }
        let work = Task.detached(priority: .userInitiated) { () async throws -> [URL] in
            switch kind {
            case .gif: return [try PixelExporter.gif(story, name: name, maxSide: maxSide, progress: report)]
            case .mp4: return [try await PixelExporter.mp4(story, name: name, maxSide: maxSide, progress: report)]
            case .sheet: return try PixelExporter.spriteSheet(story, name: name, scene: scene, scale: scale)
            case .png: return [try PixelExporter.png(story, name: name, scene: scene, frame: frame, scale: scale)]
            }
        }
        job = Task { @MainActor in
            do {
                results = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
            } catch is CancellationError {
                message = "Stopped."
            } catch {
                message = error.localizedDescription
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
                    // Adding the file itself keeps GIFs animated.
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
                }
            }) { ok, _ in
                Task { @MainActor in message = ok ? "Saved to Photos." : "Couldn't save to Photos." }
            }
        }
    }
}

/// The export work, run away from the screen so drawing stays smooth.
enum PixelExporter {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func outputURL(_ name: String, suffix: String = "", ext: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PixelExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(GaleIO.safeName(name) + suffix).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Every picture of the story at `fps`, with how long each shows. Repeats are merged so files stay small.
    /// Pictures are made one at a time, so long stories don't fill memory.
    static func forEachPicture(_ r: StoryRenderer, fps: Double, mergeRepeats: Bool,
                               _ body: (RGBAImage, Int) throws -> Void, progress: (Double) -> Void) throws {
        let total = r.timing.total
        let count = max(1, Int((total * fps).rounded(.up)))
        var pending: RGBAImage?
        var pendingTicks = 0
        for k in 0..<count {
            try Task.checkCancellation()
            let img = r.image(at: Double(k) / fps, loop: false)
            if mergeRepeats, let p = pending, p == img {
                pendingTicks += 1
            } else {
                if let p = pending { try body(p, pendingTicks) }
                pending = img
                pendingTicks = 1
            }
            progress(Double(k + 1) / Double(count))
        }
        if let p = pending { try body(p, pendingTicks) }
    }

    static func gif(_ story: PixelStory, name: String, maxSide: Int, progress: (Double) -> Void) throws -> URL {
        let r = StoryRenderer(story: story, maxSide: maxSide)
        var enc = GIFEncoder(width: r.layout.width, height: r.layout.height)
        // 25 pictures a second: GIF times are in hundredths, so each tick is exactly 4.
        try forEachPicture(r, fps: 25, mergeRepeats: true, { img, ticks in
            enc.add(img, centiseconds: ticks * 4)
        }, progress: progress)
        let url = outputURL(story.name(fallback: name), ext: "gif")
        try enc.finish().write(to: url, options: .atomic)
        return url
    }

    static func mp4(_ story: PixelStory, name: String, maxSide: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let r = StoryRenderer(story: story, maxSide: maxSide, evenSize: true)
        let w = r.layout.width, h = r.layout.height
        let url = outputURL(story.name(fallback: name), ext: "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 8)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw Failure(message: "Couldn't make the video.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "Couldn't start the video.") }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let count = max(1, Int((r.timing.total * Double(fps)).rounded(.up)))
        var last: RGBAImage?
        var lastBuffer: CVPixelBuffer?
        for k in 0..<count {
            try Task.checkCancellation()
            let img = r.image(at: Double(k) / Double(fps), loop: false)
            if img != last || lastBuffer == nil {
                guard let pool = adaptor.pixelBufferPool, let buffer = makeBuffer(img, pool: pool) else {
                    throw Failure(message: "Couldn't draw a video frame.")
                }
                lastBuffer = buffer
                last = img
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            if let lastBuffer {
                adaptor.append(lastBuffer, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps)))
            }
            progress(Double(k + 1) / Double(count))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(message: "The video didn't finish.") }
        return url
    }

    /// Copies an RGBA picture into a BGRA video frame (on black, since videos have no see-through).
    private static func makeBuffer(_ img: RGBAImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let w = min(img.width, CVPixelBufferGetWidth(buffer)), h = min(img.height, CVPixelBufferGetHeight(buffer))
        let dst = base.assumingMemoryBound(to: UInt8.self)
        img.bytes.withUnsafeBufferPointer { src in
            for y in 0..<h {
                let row = dst + y * rowBytes
                for x in 0..<w {
                    let s = (y * img.width + x) * 4
                    let a = Int(src[s + 3])
                    row[x * 4 + 0] = UInt8(Int(src[s + 2]) * a / 255)
                    row[x * 4 + 1] = UInt8(Int(src[s + 1]) * a / 255)
                    row[x * 4 + 2] = UInt8(Int(src[s + 0]) * a / 255)
                    row[x * 4 + 3] = 255
                }
            }
        }
        return buffer
    }

    static func spriteSheet(_ story: PixelStory, name: String, scene: Int, scale: Int) throws -> [URL] {
        let (img, layout) = SpriteSheet.render(story, scene: scene, scale: scale)
        let base = story.name(fallback: name)
        let suffix = " scene \(scene + 1)"
        let pngURL = outputURL(base, suffix: suffix, ext: "png")
        guard let png = img.pngData() else { throw Failure(message: "Couldn't save the sprite sheet.") }
        try png.write(to: pngURL, options: .atomic)
        let jsonURL = outputURL(base, suffix: suffix, ext: "json")
        try Data(SpriteSheet.json(story, scene: scene, layout: layout, imageName: pngURL.lastPathComponent).utf8)
            .write(to: jsonURL, options: .atomic)
        return [pngURL, jsonURL]
    }

    static func png(_ story: PixelStory, name: String, scene: Int, frame: Int, scale: Int) throws -> URL {
        let img = story.thumbnail(scene: scene, frame: frame).scaled(by: max(1, scale))
        guard let data = img.pngData() else { throw Failure(message: "Couldn't save the picture.") }
        let url = outputURL(story.name(fallback: name), suffix: " scene \(scene + 1) frame \(frame + 1)", ext: "png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private extension PixelStory {
    /// Stories don't keep their own name (the project does), so exports use the project's.
    func name(fallback: String) -> String {
        let clean = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Pixel story" : clean
    }
}
