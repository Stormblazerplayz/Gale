import GaleCore
import GaleFormat
import SwiftUI
import UIKit

// MARK: - The stabilizer card in brush settings

/// Smoothing strength, "Keep corners sharp", a before and after of your last line, and the stabilizer test.
struct StabilizerSection: View {
    @ObservedObject var model: EditorModel
    @State private var showTest = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Smoothing")
                    if let c = model.calibration {
                        TunedBadge(result: c)
                    }
                    Spacer()
                    Button("Reset") { model.smoothing = StrokeSmoothing.defaultAmount }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                        .disabled(abs(model.smoothing - StrokeSmoothing.defaultAmount) < 0.005)
                        .accessibilityIdentifier("smoothingReset")
                }
                SmoothingControl(value: $model.smoothing, compact: false)
                BeforeAfterPreview(raw: model.lastRawLine, amount: model.smoothing, sharpCorners: model.sharpCorners,
                                   emptyText: "Draw a line on your canvas to see it here, before and after smoothing.")
                    .frame(height: 120)
            }
            .padding(.vertical, 4)

            Toggle(isOn: $model.sharpCorners) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep corners sharp")
                        Text("Zigzags, boxes and stars stay crisp, even with strong smoothing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "triangle")
                        .foregroundStyle(Theme.accent)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("sharpCorners")

            Button { showTest = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.gradient)
                        Image(systemName: "hand.draw.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.calibration == nil ? "Test my hand" : "Test my hand again")
                            .foregroundStyle(.primary)
                        Text("Trace 4 shapes and Gale picks the smoothing for you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("stabilizerTest")
        } footer: {
            Text("Off draws exactly where you touch. Turn it up if your lines come out shaky. Small strokes like eyes keep their shape either way.")
        }
        .sheet(isPresented: $showTest) {
            StabilizerCalibrationView(model: model)
        }
    }
}

/// "Tuned: Steady" after you've taken the stabilizer test.
struct TunedBadge: View {
    var result: StabilizerCalibration.Result

    var body: some View {
        Label("Tuned: \(result.level)", systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .accessibilityIdentifier("tunedBadge")
    }
}

// MARK: - Before and after

/// Your own line as you drew it, next to how Gale smooths it.
struct BeforeAfterPreview: View {
    /// Raw touches, in screen points.
    var raw: [StrokePoint]
    var amount: Double
    var sharpCorners: Bool
    var emptyText: String

    var body: some View {
        if raw.count < 2 {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                Label(emptyText, systemImage: "scribble.variable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .accessibilityIdentifier("beforeAfterEmpty")
        } else {
            let smoothed = StrokeSmoothing.finish(raw, amount: amount, adaptive: sharpCorners)
            HStack(spacing: 8) {
                LinePanel(title: "Before", points: raw, frameOf: raw, color: .secondary)
                LinePanel(title: "After", points: smoothed, frameOf: raw, color: Theme.accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your last line before and after smoothing")
            .accessibilityIdentifier("beforeAfter")
        }
    }
}

/// One line fitted into a little panel. `frameOf` sets the framing, so before and after line up exactly.
private struct LinePanel: View {
    var title: String
    var points: [StrokePoint]
    var frameOf: [StrokePoint]
    var color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
            Canvas { ctx, size in
                guard let fit = Fit(frameOf, in: size, padding: 14) else { return }
                var path = Path()
                for (i, p) in points.enumerated() {
                    let q = fit.map(p)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
        }
    }
}

/// Fits a line's bounds into a size, keeping its shape.
private struct Fit {
    var scale: CGFloat
    var dx: CGFloat
    var dy: CGFloat

    init?(_ pts: [StrokePoint], in size: CGSize, padding: CGFloat) {
        guard let first = pts.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let w = max(1, maxX - minX), h = max(1, maxY - minY)
        let availW = max(1, size.width - padding * 2), availH = max(1, size.height - padding * 2 - 8)
        scale = min(availW / CGFloat(w), availH / CGFloat(h))
        dx = (size.width - CGFloat(w) * scale) / 2 - CGFloat(minX) * scale
        dy = (size.height + 8 - CGFloat(h) * scale) / 2 - CGFloat(minY) * scale
    }

    func map(_ p: StrokePoint) -> CGPoint { CGPoint(x: CGFloat(p.x) * scale + dx, y: CGFloat(p.y) * scale + dy) }
}

// MARK: - The stabilizer test

/// Trace four shapes; Gale measures how much your hand shakes and picks the smoothing that suits you.
struct StabilizerCalibrationView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var lines: [[StrokePoint]] = []
    @State private var note: String?
    @State private var result: StabilizerCalibration.Result?
    @State private var tryAmount = StrokeSmoothing.defaultAmount
    @State private var clearToken = 0

    private let guides = StabilizerCalibration.guides

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    ResultView(result: result, lines: lines, tryAmount: $tryAmount, sharpCorners: model.sharpCorners,
                               use: { use(result) }, again: restart)
                } else {
                    tracing
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .navigationTitle("Stabilizer test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closeCalibration")
                }
            }
        }
    }

    private var tracing: some View {
        VStack(spacing: 16) {
            StepDots(count: guides.count, done: step)
            VStack(spacing: 4) {
                Text("\(step + 1) of \(guides.count): \(guides[step].title)")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("calibrationStep")
                Text(guides[step].tip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            GuidePad(guide: guides[step], clearToken: clearToken) { pts in finished(pts) }
                .id(step)
            Group {
                if let note {
                    Label(note, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Trace on top of the dotted shape, at your normal speed. Pencil or finger both work.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .frame(minHeight: 36)
            if lines.count >= StabilizerCalibration.minLines {
                Button("Skip the rest and see my result") { showResult() }
                    .font(.footnote)
                    .accessibilityIdentifier("calibrationFinishEarly")
            }
        }
    }

    private func finished(_ pts: [StrokePoint]) {
        guard StabilizerCalibration.lineShake(pts) != nil else {
            note = "That line was too short to measure. Trace the whole shape in one go."
            clearToken += 1
            return
        }
        note = nil
        lines.append(pts)
        if step + 1 < guides.count {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { step += 1 }
        } else {
            showResult()
        }
    }

    private func showResult() {
        guard let r = StabilizerCalibration.measure(lines) else {
            note = "Gale needs at least \(StabilizerCalibration.minLines) full shapes to measure. Keep going."
            return
        }
        tryAmount = r.amount
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { result = r }
    }

    private func use(_ r: StabilizerCalibration.Result) {
        var tuned = r
        tuned.amount = tryAmount
        model.calibration = tuned
        model.smoothing = tryAmount
        dismiss()
    }

    private func restart() {
        withAnimation {
            result = nil
            lines = []
            step = 0
            note = nil
            clearToken += 1
        }
    }
}

/// Little capsules that fill in as you trace each shape.
private struct StepDots: View {
    var count: Int
    var done: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i < done ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(i == done ? 0.45 : 0.18)))
                    .frame(width: i == done ? 28 : 16, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: done)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shape \(min(done + 1, count)) of \(count)")
    }
}

/// The shape to trace: a dotted guide with a glowing dot that shows the way, and a pad that catches your touches.
private struct GuidePad: View {
    var guide: StabilizerCalibration.Guide
    var clearToken: Int
    var onLine: ([StrokePoint]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let height = min(geo.size.height, geo.size.width / StabilizerCalibration.aspect)
            let width = height * StabilizerCalibration.aspect
            let path = guidePath(height: height)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                path.stroke(Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round, dash: [0.1, 16]))
                startMarker(height: height)
                if reduceMotion || UITestMode.on {
                    pacer(at: 0, path: path, height: height)
                } else {
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.2
                        pacer(at: min(1, t), path: path, height: height)
                    }
                }
                TracePad(clearToken: clearToken, onLine: onLine)
                    .accessibilityIdentifier("calibrationPad")
            }
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(StabilizerCalibration.aspect, contentMode: .fit)
    }

    private func guidePath(height: CGFloat) -> Path {
        var p = Path()
        for (i, v) in guide.points.enumerated() {
            let q = CGPoint(x: CGFloat(v.x) * height, y: CGFloat(v.y) * height)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }

    private func startMarker(height: CGFloat) -> some View {
        let s = guide.points.first ?? .zero
        return Circle()
            .stroke(Theme.accent, lineWidth: 2)
            .frame(width: 18, height: 18)
            .position(x: CGFloat(s.x) * height, y: CGFloat(s.y) * height)
    }

    /// The glowing dot that runs along the guide, with a short trail behind it.
    @ViewBuilder
    private func pacer(at t: Double, path: Path, height: CGFloat) -> some View {
        let i = min(guide.points.count - 1, max(0, Int((t * Double(guide.points.count - 1)).rounded())))
        let v = guide.points[i]
        ZStack {
            path.trimmedPath(from: CGFloat(max(0, t - 0.18)), to: CGFloat(t))
                .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                .opacity(0.55)
            Circle()
                .fill(Theme.accent.opacity(0.25))
                .frame(width: 30, height: 30)
                .position(x: CGFloat(v.x) * height, y: CGFloat(v.y) * height)
            Circle()
                .fill(Theme.accent)
                .frame(width: 12, height: 12)
                .position(x: CGFloat(v.x) * height, y: CGFloat(v.y) * height)
        }
        .allowsHitTesting(false)
    }
}

/// Catches one line of raw touches (finger or Pencil) and shows your ink as you trace.
private struct TracePad: UIViewRepresentable {
    var clearToken: Int
    var onLine: ([StrokePoint]) -> Void

    func makeUIView(context: Context) -> TracePadView {
        let v = TracePadView()
        v.onLine = onLine
        v.lastToken = clearToken
        return v
    }

    func updateUIView(_ v: TracePadView, context: Context) {
        v.onLine = onLine
        if v.lastToken != clearToken {
            v.lastToken = clearToken
            v.clear()
        }
    }
}

final class TracePadView: UIView {
    var onLine: (([StrokePoint]) -> Void)?
    var lastToken = 0
    private var points: [StrokePoint] = []
    private var active: UITouch?
    private let ink = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        ink.fillColor = nil
        ink.strokeColor = UIColor(Theme.accent).cgColor
        ink.lineWidth = 4
        ink.lineCap = .round
        ink.lineJoin = .round
        layer.addSublayer(ink)
        isAccessibilityElement = true
        accessibilityLabel = "Tracing area"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        ink.frame = bounds
    }

    func clear() {
        points = []
        active = nil
        ink.path = nil
    }

    private func point(_ t: UITouch) -> StrokePoint {
        let p = t.location(in: self)
        let force = t.maximumPossibleForce > 0 ? Double(t.force / t.maximumPossibleForce) : 0.5
        return StrokePoint(x: Double(p.x), y: Double(p.y), pressure: force > 0 ? force : 0.5, time: t.timestamp)
    }

    private func redraw() {
        let path = UIBezierPath()
        for (i, p) in points.enumerated() {
            let q = CGPoint(x: p.x, y: p.y)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.path = path.cgPath
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, let t = touches.first else { return }
        active = t
        points = [point(t)]
        redraw()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let a = active, touches.contains(a) else { return }
        for c in event?.coalescedTouches(for: a) ?? [a] { points.append(point(c)) }
        redraw()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let a = active, touches.contains(a) else { return }
        let last = point(a)
        if let prev = points.last, prev.x != last.x || prev.y != last.y { points.append(last) }
        active = nil
        let line = points
        onLine?(line)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let a = active, touches.contains(a) else { return }
        clear()
    }
}

/// How steady your hand is, what Gale recommends, and your own line before and after.
private struct ResultView: View {
    var result: StabilizerCalibration.Result
    var lines: [[StrokePoint]]
    @Binding var tryAmount: Double
    var sharpCorners: Bool
    var use: () -> Void
    var again: () -> Void
    @State private var shown = 0.0

    /// The line that shows smoothing best: the wave if you traced it, otherwise the longest.
    private var showcase: [StrokePoint] {
        if lines.count > 2 { return lines[2] }
        return lines.max { $0.count < $1.count } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: shown)
                            .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(result.steadiness)")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("steady")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 128, height: 128)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Steadiness \(result.steadiness) out of 100")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.level)
                            .font(.title2.weight(.bold))
                            .accessibilityIdentifier("calibrationLevel")
                        Text("Gale recommends \(StrokeSmoothing.label(result.amount)) smoothing for your hand.")
                            .foregroundStyle(.secondary)
                        if sharpCorners {
                            Label("Corners stay sharp", systemImage: "triangle")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your line, before and after")
                        .font(.headline)
                    BeforeAfterPreview(raw: showcase, amount: tryAmount, sharpCorners: sharpCorners, emptyText: "")
                        .frame(height: 150)
                    HStack {
                        Text("Try it")
                            .font(.subheadline)
                        SmoothingControl(value: $tryAmount, compact: false)
                    }
                    if abs(tryAmount - result.amount) > 0.005 {
                        Button("Back to the recommended \(StrokeSmoothing.label(result.amount))") { tryAmount = result.amount }
                            .font(.footnote)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))

                VStack(spacing: 10) {
                    Button(action: use) {
                        Text("Use \(StrokeSmoothing.label(tryAmount))")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("useCalibration")
                    Button("Try again", action: again)
                        .accessibilityIdentifier("calibrationAgain")
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { shown = Double(result.steadiness) / 100 }
        }
    }
}
