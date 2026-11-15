import AVFoundation
import CoreImage
import Foundation
import GaleFormat
import ImageIO
import UIKit

/// Holds something that isn't marked Sendable so it can cross from a background task to the screen.
/// Only used for objects that are made once and then only read.
final class StudioBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum StudioError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

extension CMTime {
    /// A CMTime from seconds, safe for NaN and infinity.
    static func studio(_ seconds: Double) -> CMTime {
        guard seconds.isFinite else { return .zero }
        return CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    /// Seconds, or 0 when the time is not a real number.
    var studioSeconds: Double {
        let s = seconds
        return s.isFinite ? s : 0
    }
}

// MARK: - The finished movie

/// A movie ready to play or save: the cut list, how to draw each frame, and how loud each sound is.
final class StudioMovieBuild: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: Double
    let renderSize: CGSize

    init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, duration: Double, renderSize: CGSize) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
        self.renderSize = renderSize
    }
}

// MARK: - Render plan (read by the compositor on its own threads)

/// Everything needed to draw any moment of the movie. Never changes after it is made.
final class StudioRenderPlan: @unchecked Sendable {
    enum Source {
        case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
        case picture(URL)
        case animation
    }

    struct Layer {
        let clip: Clip
        let source: Source
    }

    let project: GaleProject
    let width: Int
    let height: Int
    /// For each video track, back to front, the clips that can show on it.
    let layersByTrack: [[Layer]]
    let drawOnTop: Bool
    private let background: CIImage
    private let drawings = NSCache<NSNumber, CIImage>()
    private let pictures = NSCache<NSString, CIImage>()

    var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    init(project: GaleProject, width: Int, height: Int, layersByTrack: [[Layer]]) {
        self.project = project
        self.width = max(2, width)
        self.height = max(2, height)
        self.layersByTrack = layersByTrack
        drawOnTop = StudioMath.drawsAnimationOnTop(project)
        let paper = CIImage(color: CIColor(cgColor: project.canvas.background.cgColor))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        background = paper.composited(over: black).cropped(to: CGRect(x: 0, y: 0, width: max(2, width), height: max(2, height)))
        // Keep about 300 MB of drawn frames at most.
        drawings.totalCostLimit = 300 * 1024 * 1024
        pictures.countLimit = 24
    }

    /// The picture for movie time `t`. `frame` gives the decoded video frame of a composition track.
    func image(at t: Double, frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        var out = background
        for layers in layersByTrack {
            guard let layer = active(in: layers, at: t) else { continue }
            var picture: CIImage?
            switch layer.source {
            case .video(let trackID, let orientation):
                if let buffer = frame(trackID) {
                    picture = fit(CIImage(cvPixelBuffer: buffer).oriented(orientation))
                }
            case .picture(let url):
                picture = self.picture(url)
            case .animation:
                let s = StudioMath.sourceTime(of: layer.clip, atTimeline: t)
                picture = drawing(StudioMath.drawingFrameIndex(atTime: s, project: project))
            }
            guard let top = picture else { continue }
            let over = top.composited(over: out)
            let g = StudioMath.fadeGain(layer.clip, at: t)
            if g >= 0.999 {
                out = over
            } else if g > 0.001 {
                out = out.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: over,
                    kCIInputTimeKey: NSNumber(value: g)
                ])
            }
        }
        if drawOnTop, let d = drawing(StudioMath.drawingFrameIndex(atTime: t, project: project)) {
            out = d.composited(over: out)
        }
        return out.cropped(to: rect)
    }

    private func active(in layers: [Layer], at t: Double) -> Layer? {
        var best: Layer?
        for l in layers where StudioMath.contains(l.clip, time: t) {
            if let b = best, (b.clip.start, b.clip.id) > (l.clip.start, l.clip.id) { continue }
            best = l
        }
        return best
    }

    /// Scales a picture to fit the movie, centered.
    private func fit(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite else { return image }
        let r = StudioMath.aspectFit(width: Double(e.width), height: Double(e.height), inWidth: Double(width), inHeight: Double(height))
        let k = CGFloat(r.width) / e.width
        let move = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: CGFloat(r.x), y: CGFloat(r.y)))
        return image.transformed(by: move)
    }

    /// The drawing for one frame, see-through, at movie size. Made once, then kept.
    func drawing(_ index: Int) -> CIImage? {
        let key = NSNumber(value: index)
        if let hit = drawings.object(forKey: key) { return hit }
        let scale = CGFloat(Double(width) / max(1, project.canvas.width))
        var options = FrameRenderer.Options()
        options.background = false
        options.hair = true
        options.motionBlur = true
        guard let cg = FrameRenderer.image(project, frameIndex: index, scale: scale, options: options) else { return nil }
        var img = CIImage(cgImage: cg)
        let e = img.extent
        if e.width > 0, e.height > 0 {
            img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
        }
        drawings.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
        return img
    }

    /// A photo, turned the right way up and fit to the movie. Made once, then kept.
    private func picture(_ url: URL) -> CIImage? {
        let key = url.path as NSString
        if let hit = pictures.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let img = fit(CIImage(cgImage: cg))
        pictures.setObject(img, forKey: key)
        return img
    }

    /// Which way to turn a video frame, from the video's own transform.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        func is_(_ v: CGFloat, _ w: CGFloat) -> Bool { abs(v - w) < 0.01 }
        if is_(t.a, 0), is_(t.b, 1), is_(t.c, -1), is_(t.d, 0) { return .right }
        if is_(t.a, 0), is_(t.b, -1), is_(t.c, 1), is_(t.d, 0) { return .left }
        if is_(t.a, -1), is_(t.b, 0), is_(t.c, 0), is_(t.d, -1) { return .down }
        return .up
    }
}

// MARK: - Compositor

/// Tells the compositor how to draw a stretch of the movie.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let plan: StudioRenderPlan

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], plan: StudioRenderPlan) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.plan = plan
        super.init()
    }
}

/// Draws each movie frame: paper, then video tracks back to front, then the drawing on top.
final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? StudioInstruction else {
                request.finish(with: StudioError.message("The movie couldn't be drawn."))
                return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: StudioError.message("Out of memory while drawing the movie."))
                return
            }
            let plan = instruction.plan
            var image = plan.image(at: request.compositionTime.studioSeconds) { id in
                request.sourceFrame(byTrackID: id)
            }
            let w = CVPixelBufferGetWidth(output), h = CVPixelBufferGetHeight(output)
            if w != plan.width || h != plan.height, plan.width > 0, plan.height > 0 {
                image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(plan.width),
                                                                y: CGFloat(h) / CGFloat(plan.height)))
            }
            context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Blank video

/// A tiny black video. The movie always has one stretched under everything, so it has a length
/// and frames to draw on even when there is no video (just the drawing, or just sounds).
actor StudioBlankVideo {
    static let shared = StudioBlankVideo()
    private var task: Task<URL, Error>?

    func url() async throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dest = caches.appendingPathComponent("gale-studio-blank-v1.mov")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if let task { return try await task.value }
        let t = Task { try await StudioBlankVideo.write(to: dest) }
        task = t
        do {
            return try await t.value
        } catch {
            task = nil
            throw error
        }
    }

    private static func write(to dest: URL) async throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("gale-blank-\(UUID().uuidString).mov")
        let side = 64
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side
        ])
        guard writer.canAdd(input) else { throw StudioError.message("Couldn't get the movie ready.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("Couldn't get the movie ready.") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<2 {
            var tries = 0
            while !input.isReadyForMoreMediaData && tries < 500 {
                tries += 1
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let pb = buffer else { throw StudioError.message("Couldn't get the movie ready.") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 2)) {
                throw writer.error ?? StudioError.message("Couldn't get the movie ready.")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? fm.removeItem(at: temp)
            throw writer.error ?? StudioError.message("Couldn't get the movie ready.")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: temp, to: dest)
        return dest
    }
}

// MARK: - Builder

/// Turns the project's tracks and clips into something AVFoundation can play and save.
enum StudioMovieBuilder {
    /// One composition track. Clips are added left to right; `end` is where the next one can go.
    private final class Slot {
        let track: AVMutableCompositionTrack
        var end: CMTime = .zero
        /// Volume curve pieces for sound slots.
        var segments: [StudioVolumeSegment] = []
        init(track: AVMutableCompositionTrack) { self.track = track }
    }

    /// Builds the movie. `maxSide` caps the long side of the picture (smaller = faster preview).
    static func build(project: GaleProject, folder: URL, maxSide: Double) async throws -> StudioMovieBuild {
        let composition = AVMutableComposition()
        let size = StudioMath.renderSize(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height, maxSide: maxSide)
        let length = StudioMath.movieLength(project)
        let tolerance = CMTime(value: 2, timescale: 600)

        var assets: [String: AVURLAsset] = [:]
        func asset(for item: MediaItem) -> AVURLAsset {
            if let a = assets[item.id] { return a }
            let a = AVURLAsset(url: GaleIO.mediaURL(item, in: folder))
            assets[item.id] = a
            return a
        }

        var videoSlots: [String: [Slot]] = [:]
        var audioSlots: [String: [Slot]] = [:]
        var allAudioSlots: [Slot] = []

        func freeSlot(_ pool: inout [Slot], type: AVMediaType, at start: CMTime) -> Slot? {
            if let s = pool.first(where: { CMTimeCompare($0.end, CMTimeAdd(start, tolerance)) <= 0 }) { return s }
            guard let t = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            let s = Slot(track: t)
            pool.append(s)
            if type == .audio { allAudioSlots.append(s) }
            return s
        }

        /// Puts part of a source track on a slot at `start`, stretched to `target`. Returns where it really went.
        func place(_ source: AVAssetTrack, range: CMTimeRange, at start: CMTime, target: CMTime, in slot: Slot) throws -> CMTime {
            var at = start
            if CMTimeCompare(slot.end, start) < 0 {
                slot.track.insertEmptyTimeRange(CMTimeRange(start: slot.end, end: start))
            } else {
                at = slot.end
            }
            try slot.track.insertTimeRange(range, of: source, at: at)
            if CMTimeCompare(range.duration, target) != 0 {
                slot.track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: target)
            }
            slot.end = CMTimeAdd(at, target)
            return at
        }

        /// The part of the source a clip uses, cut to what the file really has.
        func sourceRange(_ clip: Clip, track: AVAssetTrack) async -> CMTimeRange? {
            guard let full = try? await track.load(.timeRange), full.isValid, !full.isEmpty else { return nil }
            let wanted = CMTimeRange(start: CMTimeAdd(full.start, .studio(clip.inPoint)), duration: .studio(clip.duration))
            let cut = wanted.intersection(full)
            guard cut.isValid, cut.duration.studioSeconds >= 1.0 / 600 else { return nil }
            return cut
        }

        func addSound(_ clip: Clip, gain: Double, source: AVAssetTrack, galeTrack: String) async throws {
            guard gain > 0.0001, let range = await sourceRange(clip, track: source) else { return }
            let speed = StudioMath.safeSpeed(clip.speed)
            let target = CMTime.studio(range.duration.studioSeconds / speed)
            let copies = StudioMath.copiesNeeded(gain: gain)
            var pool = audioSlots[galeTrack] ?? []
            for _ in 0..<copies {
                guard let slot = freeSlot(&pool, type: .audio, at: .studio(clip.start)) else { break }
                let at = try place(source, range: range, at: .studio(clip.start), target: target, in: slot)
                // Follow the clip where it really landed, and its real length.
                var placed = clip
                placed.start = at.studioSeconds
                placed.duration = range.duration.studioSeconds
                slot.segments += StudioMath.volumeSegments(placed, gain: gain, copies: copies)
            }
            audioSlots[galeTrack] = pool
        }

        let ordered = StudioMath.orderedTracks(project.movie)
        var layersByTrack: [[StudioRenderPlan.Layer]] = []

        for track in ordered {
            let clips = StudioMath.clips(onTrack: track.id, in: project.movie)
            switch track.kind {
            case .video:
                var layers: [StudioRenderPlan.Layer] = []
                var pool: [Slot] = []
                for clip in clips where clip.length > 0.0001 {
                    if clip.media == Clip.animation {
                        layers.append(.init(clip: clip, source: .animation))
                        continue
                    }
                    guard let item = project.media.first(where: { $0.id == clip.media }) else { continue }
                    switch item.kind {
                    case .image:
                        layers.append(.init(clip: clip, source: .picture(GaleIO.mediaURL(item, in: folder))))
                    case .video, .audio:
                        let a = asset(for: item)
                        if let v = try? await a.loadTracks(withMediaType: .video).first,
                           let range = await sourceRange(clip, track: v),
                           let slot = freeSlot(&pool, type: .video, at: .studio(clip.start)) {
                            let target = CMTime.studio(range.duration.studioSeconds / StudioMath.safeSpeed(clip.speed))
                            let at = try place(v, range: range, at: .studio(clip.start), target: target, in: slot)
                            let transform = (try? await v.load(.preferredTransform)) ?? .identity
                            var placed = clip
                            placed.start = at.studioSeconds
                            placed.duration = range.duration.studioSeconds
                            layers.append(.init(clip: placed,
                                                source: .video(trackID: slot.track.trackID,
                                                               orientation: StudioRenderPlan.orientation(of: transform))))
                        }
                        if let sound = try? await a.loadTracks(withMediaType: .audio).first {
                            try await addSound(clip, gain: StudioMath.totalGain(clip: clip, track: track), source: sound, galeTrack: track.id)
                        }
                    }
                }
                videoSlots[track.id] = pool
                layersByTrack.append(layers)
            case .audio:
                for clip in clips where clip.length > 0.0001 {
                    guard let item = project.media.first(where: { $0.id == clip.media }), item.kind != .image else { continue }
                    if let sound = try? await asset(for: item).loadTracks(withMediaType: .audio).first {
                        try await addSound(clip, gain: StudioMath.totalGain(clip: clip, track: track), source: sound, galeTrack: track.id)
                    }
                }
            }
        }

        // The blank video under everything, as long as the whole movie.
        let blankURL = try await StudioBlankVideo.shared.url()
        let blank = AVURLAsset(url: blankURL)
        guard let blankTrack = try await blank.loadTracks(withMediaType: .video).first,
              let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.message("Couldn't get the movie ready.")
        }
        let blankRange = try await blankTrack.load(.timeRange)
        guard blankRange.isValid, blankRange.duration.studioSeconds > 0 else {
            throw StudioError.message("Couldn't get the movie ready.")
        }
        var total = CMTime.studio(length)
        for slot in videoSlots.values.flatMap({ $0 }) + allAudioSlots {
            total = CMTimeMaximum(total, slot.end)
        }
        try base.insertTimeRange(blankRange, of: blankTrack, at: .zero)
        base.scaleTimeRange(CMTimeRange(start: .zero, duration: blankRange.duration), toDuration: total)

        // Sound levels and fades.
        var params: [AVMutableAudioMixInputParameters] = []
        for slot in allAudioSlots where !slot.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: slot.track)
            var last = CMTime.zero
            for seg in slot.segments.sorted(by: { $0.start < $1.start }) {
                let start = CMTimeMaximum(CMTime.studio(seg.start), last)
                let end = CMTime.studio(seg.end)
                guard CMTimeCompare(end, start) > 0 else { continue }
                p.setVolumeRamp(fromStartVolume: Float(seg.from), toEndVolume: Float(seg.to),
                                timeRange: CMTimeRange(start: start, end: end))
                last = end
            }
            params.append(p)
        }
        var mix: AVMutableAudioMix?
        if !params.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = params
            mix = m
        }

        let duration = total
        let plan = StudioRenderPlan(project: project, width: size.width, height: size.height, layersByTrack: layersByTrack)
        let videoTrackIDs = videoSlots.values.flatMap { $0 }.map { $0.track.trackID } + [base.trackID]
        let instruction = StudioInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), trackIDs: videoTrackIDs, plan: plan)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = CGSize(width: size.width, height: size.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: StudioMath.videoFPS(projectFPS: project.fps))
        videoComposition.instructions = [instruction]

        return StudioMovieBuild(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: mix,
                                duration: duration.studioSeconds,
                                renderSize: CGSize(width: size.width, height: size.height))
    }
}
