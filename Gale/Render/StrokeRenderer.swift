import CoreGraphics
import Foundation
import GaleCore
import GaleFormat

/// Draws strokes and fills into a Core Graphics context whose coordinates are canvas pixels with y going down.
enum StrokeRenderer {
    /// Draws one cel: fills first, then strokes, both in key order.
    static func draw(_ cel: Cel, in ctx: CGContext, alpha: Double = 1, tint: RGBA? = nil) {
        for fill in cel.fills { draw(fill, in: ctx, alpha: alpha, tint: tint) }
        for stroke in cel.strokes { draw(stroke, in: ctx, alpha: alpha, tint: tint) }
    }

    static func draw(_ fill: Fill, in ctx: CGContext, alpha: Double = 1, tint: RGBA? = nil) {
        guard fill.path.count >= 6 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: fill.path[0], y: fill.path[1]))
        var i = 2
        while i + 1 < fill.path.count {
            path.addLine(to: CGPoint(x: fill.path[i], y: fill.path[i + 1]))
            i += 2
        }
        path.closeSubpath()
        let c = tint ?? fill.color
        ctx.saveGState()
        ctx.setFillColor(c.with(alpha: fill.color.a * alpha).cgColor)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    static func draw(_ stroke: Stroke, in ctx: CGContext, alpha: Double = 1, tint: RGBA? = nil) {
        guard !stroke.points.isEmpty else { return }
        let isEraser = stroke.brush.kind == .eraser
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if isEraser {
            ctx.setBlendMode(.clear)
        }
        let color = (tint ?? stroke.brush.color)
        let a = isEraser ? 1 : StrokeShape.alpha(of: stroke) * alpha

        if stroke.brush.kind == .airbrush && !isEraser {
            drawAirbrush(stroke, color: color, alpha: a, in: ctx)
            return
        }
        let outline = StrokeShape.outline(of: stroke)
        guard outline.count >= 3 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: outline[0].x, y: outline[0].y))
        for p in outline.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
        path.closeSubpath()
        ctx.setFillColor(color.with(alpha: isEraser ? 1 : a).cgColor)
        ctx.addPath(path)
        // Nonzero so a stroke that crosses itself stays solid.
        ctx.fillPath(using: .winding)
    }

    private static func drawAirbrush(_ stroke: Stroke, color: RGBA, alpha: Double, in ctx: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        let inner = color.with(alpha: 1).cgColor
        let outer = color.with(alpha: 0).cgColor
        guard let gradient = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1]) else { return }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for dab in StrokeShape.airbrushDabs(of: stroke) {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(alpha * (0.3 + 0.7 * dab.pressure)))
            let c = CGPoint(x: dab.center.x, y: dab.center.y)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(dab.radius), options: [])
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
    }

    /// The live stroke while drawing, as a path (used by the fast preview layer).
    static func path(for stroke: Stroke) -> CGPath {
        let path = CGMutablePath()
        let outline = StrokeShape.outline(of: stroke)
        guard outline.count >= 3 else { return path }
        path.move(to: CGPoint(x: outline[0].x, y: outline[0].y))
        for p in outline.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
        path.closeSubpath()
        return path
    }
}
