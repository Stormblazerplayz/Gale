import Foundation
import GaleFormat

/// Turns an "animate it" step into a real Gale project, and reads the learner's animation back out.
///
/// The project has two layers:
///   - "Lesson guide" (bottom, locked, see-through): the lesson's drawings, one per frame, to animate over.
///   - "Your animation" (top): where the learner draws. Any other layers they add count too.
/// It has one frame per guide drawing, with the guide's holds and frame rate, so it plays at the lesson's timing.
public enum LearnStudio {
    public static let guideLayerName = "Lesson guide"
    public static let drawLayerName = "Your animation"
    /// Canvas height in pixels. Lesson space is 1 unit tall, so 1 unit = this many pixels.
    public static let canvasHeight = 1200.0

    /// Light lines for the guide layer.
    public static let inkColor = RGBA(0.42, 0.47, 0.62, 1)
    public static let accentColor = RGBA(0.55, 0.36, 0.96, 1)
    public static let helperColor = RGBA(0.62, 0.64, 0.7, 1)

    /// A fresh project for an animate step (nil when the step has no guide).
    public static func makeProject(for step: LearnStep, lessonTitle: String) -> GaleProject? {
        guard let guide = step.guide, !guide.frames.isEmpty else { return nil }
        let h = canvasHeight
        let w = (max(0.5, min(2.5, guide.aspect)) * h).rounded()
        let title = step.title.isEmpty ? lessonTitle : "\(lessonTitle): \(step.title)"
        var project = GaleProject(name: title, canvas: GaleCanvas(width: w, height: h, background: .white),
                                  fps: min(60, max(1, guide.fps)))

        // GaleProject starts with one layer and one frame. Make the first layer the guide and add ours on top.
        project.layers[0].name = guideLayerName
        project.layers[0].locked = true
        project.layers[0].opacity = 0.45
        let guideID = project.layers[0].id
        let drawLayer = project.addLayer(name: drawLayerName)

        project.frames = []
        for (i, gf) in guide.frames.enumerated() {
            var cel = Cel()
            for path in guide.background + gf.paths {
                if let stroke = stroke(for: path, scale: h) { cel.append(stroke) }
            }
            var frame = Frame(hold: max(1, gf.hold), cels: [guideID: cel])
            frame.cels[drawLayer.id] = Cel()
            project.insertFrame(frame, after: i == 0 ? nil : i - 1)
        }
        project.normalize()
        return project
    }

    /// A guide line as a Gale stroke (a marker line, so it has an even width).
    static func stroke(for path: LearnPath, scale: Double) -> Stroke? {
        let pts = path.polyline
        guard !pts.isEmpty else { return nil }
        let color: RGBA
        var width = path.width * scale
        switch path.role {
        case .ink: color = inkColor
        case .accent: color = accentColor
        case .guide:
            color = helperColor
            width *= 0.8
        }
        // A single point becomes a tiny dot.
        let line = pts.count == 1 ? [pts[0], LearnPoint(pts[0].x + 0.0005, pts[0].y)] : pts
        let points = line.enumerated().map { i, p in
            StrokePoint(x: p.x * scale, y: p.y * scale, pressure: 1, time: Double(i) * 0.01)
        }
        return Stroke(brush: Brush(kind: .marker, color: color, size: max(2, width), opacity: 1), points: points)
    }

    /// The guide layer and the learner's layer, found by name (the learner may have moved them).
    public static func layerIDs(in project: GaleProject) -> (guide: String?, draw: String?) {
        let guide = project.layers.first { $0.name == guideLayerName }?.id
        let draw = project.layers.last { $0.name == drawLayerName }?.id
        return (guide, draw)
    }

    /// The learner's lines on every frame, in lesson units, ready for the frames checks.
    /// Reads every layer except the lesson guide. Eraser strokes rub out the lines under them.
    public static func answerFrames(from project: GaleProject) -> [[[LearnPoint]]] {
        let guideID = layerIDs(in: project).guide
        let scale = max(1, project.canvas.height)
        let layers = project.layers.filter { $0.id != guideID && $0.visible }
        return project.frames.map { frame in
            var lines: [[LearnPoint]] = []
            for layer in layers {
                var cel = frame.cel(layer.id)
                cel.sortByKey()
                var layerLines: [[LearnPoint]] = []
                for s in cel.strokes {
                    let pts = s.points.map { LearnPoint($0.x / scale, $0.y / scale) }
                    if s.brush.kind == .eraser {
                        let radius = max(0.002, s.brush.size / scale / 2)
                        layerLines = erase(layerLines, along: pts, radius: radius)
                    } else if !pts.isEmpty {
                        layerLines.append(pts)
                    }
                }
                lines += layerLines
            }
            return lines.filter { !$0.isEmpty }
        }
    }

    /// Cuts away every part of the lines within `radius` of the eraser's path.
    public static func erase(_ lines: [[LearnPoint]], along eraser: [LearnPoint], radius: Double) -> [[LearnPoint]] {
        guard !eraser.isEmpty else { return lines }
        let path = eraser.count == 1 ? [eraser[0], eraser[0]] : eraser
        var out: [[LearnPoint]] = []
        for line in lines {
            // Look at the line finely so a quick swipe across a long straight segment still cuts it.
            let fine = line.count > 1 ? LearnGeometry.resample(line, spacing: max(0.002, radius / 2)) : line
            var run: [LearnPoint] = []
            for p in fine {
                if LearnGeometry.distance(p, toLines: [path]) <= radius {
                    if !run.isEmpty { out.append(run) }
                    run = []
                } else {
                    run.append(p)
                }
            }
            if !run.isEmpty { out.append(run) }
        }
        return out
    }

    /// How many frames have something drawn on them.
    public static func drawnFrameCount(_ frames: [[[LearnPoint]]]) -> Int {
        frames.filter { !$0.isEmpty }.count
    }
}
