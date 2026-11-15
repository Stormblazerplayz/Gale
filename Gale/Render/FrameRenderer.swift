import CoreGraphics
import CoreImage
import Foundation
import GaleCore
import GaleFormat

/// Turns a frame of a project into a picture. Safe to use from any thread.
enum FrameRenderer {
    struct Options {
        /// Paint the paper color behind everything.
        var background = true
        /// Make hair regions sway (playback and export). Off while editing so you draw on the real lines.
        var hair = false
        /// Add motion blur trails (playback and export) when the project has it turned on.
        var motionBlur = false
        /// Only these layers (nil = all visible layers).
        var layers: Set<String>? = nil
        /// Draw every layer in this one color (used for onion skin ghosts).
        var tint: RGBA? = nil
    }

    /// Draws a frame into a context that is already set up as canvas pixels, y down.
    static func draw(_ project: GaleProject, frameIndex: Int, in ctx: CGContext, options: Options = Options()) {
        guard project.frames.indices.contains(frameIndex) else { return }
        let canvas = CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height)
        if options.background {
            ctx.setFillColor(project.canvas.background.cgColor)
            ctx.fill(canvas)
        }
        let frame = project.frames[frameIndex]
        let time = Playback.time(ofFrame: frameIndex, project: project)
        let previousIndex = frameIndex > 0 ? frameIndex - 1 : project.frames.count - 1
        for layer in project.layers where layer.visible {
            if let only = options.layers, !only.contains(layer.id) { continue }
            var cel = frame.cel(layer.id)
            if cel.isEmpty { continue }
            if options.hair {
                let regions = HairSway.regions(in: project, layer: layer.id)
                if !regions.isEmpty { cel = HairSway.deform(cel, regions: regions, time: time) }
            }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(layer.opacity))
            // Each layer gets its own see-through sheet, so the eraser only clears its own layer.
            ctx.beginTransparencyLayer(in: canvas, auxiliaryInfo: nil)
            if options.motionBlur, project.motionBlur.on, project.frames.count > 1, previousIndex != frameIndex {
                let previous = project.frames[previousIndex].cel(layer.id)
                let trails = MotionBlur.trails(previous: previous, current: cel, settings: project.motionBlur)
                for trail in trails {
                    for sample in trail.samples {
                        ctx.saveGState()
                        ctx.translateBy(x: CGFloat(sample.offset.x), y: CGFloat(sample.offset.y))
                        for s in trail.strokes where s.brush.kind != .eraser {
                            StrokeRenderer.draw(s, in: ctx, alpha: sample.alpha, tint: options.tint)
                        }
                        ctx.restoreGState()
                    }
                }
            }
            StrokeRenderer.draw(cel, in: ctx, tint: options.tint)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    /// Makes a bitmap context of `size` pixels, flipped so drawing uses canvas pixels with y down.
    static func makeContext(canvasWidth: Double, canvasHeight: Double, scale: CGFloat, opaque: Bool = false) -> CGContext? {
        let w = max(1, Int((CGFloat(canvasWidth) * scale).rounded()))
        let h = max(1, Int((CGFloat(canvasHeight) * scale).rounded()))
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }

    /// A picture of a frame. `scale` 1 = full canvas size.
    static func image(_ project: GaleProject, frameIndex: Int, scale: CGFloat = 1, options: Options = Options()) -> CGImage? {
        guard let ctx = makeContext(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height,
                                    scale: scale, opaque: options.background && project.canvas.background.a >= 1) else { return nil }
        draw(project, frameIndex: frameIndex, in: ctx, options: options)
        return ctx.makeImage()
    }

    /// A picture of just some strokes (for stash and loop thumbnails), fit into a square.
    static func thumbnail(strokes: [Stroke], fills: [Fill] = [], side: CGFloat = 160) -> CGImage? {
        var all = Box.empty
        for s in strokes { all = all.union(Geometry.bounds(of: s)) }
        for f in fills { all = all.union(Geometry.bounds(ofPath: f.path)) }
        guard all.width > 0 || all.height > 0 else { return nil }
        let pad = 6.0
        let k = (Double(side) - pad * 2) / max(1, all.maxSide)
        guard let ctx = makeContext(canvasWidth: Double(side), canvasHeight: Double(side), scale: 1) else { return nil }
        ctx.translateBy(x: CGFloat(pad + (Double(side) - pad * 2 - all.width * k) / 2),
                        y: CGFloat(pad + (Double(side) - pad * 2 - all.height * k) / 2))
        ctx.scaleBy(x: CGFloat(k), y: CGFloat(k))
        ctx.translateBy(x: CGFloat(-all.minX), y: CGFloat(-all.minY))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        StrokeRenderer.draw(Cel(strokes: strokes, fills: fills), in: ctx)
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }

    /// Frosted glass look for an onion skin ghost: soft blur, a little milky, tinted.
    static func frosted(_ image: CGImage, blur: Double, context: CIContext) -> CGImage? {
        guard blur > 0.1 else { return image }
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: blur)
            .cropped(to: input.extent)
        // Lift the darks a bit so the ghost looks like it's behind frosted glass.
        let milky = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputBrightnessKey: 0.06])
        return context.createCGImage(milky, from: input.extent)
    }
}
