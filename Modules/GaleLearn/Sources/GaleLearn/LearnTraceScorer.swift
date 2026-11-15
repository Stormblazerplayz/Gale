import Foundation

/// How well a drawing went over a guide.
public struct LearnTraceResult: Hashable, Sendable {
    /// Share of the guide lines that have the learner's ink close by (0...1).
    public var coverage: Double
    /// Share of the learner's ink that sits on a guide line (0...1).
    public var accuracy: Double
    /// Where the biggest missed part of the guide is.
    public var missedArea: LearnArea?
    /// Where the most ink wandered off the guide.
    public var strayArea: LearnArea?
    /// Length of the learner's ink divided by the length of the guide (about 1 for a clean trace).
    public var inkRatio: Double

    public init(coverage: Double, accuracy: Double, missedArea: LearnArea? = nil, strayArea: LearnArea? = nil,
                inkRatio: Double = 1) {
        self.coverage = coverage
        self.accuracy = accuracy
        self.missedArea = missedArea
        self.strayArea = strayArea
        self.inkRatio = inkRatio
    }

    /// Far more ink than the guide has: scribbling over everything, not tracing.
    public var isScribble: Bool { inkRatio > LearnTraceScorer.maxInkRatio }

    /// One number for the whole trace (the weaker of the two, and 0 for a scribble).
    public var score: Double { isScribble ? 0 : min(coverage, accuracy) }

    /// Whether the trace is good enough.
    public func passes(minCoverage: Double, minAccuracy: Double) -> Bool {
        !isScribble && coverage >= minCoverage && accuracy >= minAccuracy
    }
}

/// Scores a traced drawing against guide lines.
public enum LearnTraceScorer {
    /// Ink this far from the guide (times the tolerance) still counts as accurate.
    public static let accuracySlack = 1.25
    /// Drawing more than this many times the guide's length counts as scribbling.
    public static let maxInkRatio = 2.5

    /// - Parameters:
    ///   - guide: the lines to trace (usually the ink lines of a guide frame).
    ///   - strokes: what the learner drew, in lesson units.
    ///   - tolerance: how close counts as on the line.
    ///   - aspect: width of lesson space (for naming areas in hints).
    public static func score(guide: [[LearnPoint]], strokes: [[LearnPoint]], tolerance: Double = LearnCheck.defaultTolerance,
                             aspect: Double = LearnGuide.defaultAspect) -> LearnTraceResult {
        let tol = max(0.005, tolerance)
        let drawn = strokes.filter { !$0.isEmpty }
        let guideLines = guide.filter { $0.count > 1 }
        guard !guideLines.isEmpty else { return LearnTraceResult(coverage: 0, accuracy: 0) }
        let spacing = tol / 3

        // Coverage: walk along each guide line and see whether ink is nearby.
        var covered = 0
        var total = 0
        var bestRun: [LearnPoint] = []
        for line in guideLines {
            let samples = LearnGeometry.resample(line, spacing: spacing)
            var run: [LearnPoint] = []
            for p in samples {
                total += 1
                let near = !drawn.isEmpty && LearnGeometry.distance(p, toLines: drawn) <= tol
                if near {
                    covered += 1
                    if run.count > bestRun.count { bestRun = run }
                    run = []
                } else {
                    run.append(p)
                }
            }
            if run.count > bestRun.count { bestRun = run }
        }
        let coverage = total > 0 ? Double(covered) / Double(total) : 0

        // Accuracy: walk along the learner's ink and see whether a guide line is nearby.
        var onLine = 0
        var inkTotal = 0
        var worstStray: [LearnPoint] = []
        for line in drawn {
            let samples = line.count == 1 ? line : LearnGeometry.resample(line, spacing: spacing)
            var run: [LearnPoint] = []
            for p in samples {
                inkTotal += 1
                if LearnGeometry.distance(p, toLines: guideLines) <= tol * accuracySlack {
                    onLine += 1
                    if run.count > worstStray.count { worstStray = run }
                    run = []
                } else {
                    run.append(p)
                }
            }
            if run.count > worstStray.count { worstStray = run }
        }
        let accuracy = inkTotal > 0 ? Double(onLine) / Double(inkTotal) : 0

        // Name the places (ignore tiny misses at line ends).
        let guideLength = guideLines.reduce(0.0) { $0 + LearnGeometry.length($1) }
        let inkLength = drawn.reduce(0.0) { $0 + LearnGeometry.length($1) }
        let ratio = inkLength / max(1e-6, guideLength)

        let minRun = 3
        let missed = bestRun.count >= minRun ? LearnArea(point: middle(of: bestRun), aspect: aspect) : nil
        let stray = worstStray.count >= minRun ? LearnArea(point: middle(of: worstStray), aspect: aspect) : nil
        return LearnTraceResult(coverage: coverage, accuracy: accuracy, missedArea: missed, strayArea: stray,
                                inkRatio: ratio)
    }

    /// A short, friendly sentence about what to fix, or nil when the trace is good enough.
    public static func hint(for result: LearnTraceResult, minCoverage: Double, minAccuracy: Double) -> String? {
        if result.coverage <= 0.001 && result.accuracy <= 0.001 {
            return "Draw right on top of the gray guide line."
        }
        if result.isScribble {
            return "That's a lot of extra lines! Trace just the gray guide, going over each part once."
        }
        if result.coverage < minCoverage {
            if let area = result.missedArea {
                return "You missed part of the guide near \(area.words). Go over the whole gray line."
            }
            return "Go over the whole gray line, from one end to the other."
        }
        if result.accuracy < minAccuracy {
            if let area = result.strayArea {
                return "Some of your line wandered off the guide near \(area.words). Slow down a little and stay on the gray line."
            }
            return "Some of your line wandered off the guide. Stay on the gray line."
        }
        return nil
    }

    static func middle(of run: [LearnPoint]) -> LearnPoint {
        run.isEmpty ? .zero : run[run.count / 2]
    }
}
