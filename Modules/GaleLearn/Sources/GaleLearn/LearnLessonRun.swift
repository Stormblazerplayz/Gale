import Foundation

/// How one step of a lesson went.
public struct LearnStepRecord: Codable, Hashable, Sendable {
    /// Wrong tries so far.
    public var fails: Int = 0
    public var passed: Bool = false
    public var skipped: Bool = false
    /// Best stars for this step (0...3). Only scored steps earn stars.
    public var stars: Int = 0

    public init(fails: Int = 0, passed: Bool = false, skipped: Bool = false, stars: Int = 0) {
        self.fails = fails
        self.passed = passed
        self.skipped = skipped
        self.stars = stars
    }
}

/// What to show after handing in a step.
public struct LearnFeedback: Hashable, Sendable {
    public var passed: Bool
    /// A short headline ("Great job!", "Not quite").
    public var title: String
    public var message: String
    /// Extra help, shown after the first miss.
    public var hint: String?
    /// After three misses the step can be skipped.
    public var canSkip: Bool
    /// Stars for this try (0 when it didn't pass).
    public var stars: Int

    public init(passed: Bool, title: String, message: String, hint: String?, canSkip: Bool, stars: Int) {
        self.passed = passed
        self.title = title
        self.message = message
        self.hint = hint
        self.canSkip = canSkip
        self.stars = stars
    }
}

/// Plays through one lesson: hand in a step, get feedback, move on.
///
/// - A hint shows after the first miss.
/// - After three misses the step can be skipped (it then earns no stars).
/// - The lesson earns 1 to 3 stars from how its checked steps went.
public struct LearnLessonRun: Sendable {
    public static let failsBeforeHint = 1
    public static let failsBeforeSkip = 3

    public let lesson: LearnLesson
    public private(set) var index: Int = 0
    public private(set) var records: [LearnStepRecord]
    public private(set) var isFinished = false
    /// The last feedback for the current step (cleared when the step changes).
    public private(set) var feedback: LearnFeedback?

    public init(lesson: LearnLesson) {
        self.lesson = lesson
        records = Array(repeating: LearnStepRecord(), count: lesson.steps.count)
    }

    public var stepCount: Int { lesson.steps.count }
    public var step: LearnStep { lesson.steps[min(index, max(0, lesson.steps.count - 1))] }
    public var record: LearnStepRecord { records.isEmpty ? LearnStepRecord() : records[min(index, records.count - 1)] }
    public var isLastStep: Bool { index >= stepCount - 1 }
    public var canGoBack: Bool { index > 0 && !isFinished }

    /// Read and tool steps can always move on; checked steps once passed or skipped.
    public var canAdvance: Bool {
        guard !lesson.steps.isEmpty, !isFinished else { return false }
        return !step.kind.isScored || record.passed || record.skipped
    }

    public var showHint: Bool { record.fails >= LearnLessonRun.failsBeforeHint && !record.passed }
    public var canSkip: Bool { record.fails >= LearnLessonRun.failsBeforeSkip && !record.passed && !record.skipped }

    /// The hint for the current step.
    public var hint: String {
        if let h = step.hint, !h.isEmpty { return h }
        switch step.kind {
        case .trace: return "Go slowly at first and keep your line right on top of the gray guide."
        case .frames: return "Use the faint guide and the frosted onion skin of your last frame to line things up."
        case .quiz: return "Look at the animation again, then reread the question."
        case .read, .tool: return "Take your time."
        }
    }

    /// Share of the lesson done (0...1).
    public var progress: Double {
        guard stepCount > 0 else { return 1 }
        if isFinished { return 1 }
        let done = records.filter { $0.passed || $0.skipped }.count
        return Double(done) / Double(stepCount)
    }

    /// Hands in the current step.
    @discardableResult
    public mutating func submit(_ answer: LearnAnswer) -> LearnFeedback {
        guard !lesson.steps.isEmpty, !isFinished else {
            return LearnFeedback(passed: false, title: "Done", message: "This lesson is finished.", hint: nil, canSkip: false, stars: 0)
        }
        let s = step
        let result = LearnEvaluator.evaluate(s, answer: answer)
        var rec = records[index]
        let fb: LearnFeedback
        if result.passed {
            let stars = s.kind.isScored ? LearnLessonRun.stars(for: s.kind, quality: result.quality, fails: rec.fails) : 0
            rec.passed = true
            rec.stars = max(rec.stars, stars)
            fb = LearnFeedback(passed: true, title: LearnLessonRun.cheer(stars: stars, kind: s.kind),
                               message: result.message, hint: nil, canSkip: false, stars: stars)
        } else {
            if !rec.passed { rec.fails += 1 }
            let hintText: String? = rec.fails >= LearnLessonRun.failsBeforeHint ? hintFor(s) : nil
            let skip = rec.fails >= LearnLessonRun.failsBeforeSkip && !rec.passed
            fb = LearnFeedback(passed: false, title: "Not quite", message: result.message, hint: hintText, canSkip: skip, stars: 0)
        }
        records[index] = rec
        feedback = fb
        return fb
    }

    /// Moves to the next step, or finishes the lesson on the last one.
    @discardableResult
    public mutating func advance() -> Bool {
        guard canAdvance else { return false }
        if !step.kind.isScored { records[index].passed = true }
        feedback = nil
        if isLastStep {
            isFinished = true
        } else {
            index += 1
        }
        return true
    }

    /// Goes back one step (what you did there is kept).
    @discardableResult
    public mutating func back() -> Bool {
        guard canGoBack else { return false }
        index -= 1
        feedback = nil
        return true
    }

    /// Skips a step after three misses. It earns no stars.
    @discardableResult
    public mutating func skip() -> Bool {
        guard canSkip else { return false }
        records[index].skipped = true
        return advance()
    }

    /// Stars for the whole lesson (1...3).
    public var stars: Int {
        let scored = zip(lesson.steps, records).filter { $0.0.kind.isScored }
        guard !scored.isEmpty else { return 3 }
        let total = scored.reduce(0) { $0 + ($1.1.skipped && !$1.1.passed ? 0 : $1.1.stars) }
        let mean = Double(total) / Double(scored.count)
        return max(1, min(3, Int(mean.rounded())))
    }

    /// Stars for one passed step.
    public static func stars(for kind: LearnStepKind, quality: Double, fails: Int) -> Int {
        switch kind {
        case .quiz:
            return fails == 0 ? 3 : (fails == 1 ? 2 : 1)
        case .trace, .frames:
            var s = quality >= 0.9 ? 3 : (quality >= 0.75 ? 2 : 1)
            if fails >= 2 { s -= 1 }
            return max(1, s)
        case .read, .tool:
            return 0
        }
    }

    static func cheer(stars: Int, kind: LearnStepKind) -> String {
        guard kind.isScored else { return "Nice!" }
        switch stars {
        case 3: return "Perfect!"
        case 2: return "Great job!"
        default: return "You did it!"
        }
    }

    func hintFor(_ s: LearnStep) -> String {
        if let h = s.hint, !h.isEmpty { return h }
        return hint
    }
}
