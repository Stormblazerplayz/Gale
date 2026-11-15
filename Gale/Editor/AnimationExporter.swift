import AVFoundation
import CoreGraphics
import Foundation
import GaleCore
import GaleFormat
import ImageIO
import UniformTypeIdentifiers

/// Saves the animation as a video or a GIF.
enum AnimationExporter {
    enum Kind: String, CaseIterable, Identifiable {
        case mp4, gif, png
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mp4: return "Video (MP4)"
            case .gif: return "GIF"
            case .png: return "Picture of this frame (PNG)"
            }
        }
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Size that fits within `maxSide`, rounded to even numbers (videos need that).
    static func outputSize(_ p: GaleProject, maxSide: Double) -> (Int, Int, CGFloat) {
        let k = min(1, maxSide / max(p.canvas.width, p.canvas.height))
        var w = Int((p.canvas.width * k).rounded())
        var h = Int((p.canvas.height * k).rounded())
        w -= w % 2
        h -= h % 2
        return (max(2, w), max(2, h), CGFloat(k))
    }

    static func exportMP4(_ p: GaleProject, repeats: Int, maxSide: Double = 1920,
                          progress: @escaping (Double) -> Void) async throws -> URL {
        let (w, h, scale) = outputSize(p, maxSide: maxSide)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(GaleIO.safeName(p.name)).mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 6)],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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

        var opts = FrameRenderer.Options()
        opts.hair = true
        opts.motionBlur = true
        let fps = Int32(max(1, p.fps))
        let totalTicks = Playback.exportTicks(project: p, repeats: max(1, repeats), minimumSeconds: 1)
        var cache: [Int: CGImage] = [:]
        var tick = 0
        while tick < totalTicks {
            let i = Playback.frameIndex(atTick: tick, frames: p.frames)
            // Hold frames stay on screen: one video frame per tick keeps timing exact.
            let image: CGImage?
            if let c = cache[i] { image = c } else {
                image = FrameRenderer.image(p, frameIndex: i, scale: scale, options: opts)
                if let image { cache[i] = image }
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            if let image, let pool = adaptor.pixelBufferPool, let buffer = makeBuffer(from: image, pool: pool, width: w, height: h) {
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(tick), timescale: fps))
            }
            tick += 1
            progress(Double(tick) / Double(totalTicks))
            try Task.checkCancellation()
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(message: "The video didn't finish.") }
        return url
    }

    private static func makeBuffer(from image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    static func exportGIF(_ p: GaleProject, maxSide: Double = 720, progress: @escaping (Double) -> Void) async throws -> URL {
        let (_, _, scale) = outputSize(p, maxSide: maxSide)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(GaleIO.safeName(p.name)).gif")
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, p.frames.count, nil) else {
            throw Failure(message: "Couldn't make the GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        var opts = FrameRenderer.Options()
        opts.hair = true
        opts.motionBlur = true
        for (i, frame) in p.frames.enumerated() {
            guard let img = FrameRenderer.image(p, frameIndex: i, scale: scale, options: opts) else { continue }
            let delay = Double(frame.hold) / Double(max(1, p.fps))
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
            ]] as CFDictionary)
            progress(Double(i + 1) / Double(p.frames.count))
            try Task.checkCancellation()
        }
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "The GIF didn't finish.") }
        return url
    }

    static func exportPNG(_ p: GaleProject, frameIndex: Int) throws -> URL {
        guard let img = FrameRenderer.image(p, frameIndex: frameIndex, scale: 1) else { throw Failure(message: "Couldn't draw the frame.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(GaleIO.safeName(p.name)) frame \(frameIndex + 1).png")
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "Couldn't save the picture.")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "Couldn't save the picture.") }
        return url
    }
}
