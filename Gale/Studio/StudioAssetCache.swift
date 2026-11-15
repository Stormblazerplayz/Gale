import AVFoundation
import CoreGraphics
import Foundation
import GaleFormat
import ImageIO

/// Loudness peaks of a sound file, `perSecond` of them for each second.
struct StudioPeaks: Sendable {
    let values: [Float]
    let perSecond: Double
}

/// Makes and keeps small pictures for the timeline (video frames, photos, drawings) and waveforms.
actor StudioAssetCache {
    static let shared = StudioAssetCache()

    private var images: [String: StudioBox<CGImage>] = [:]
    private var imageOrder: [String] = []
    private var imageTasks: [String: Task<StudioBox<CGImage>?, Never>] = [:]
    private var generators: [URL: StudioBox<AVAssetImageGenerator>] = [:]
    private var peaks: [String: StudioPeaks] = [:]
    private var peakTasks: [String: Task<StudioPeaks?, Never>] = [:]
    private let maxImages = 400

    /// Peaks per second we keep for waveforms.
    static let peakRate = 50.0

    // MARK: Pictures

    private func cachedImage(_ key: String, make: @escaping @Sendable () async -> StudioBox<CGImage>?) async -> CGImage? {
        if let hit = images[key] { return hit.value }
        if let running = imageTasks[key] { return await running.value?.value }
        let task = Task.detached(priority: .utility) { await make() }
        imageTasks[key] = task
        let result = await task.value
        imageTasks[key] = nil
        if let result {
            images[key] = result
            imageOrder.append(key)
            if imageOrder.count > maxImages {
                let drop = imageOrder.prefix(imageOrder.count - maxImages)
                for k in drop { images[k] = nil }
                imageOrder.removeFirst(drop.count)
            }
        }
        return result?.value
    }

    private func generator(for url: URL) -> StudioBox<AVAssetImageGenerator> {
        if let g = generators[url] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 240, height: 240)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let box = StudioBox(g)
        generators[url] = box
        if generators.count > 40 { generators.removeAll(); generators[url] = box }
        return box
    }

    /// A small frame of a video at `time` seconds (rounded to a tenth).
    func videoFrame(url: URL, time: Double) async -> CGImage? {
        let tenths = Int((max(0, time) * 10).rounded())
        let key = "v|\(url.path)|\(tenths)"
        let gen = generator(for: url)
        return await cachedImage(key) {
            let t = CMTime(value: CMTimeValue(tenths), timescale: 10)
            guard let result = try? await gen.value.image(at: t) else { return nil }
            return StudioBox(result.image)
        }
    }

    /// A small copy of a photo, turned the right way up.
    func picture(url: URL) async -> CGImage? {
        await cachedImage("p|\(url.path)") {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return StudioBox(cg)
        }
    }

    /// A small picture of one drawing frame on its paper. `version` changes when the drawing changes.
    func drawing(project: GaleProject, frameIndex: Int, version: Int) async -> CGImage? {
        await cachedImage("d|\(project.id)|\(version)|\(frameIndex)") {
            let scale = CGFloat(160 / max(1, max(project.canvas.width, project.canvas.height)))
            guard let cg = FrameRenderer.image(project, frameIndex: frameIndex, scale: scale) else { return nil }
            return StudioBox(cg)
        }
    }

    // MARK: Waveforms

    /// Waveform peaks of a sound (or a video's sound). `key` names the file's content (its sha256).
    func peaks(url: URL, key: String) async -> StudioPeaks? {
        if let hit = peaks[key] { return hit }
        if let running = peakTasks[key] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> StudioPeaks? in
            if let saved = StudioAssetCache.loadSavedPeaks(key: key) { return saved }
            guard let made = await StudioAssetCache.readPeaks(url: url, perSecond: StudioAssetCache.peakRate) else { return nil }
            StudioAssetCache.savePeaks(made, key: key)
            return made
        }
        peakTasks[key] = task
        let result = await task.value
        peakTasks[key] = nil
        if let result { peaks[key] = result }
        return result
    }

    private static func peaksFile(key: String) -> URL? {
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("gale-waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(safe).peaks")
    }

    /// File layout: 8 bytes (peaks per second, Double) then Float32 peaks.
    private static func loadSavedPeaks(key: String) -> StudioPeaks? {
        guard let file = peaksFile(key: key), let data = try? Data(contentsOf: file), data.count >= 8 else { return nil }
        var rate = 0.0
        withUnsafeMutableBytes(of: &rate) { raw in
            _ = data.copyBytes(to: raw.bindMemory(to: UInt8.self), from: 0..<8)
        }
        guard rate.isFinite, rate > 0 else { return nil }
        let count = (data.count - 8) / 4
        var values = [Float](repeating: 0, count: count)
        if count > 0 {
            values.withUnsafeMutableBytes { raw in
                _ = data.copyBytes(to: raw.bindMemory(to: UInt8.self), from: 8..<(8 + count * 4))
            }
        }
        return StudioPeaks(values: values, perSecond: rate)
    }

    private static func savePeaks(_ peaks: StudioPeaks, key: String) {
        guard let file = peaksFile(key: key) else { return }
        var data = Data()
        var rate = peaks.perSecond
        withUnsafeBytes(of: &rate) { data.append(contentsOf: $0) }
        peaks.values.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: file, options: .atomic)
    }

    /// Reads every sample of the file's sound and keeps the loudest of each little piece.
    static func readPeaks(url: URL, perSecond: Double) async -> StudioPeaks? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var accumulator: StudioPeakAccumulator?
        var channels = 1
        var sampleRate = 44_100.0
        var scratch: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            if accumulator == nil {
                if let format = CMSampleBufferGetFormatDescription(sample),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                    channels = max(1, Int(asbd.mChannelsPerFrame))
                }
                accumulator = StudioPeakAccumulator(framesPerPeak: max(1, Int(sampleRate / perSecond)))
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let floats = length / MemoryLayout<Float>.size
            guard floats > 0 else { continue }
            if scratch.count != floats { scratch = [Float](repeating: 0, count: floats) }
            let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats * MemoryLayout<Float>.size, destination: base)
            }
            guard status == noErr else { continue }
            accumulator?.add(scratch, channels: channels)
        }
        guard reader.status == .completed, var acc = accumulator else { return nil }
        let values = acc.finish()
        return StudioPeaks(values: values, perSecond: sampleRate / Double(acc.framesPerPeak))
    }
}
