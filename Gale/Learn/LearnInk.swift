import SwiftUI
import UIKit
import Combine
import GaleFormat
import GaleCore
import GaleLearn

/// One line the kid drew, in lesson units, with pencil pressure for each point.
struct LearnInkStroke: Hashable {
    var points: [LearnPoint] = []
    var pressures: [Double] = []

    mutating func append(_ p: LearnPoint, pressure: Double) {
        points.append(p)
        pressures.append(pressure)
    }
}

/// The line being drawn right now. Kept apart so only the drawing layer redraws while the pencil moves.
@MainActor
final class LearnLiveInk: ObservableObject {
    @Published var stroke: LearnInkStroke?
}

/// Everything drawn for one step: one page for a trace step, one page per frame for a frames step.
@MainActor
final class LearnInk: ObservableObject {
    @Published private(set) var frames: [[LearnInkStroke]]
    @Published var current: Int = 0
    let live = LearnLiveInk()

    private var history: [(frame: Int, strokes: [LearnInkStroke])] = []

    init(frameCount: Int) {
        frames = Array(repeating: [], count: max(1, frameCount))
    }

    var frameCount: Int { frames.count }
    var currentStrokes: [LearnInkStroke] { frames.indices.contains(current) ? frames[current] : [] }
    var isEmpty: Bool { frames.allSatisfy(\.isEmpty) }
    var canUndo: Bool { !history.isEmpty }
    var drawnFrameCount: Int { frames.filter { !$0.isEmpty }.count }

    /// What gets checked: a list of lines per frame.
    var answerFrames: [[[LearnPoint]]] { frames.map { $0.map(\.points) } }

    func select(_ i: Int) {
        guard frames.indices.contains(i), i != current else { return }
        live.stroke = nil
        current = i
    }

    func begin(_ p: LearnPoint, pressure: Double) {
        var s = LearnInkStroke()
        s.append(p, pressure: pressure)
        live.stroke = s
    }

    func add(_ pts: [(LearnPoint, Double)]) {
        guard var s = live.stroke, !pts.isEmpty else { return }
        for (p, pressure) in pts { s.append(p, pressure: pressure) }
        live.stroke = s
    }

    func end(_ tail: [(LearnPoint, Double)]) {
        guard var s = live.stroke else { return }
        for (p, pressure) in tail { s.append(p, pressure: pressure) }
        live.stroke = nil
        guard frames.indices.contains(current), !s.points.isEmpty else { return }
        remember()
        frames[current].append(s)
    }

    func cancel() { live.stroke = nil }

    func undo() {
        guard let last = history.popLast(), frames.indices.contains(last.frame) else { return }
        live.stroke = nil
        frames[last.frame] = last.strokes
        current = last.frame
    }

    func clearCurrent() {
        guard frames.indices.contains(current), !frames[current].isEmpty else { return }
        remember()
        frames[current] = []
    }

    private func remember() {
        history.append((current, frames[current]))
        if history.count > 200 { history.removeFirst(history.count - 200) }
    }
}

/// Keeps each step's drawing, so going back to a step shows what you drew there.
@MainActor
final class LearnInkBook: ObservableObject {
    private var inks: [String: LearnInk] = [:]
    private var watchers: [String: AnyCancellable] = [:]

    func ink(for step: LearnStep) -> LearnInk {
        if let ink = inks[step.id] { return ink }
        let count = step.kind == .frames ? max(1, step.guide?.frames.count ?? 1) : 1
        let ink = LearnInk(frameCount: count)
        inks[step.id] = ink
        // Finished lines (not the live one) update buttons like Check.
        watchers[step.id] = ink.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return ink
    }
}

// MARK: - Touch input

/// Reads Apple Pencil and finger touches (with pressure and tilt), smooths them with Gale's stabilizer,
/// and hands them on in lesson units.
final class LearnTouchView: UIView {
    var aspect: Double = LearnGuide.defaultAspect
    var smoothing: Double = 0.25
    var isDrawingEnabled = true

    var onBegin: ((LearnPoint, Double) -> Void)?
    var onAdd: (([(LearnPoint, Double)]) -> Void)?
    var onEnd: (([(LearnPoint, Double)]) -> Void)?
    var onCancel: (() -> Void)?

    private var activeTouch: UITouch?
    private var stabilizer: StrokeStabilizer?
    private var strokeStart: TimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    private var space: LearnSpace { LearnSpace(size: bounds.size, aspect: aspect) }

    private func sample(_ touch: UITouch) -> StrokePoint {
        let loc = touch.preciseLocation(in: self)
        var pressure = 0.5
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            pressure = Double(touch.force / touch.maximumPossibleForce)
        } else if touch.force > 0, touch.maximumPossibleForce > 0 {
            pressure = 0.3 + 0.7 * Double(touch.force / touch.maximumPossibleForce)
        }
        let altitude = touch.type == .pencil ? Double(touch.altitudeAngle) : .pi / 2
        let azimuth = touch.type == .pencil ? Double(touch.azimuthAngle(in: self)) : 0
        return StrokePoint(x: Double(loc.x), y: Double(loc.y), pressure: min(1, max(0.05, pressure)),
                           altitude: altitude, azimuth: azimuth, time: max(0, touch.timestamp - strokeStart))
    }

    private func convert(_ pts: [StrokePoint]) -> [(LearnPoint, Double)] {
        let sp = space
        return pts.map { (sp.unit(CGPoint(x: $0.x, y: $0.y)), $0.pressure) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, activeTouch == nil,
              let touch = touches.first(where: { $0.type == .pencil || $0.type == .direct }) else { return }
        activeTouch = touch
        strokeStart = touch.timestamp
        let st = StrokeStabilizer(amount: smoothing, scale: 1)
        stabilizer = st
        let first = convert(st.begin(sample(touch)))
        if let p = first.first { onBegin?(p.0, p.1) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let st = stabilizer else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        var out: [StrokePoint] = []
        for t in samples { out += st.add(sample(t)) }
        let pts = convert(out)
        if !pts.isEmpty { onAdd?(pts) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let st = stabilizer else { return }
        var out = st.add(sample(touch))
        out += st.end()
        activeTouch = nil
        stabilizer = nil
        onEnd?(convert(out))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        stabilizer = nil
        onCancel?()
    }
}

/// Puts the touch view into SwiftUI and sends its lines into a `LearnInk`.
struct LearnTouchSurface: UIViewRepresentable {
    let ink: LearnInk
    let aspect: Double
    var smoothing: Double = 0.25
    var enabled = true

    func makeUIView(context: Context) -> LearnTouchView {
        let v = LearnTouchView(frame: .zero)
        configure(v)
        return v
    }

    func updateUIView(_ v: LearnTouchView, context: Context) {
        configure(v)
    }

    private func configure(_ v: LearnTouchView) {
        v.aspect = aspect
        v.smoothing = smoothing
        v.isDrawingEnabled = enabled
        let ink = self.ink
        v.onBegin = { p, pressure in ink.begin(p, pressure: pressure) }
        v.onAdd = { pts in ink.add(pts) }
        v.onEnd = { pts in ink.end(pts) }
        v.onCancel = { ink.cancel() }
        v.accessibilityLabel = "Drawing area"
    }
}

// MARK: - Showing ink

enum LearnInkDraw {
    /// Base line width in lesson units (pressure makes it thinner or thicker).
    static let width = 0.011

    static func strokes(_ strokes: [LearnInkStroke], in ctx: inout GraphicsContext, space: LearnSpace,
                        color: Color, widthScale: CGFloat = 1) {
        for s in strokes { stroke(s, in: &ctx, space: space, color: color, widthScale: widthScale) }
    }

    static func stroke(_ s: LearnInkStroke, in ctx: inout GraphicsContext, space: LearnSpace,
                       color: Color, widthScale: CGFloat = 1) {
        let base = CGFloat(width) * space.scale * widthScale
        func w(_ i: Int) -> CGFloat {
            let p = s.pressures.indices.contains(i) ? s.pressures[i] : 0.5
            return max(1, base * CGFloat(0.45 + 1.1 * p))
        }
        guard let first = s.points.first else { return }
        if s.points.count == 1 {
            let c = space.point(first)
            let r = w(0) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            return
        }
        for i in 1..<s.points.count {
            var seg = Path()
            seg.move(to: space.point(s.points[i - 1]))
            seg.addLine(to: space.point(s.points[i]))
            ctx.stroke(seg, with: .color(color),
                       style: StrokeStyle(lineWidth: (w(i - 1) + w(i)) / 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The finished lines of one page.
struct LearnInkCanvas: View {
    let strokes: [LearnInkStroke]
    let aspect: Double
    var color: Color = LearnPalette.ink
    var widthScale: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            LearnInkDraw.strokes(strokes, in: &ctx, space: LearnSpace(size: size, aspect: aspect),
                                 color: color, widthScale: widthScale)
        }
        .allowsHitTesting(false)
    }
}

/// The line being drawn right now.
struct LearnLiveCanvas: View {
    @ObservedObject var live: LearnLiveInk
    let aspect: Double

    var body: some View {
        let stroke = live.stroke
        Canvas { ctx, size in
            if let s = stroke {
                LearnInkDraw.stroke(s, in: &ctx, space: LearnSpace(size: size, aspect: aspect), color: LearnPalette.ink)
            }
        }
        .allowsHitTesting(false)
    }
}
