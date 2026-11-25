import Foundation

/// The result of one check.
public struct LearnCheckOutcome: Hashable, Sendable {
    public var type: LearnCheckType
    public var passed: Bool
    /// What to fix (or what went well).
    public var message: String
    /// How well it went (0...1).
    public var quality: Double

    public init(type: LearnCheckType, passed: Bool, message: String, quality: Double) {
        self.type = type
        self.passed = passed
        self.message = message
        self.quality = quality
    }
}

/// The result of handing in a step.
public struct LearnEvaluation: Hashable, Sendable {
    public var passed: Bool
    /// How well it went (0...1). Turns into stars.
    public var quality: Double
    public var outcomes: [LearnCheckOutcome]
    /// The first thing to fix, or a cheer when it passed.
    public var message: String

    public init(passed: Bool, quality: Double, outcomes: [LearnCheckOutcome], message: String) {
        self.passed = passed
        self.quality = quality
        self.outcomes = outcomes
        self.message = message
    }
}

/// Measurements used by the checks. All in lesson units.
public enum LearnMeasure {
    /// Strokes shorter than this are ignored by shape checks (taps and dots).
    static let minShapeLength = 0.05

    /// Biggest bend of a stroke: how far it strays from the straight line between its ends,
    /// as a share of that line's length. 0 = perfectly straight.
    public static func bend(_ stroke: [LearnPoint]) -> Double {
        guard stroke.count > 2, let a = stroke.first, let b = stroke.last else { return 0 }
        let chord = a.distance(to: b)
        guard chord > 1e-6 else { return .infinity }
        var worst = 0.0
        for p in stroke { worst = max(worst, LearnGeometry.distanceToSegment(p, a, b)) }
        return worst / chord
    }

    /// Biggest gap at a line end: each end should touch another end (of the same line or another one).
    public static func endGap(_ strokes: [[LearnPoint]]) -> Double {
        var ends: [(LearnPoint, Int, Bool)] = []
        for (i, s) in strokes.enumerated() where LearnGeometry.length(s) >= 0.02 {
            if let a = s.first, let b = s.last {
                ends.append((a, i, true))
                ends.append((b, i, false))
            }
        }
        guard !ends.isEmpty else { return .infinity }
        var worst = 0.0
        for (k, e) in ends.enumerated() {
            var best = Double.infinity
            for (j, o) in ends.enumerated() where j != k {
                best = min(best, e.0.distance(to: o.0))
            }
            worst = max(worst, best)
        }
        return worst
    }

    /// How wobbly a stroke is: the average distance from each point to the local average of its
    /// neighbours, in units of the sampling step. A clean curve is close to 0; a shaky line is
    /// well above 0.5.
    public static func wobble(_ stroke: [LearnPoint]) -> Double {
        let step = 0.01
        let pts = LearnGeometry.resample(stroke, spacing: step)
        let r = 4
        guard pts.count > 2 * r + 2 else { return 0 }
        var sum = 0.0
        var n = 0
        for i in r..<(pts.count - r) {
            var sx = 0.0, sy = 0.0
            for k in (i - r)...(i + r) {
                sx += pts[k].x
                sy += pts[k].y
            }
            let avg = LearnPoint(sx / Double(2 * r + 1), sy / Double(2 * r + 1))
            sum += pts[i].distance(to: avg)
            n += 1
        }
        return n > 0 ? (sum / Double(n)) / step : 0
    }

    /// Gaps between the middles of neighbouring frames.
    public static func spacing(_ frames: [[[LearnPoint]]]) -> [Double]? {
        var centers: [LearnPoint] = []
        for f in frames {
            guard let c = LearnGeometry.centroid(f) else { return nil }
            centers.append(c)
        }
        guard centers.count > 1 else { return nil }
        return (1..<centers.count).map { centers[$0 - 1].distance(to: centers[$0]) }
    }

    /// Whether a list of gaps fits the wanted spacing.
    public static func matches(_ gaps: [Double], _ kind: LearnSpacing) -> Bool {
        let n = gaps.count
        guard n >= 2 else { return false }
        func mean(_ s: ArraySlice<Double>) -> Double { s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count) }
        switch kind {
        case .even:
            let m = mean(gaps[...])
            guard m > 1e-6 else { return false }
            return gaps.allSatisfy { $0 >= 0.45 * m && $0 <= 1.7 * m }
        case .easeIn:
            let first = mean(gaps[0..<(n / 2)])
            let second = mean(gaps[((n + 1) / 2)..<n])
            return second >= 1.25 * first && gaps[n - 1] > gaps[0]
        case .easeOut:
            let first = mean(gaps[0..<(n / 2)])
            let second = mean(gaps[((n + 1) / 2)..<n])
            return first >= 1.25 * second && gaps[0] > gaps[n - 1]
        case .easeInOut:
            guard n >= 3 else { return false }
            let middle = mean(gaps[1..<(n - 1)])
            return middle >= 1.25 * max(gaps[0], gaps[n - 1])
        }
    }
}

/// Checks a step's answer.
public enum LearnEvaluator {
    /// Checks an answer against a step.
    public static func evaluate(_ step: LearnStep, answer: LearnAnswer) -> LearnEvaluation {
        switch step.kind {
        case .read, .tool, .watch:
            return LearnEvaluation(passed: true, quality: 1, outcomes: [], message: "Nice!")
        case .quiz:
            return evaluateQuiz(step, answer: answer)
        case .trace:
            var strokes: [[LearnPoint]] = []
            switch answer {
            case .strokes(let s): strokes = s
            case .frames(let f): strokes = f.first ?? []
            default: strokes = []
            }
            return evaluateTrace(step, strokes: strokes)
        case .frames, .animate:
            var frames: [[[LearnPoint]]] = []
            switch answer {
            case .frames(let f): frames = f
            case .strokes(let s): frames = [s]
            default: frames = []
            }
            return evaluateFrames(step, frames: frames)
        }
    }

    /// The answer a perfect learner would give: the guide's own ink lines (or the right choice).
    public static func perfectAnswer(for step: LearnStep) -> LearnAnswer {
        switch step.kind {
        case .read, .tool, .watch:
            return .done
        case .quiz:
            return .choice(step.quiz?.answer ?? 0)
        case .trace:
            return .strokes(step.guide?.frames.first?.inkStrokes ?? [])
        case .frames, .animate:
            return .frames(step.guide?.frames.map(\.inkStrokes) ?? [])
        }
    }

    static func praise(_ quality: Double) -> String {
        if quality >= 0.9 { return "Excellent! That's spot on." }
        if quality >= 0.75 { return "Great job!" }
        return "You got it!"
    }

    static func finish(_ outcomes: [LearnCheckOutcome], quality: Double) -> LearnEvaluation {
        let failed = outcomes.first { !$0.passed }
        let q = max(0, min(1, quality))
        return LearnEvaluation(passed: failed == nil, quality: q, outcomes: outcomes,
                               message: failed?.message ?? praise(q))
    }

    static func evaluateQuiz(_ step: LearnStep, answer: LearnAnswer) -> LearnEvaluation {
        guard let quiz = step.quiz, case .choice(let picked) = answer else {
            return LearnEvaluation(passed: false, quality: 0, outcomes: [], message: "Pick an answer first.")
        }
        if picked == quiz.answer {
            return LearnEvaluation(passed: true, quality: 1, outcomes: [], message: "Right! \(quiz.explain)")
        }
        return LearnEvaluation(passed: false, quality: 0, outcomes: [], message: "Not quite. Have another think and try again.")
    }

    static func evaluateTrace(_ step: LearnStep, strokes: [[LearnPoint]]) -> LearnEvaluation {
        let guide = step.guide
        let aspect = guide?.aspect ?? LearnGuide.defaultAspect
        let target = guide?.frames.first?.inkStrokes ?? []
        let drawn = strokes.filter { !$0.isEmpty }
        guard !drawn.isEmpty else {
            return LearnEvaluation(passed: false, quality: 0, outcomes: [], message: "Draw on the page first.")
        }
        var outcomes: [LearnCheckOutcome] = []
        var quality = 1.0
        for check in step.checks {
            switch check.type {
            case .trace:
                let o = traceOutcome(check, target: target, drawn: drawn, aspect: aspect, frameLabel: nil)
                quality = o.quality
                outcomes.append(o)
            case .straight, .closed, .smooth:
                outcomes.append(shapeOutcome(check, strokes: drawn))
            case .frameCount, .spacing, .loop:
                continue
            }
        }
        return finish(outcomes, quality: quality)
    }

    static func evaluateFrames(_ step: LearnStep, frames rawFrames: [[[LearnPoint]]]) -> LearnEvaluation {
        guard let guide = step.guide, !guide.frames.isEmpty else {
            return LearnEvaluation(passed: false, quality: 0, outcomes: [], message: "This step has no guide.")
        }
        let count = guide.frames.count
        var frames = rawFrames.map { $0.filter { !$0.isEmpty } }
        if frames.count > count { frames = Array(frames.prefix(count)) }
        while frames.count < count { frames.append([]) }
        let drawnCount = frames.filter { !$0.isEmpty }.count
        guard drawnCount > 0 else {
            return LearnEvaluation(passed: false, quality: 0, outcomes: [], message: "Draw on frame 1 first.")
        }
        var outcomes: [LearnCheckOutcome] = []
        var quality = 1.0
        for check in step.checks {
            switch check.type {
            case .trace:
                let o = framesTraceOutcome(check, guide: guide, frames: frames)
                quality = o.quality
                outcomes.append(o)
            case .straight, .closed, .smooth:
                outcomes.append(shapeOutcome(check, strokes: frames.flatMap { $0 }))
            case .frameCount:
                let lo = check.minFrames ?? count
                let hi = check.maxFrames ?? count
                let ok = drawnCount >= lo && drawnCount <= hi
                let msg: String
                if ok {
                    msg = "All \(drawnCount) frames are drawn."
                } else if drawnCount < lo {
                    let missing = frames.firstIndex { $0.isEmpty }.map { " Frame \($0 + 1) is still empty." } ?? ""
                    msg = "Draw on \(lo == hi ? "all \(lo)" : "at least \(lo)") frames.\(missing)"
                } else {
                    msg = "Use at most \(hi) frames."
                }
                outcomes.append(LearnCheckOutcome(type: .frameCount, passed: ok, message: msg, quality: ok ? 1 : 0))
            case .spacing:
                let kind = check.spacing ?? .even
                let drawnFrames = frames.filter { !$0.isEmpty }
                var ok = false
                var msg = "Draw every frame so the spacing can be checked."
                if drawnFrames.count == count, let gaps = LearnMeasure.spacing(drawnFrames) {
                    let moved = gaps.reduce(0, +)
                    if moved < 0.04 {
                        msg = "Your drawing barely moves. Move it a bit further each frame."
                    } else {
                        ok = LearnMeasure.matches(gaps, kind)
                        msg = ok ? "Nice spacing!" : "Check the spacing: it should have \(kind.words)."
                    }
                }
                outcomes.append(LearnCheckOutcome(type: .spacing, passed: ok, message: msg, quality: ok ? 1 : 0))
            case .loop:
                var ok = false
                var msg = "Draw every frame so the loop can be checked."
                if drawnCount == count, count >= 3 {
                    var steps: [Double] = []
                    for i in 1..<count { steps.append(LearnGeometry.chamfer(frames[i - 1], frames[i])) }
                    let wrap = LearnGeometry.chamfer(frames[count - 1], frames[0])
                    let sorted = steps.sorted()
                    let median = sorted[sorted.count / 2]
                    let limit = (check.value ?? LearnCheck.defaultLoop) * median + 0.015
                    ok = wrap <= limit
                    msg = ok ? "It loops smoothly." : "The last frame jumps when it goes back to frame 1. Make it lead into frame 1."
                }
                outcomes.append(LearnCheckOutcome(type: .loop, passed: ok, message: msg, quality: ok ? 1 : 0))
            }
        }
        return finish(outcomes, quality: quality)
    }

    static func traceOutcome(_ check: LearnCheck, target: [[LearnPoint]], drawn: [[LearnPoint]], aspect: Double,
                             frameLabel: String?) -> LearnCheckOutcome {
        let cov = check.coverage ?? LearnCheck.defaultCoverage
        let acc = check.accuracy ?? LearnCheck.defaultAccuracy
        let r = LearnTraceScorer.score(guide: target, strokes: drawn, tolerance: check.tolerance ?? LearnCheck.defaultTolerance,
                                       aspect: aspect)
        let ok = r.passes(minCoverage: cov, minAccuracy: acc)
        var msg = LearnTraceScorer.hint(for: r, minCoverage: cov, minAccuracy: acc) ?? praise(r.score)
        if let label = frameLabel, !ok { msg = "\(label): \(msg)" }
        return LearnCheckOutcome(type: .trace, passed: ok, message: msg, quality: r.score)
    }

    static func framesTraceOutcome(_ check: LearnCheck, guide: LearnGuide, frames: [[[LearnPoint]]]) -> LearnCheckOutcome {
        let cov = check.coverage ?? LearnCheck.defaultCoverage
        let acc = check.accuracy ?? LearnCheck.defaultAccuracy
        let tol = check.tolerance ?? LearnCheck.defaultTolerance
        var covSum = 0.0, accSum = 0.0, scoreSum = 0.0
        var worst: (index: Int, result: LearnTraceResult)?
        var anyScribble = false
        for (i, f) in guide.frames.enumerated() {
            let drawn = i < frames.count ? frames[i] : []
            let r = LearnTraceScorer.score(guide: f.inkStrokes, strokes: drawn, tolerance: tol, aspect: guide.aspect)
            covSum += r.coverage
            accSum += r.accuracy
            scoreSum += r.score
            if r.isScribble { anyScribble = true }
            if worst == nil || r.score < worst!.result.score { worst = (i, r) }
        }
        let n = Double(max(1, guide.frames.count))
        let meanCov = covSum / n
        let meanAcc = accSum / n
        let floorOK = (worst?.result.coverage ?? 0) >= cov * 0.6 && (worst?.result.accuracy ?? 0) >= acc * 0.6
        let ok = meanCov >= cov && meanAcc >= acc && floorOK && !anyScribble
        var msg = praise(scoreSum / n)
        if !ok, anyScribble, let i = frames.indices.first(where: { k in
            k < guide.frames.count && LearnTraceScorer.score(guide: guide.frames[k].inkStrokes, strokes: frames[k],
                                                             tolerance: tol, aspect: guide.aspect).isScribble
        }) {
            msg = "Frame \(i + 1): That's a lot of extra lines! Trace just the guide."
        } else if !ok, let w = worst {
            let inner = LearnTraceScorer.hint(for: w.result, minCoverage: cov, minAccuracy: acc)
                ?? "Match the guide a little more closely."
            msg = "Frame \(w.index + 1): \(inner)"
        }
        return LearnCheckOutcome(type: .trace, passed: ok, message: msg, quality: scoreSum / n)
    }

    static func shapeOutcome(_ check: LearnCheck, strokes: [[LearnPoint]]) -> LearnCheckOutcome {
        let shapes = strokes.filter { LearnGeometry.length($0) >= LearnMeasure.minShapeLength }
        switch check.type {
        case .straight:
            let limit = check.value ?? LearnCheck.defaultStraight
            let worst = shapes.map(LearnMeasure.bend).max() ?? .infinity
            let ok = worst <= limit
            return LearnCheckOutcome(type: .straight, passed: ok,
                                     message: ok ? "Nice and straight." : "That line bends. Try one quick, steady pull from start to end.",
                                     quality: ok ? 1 : 0)
        case .closed:
            let limit = check.value ?? LearnCheck.defaultClosedGap
            let gap = LearnMeasure.endGap(shapes)
            let ok = gap <= limit
            return LearnCheckOutcome(type: .closed, passed: ok,
                                     message: ok ? "The shape is closed." : "There's a gap where the ends should meet. Close the shape.",
                                     quality: ok ? 1 : 0)
        case .smooth:
            let limit = check.value ?? LearnCheck.defaultSmooth
            let worst = shapes.map(LearnMeasure.wobble).max() ?? .infinity
            let ok = worst <= limit
            return LearnCheckOutcome(type: .smooth, passed: ok,
                                     message: ok ? "Smooth line." : "The line is a bit wobbly. Draw a little faster, or turn the stabilizer up.",
                                     quality: ok ? 1 : 0)
        default:
            return LearnCheckOutcome(type: check.type, passed: true, message: "", quality: 1)
        }
    }
}
