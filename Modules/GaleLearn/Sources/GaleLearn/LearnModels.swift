import Foundation

// MARK: - Guides

/// A word or two placed on a guide drawing ("Squash!", "Contact").
public struct LearnNote: Codable, Hashable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double

    public init(text: String, x: Double, y: Double) {
        self.text = text
        self.x = x
        self.y = y
    }
}

/// One drawing of a guide animation.
public struct LearnGuideFrame: Codable, Hashable, Sendable {
    public var paths: [LearnPath]
    /// How many ticks this drawing stays on screen (1 = one frame).
    public var hold: Int
    public var notes: [LearnNote]

    public init(paths: [LearnPath], hold: Int = 1, notes: [LearnNote] = []) {
        self.paths = paths
        self.hold = hold
        self.notes = notes
    }

    /// The lines a learner should draw.
    public var inkPaths: [LearnPath] { paths.filter { $0.role == .ink } }
    /// The ink lines as plain point lists (what a perfect learner would draw).
    public var inkStrokes: [[LearnPoint]] { inkPaths.map(\.polyline) }

    enum CodingKeys: String, CodingKey { case paths, hold, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paths = try c.decodeIfPresent([LearnPath].self, forKey: .paths) ?? []
        hold = try c.decodeIfPresent(Int.self, forKey: .hold) ?? 1
        notes = try c.decodeIfPresent([LearnNote].self, forKey: .notes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        if hold != 1 { try c.encode(hold, forKey: .hold) }
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
    }
}

/// An animated (or still) drawing that shows how something is done.
public struct LearnGuide: Codable, Hashable, Sendable {
    /// Width divided by height. Lesson space is `aspect` wide and 1 tall.
    public var aspect: Double
    /// Frames per second for playback.
    public var fps: Int
    /// Play again from the start when it ends.
    public var loop: Bool
    /// Lines shown under every frame (ground, horizon, a still background). Never scored.
    public var background: [LearnPath]
    public var frames: [LearnGuideFrame]
    /// The point the eye follows (a ball's middle, a nose, a hand), one per frame. Empty = not tracked.
    /// Watch steps draw its trail and timing chart from these points.
    public var track: [LearnPoint]

    public static let defaultAspect = 4.0 / 3.0

    public init(aspect: Double = LearnGuide.defaultAspect, fps: Int = 12, loop: Bool = true,
                background: [LearnPath] = [], frames: [LearnGuideFrame], track: [LearnPoint] = []) {
        self.aspect = aspect
        self.fps = fps
        self.loop = loop
        self.background = background
        self.frames = frames
        self.track = track
    }

    /// The tracked point on a frame: the guide's own track point, or else the middle of the frame's ink.
    public func trackPoint(frame i: Int) -> LearnPoint? {
        guard frames.indices.contains(i) else { return nil }
        if track.count == frames.count { return track[i] }
        return LearnGeometry.centroid(frames[i].inkStrokes)
    }

    /// The first tick of a frame (holds before it added up).
    public func startTick(ofFrame i: Int) -> Int {
        frames.prefix(max(0, min(i, frames.count))).reduce(0) { $0 + max(1, $1.hold) }
    }

    /// Length of the animation in ticks (holds included).
    public var totalTicks: Int { frames.reduce(0) { $0 + max(1, $1.hold) } }

    /// Seconds for one play-through.
    public var duration: Double { Double(totalTicks) / Double(max(1, fps)) }

    /// Which frame shows at a tick (counting from 0). Loops or stops on the last frame.
    public func frameIndex(atTick tick: Int) -> Int {
        let total = totalTicks
        guard total > 0, !frames.isEmpty else { return 0 }
        var t = max(0, tick)
        if loop {
            t %= total
        } else if t >= total {
            return frames.count - 1
        }
        for (i, f) in frames.enumerated() {
            let h = max(1, f.hold)
            if t < h { return i }
            t -= h
        }
        return frames.count - 1
    }

    /// Which frame shows after `seconds` of playback.
    public func frameIndex(atTime seconds: Double, speed: Double = 1) -> Int {
        let ticks = Int((max(0, seconds) * Double(max(1, fps)) * max(0.05, speed)).rounded(.down))
        return frameIndex(atTick: ticks)
    }

    enum CodingKeys: String, CodingKey { case aspect, fps, loop, background, frames, track }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? LearnGuide.defaultAspect
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 12
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
        background = try c.decodeIfPresent([LearnPath].self, forKey: .background) ?? []
        frames = try c.decode([LearnGuideFrame].self, forKey: .frames)
        // The track is stored flat (x, y, x, y, ...) like path points.
        let flat = try c.decodeIfPresent([Double].self, forKey: .track) ?? []
        guard flat.count % 2 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .track, in: c, debugDescription: "track needs x, y pairs")
        }
        track = stride(from: 0, to: flat.count, by: 2).map { LearnPoint(flat[$0], flat[$0 + 1]) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(fps, forKey: .fps)
        try c.encode(loop, forKey: .loop)
        if !background.isEmpty { try c.encode(background, forKey: .background) }
        try c.encode(frames, forKey: .frames)
        if !track.isEmpty { try c.encode(track.flatMap { [$0.x, $0.y] }, forKey: .track) }
    }
}

// MARK: - Checks

/// The kinds of things a drawing step can check.
public enum LearnCheckType: String, Codable, Hashable, Sendable, CaseIterable {
    /// Goes over the guide lines (coverage) without wandering off (accuracy).
    case trace
    /// Every line is straight.
    case straight
    /// Line ends meet (no gaps in the shape).
    case closed
    /// Lines aren't wobbly.
    case smooth
    /// The right number of frames have a drawing (frame steps).
    case frameCount
    /// The drawing moves with the right spacing from frame to frame (frame steps).
    case spacing
    /// The last frame leads smoothly back into the first (frame steps).
    case loop

    /// Checks that only make sense when there are several frames.
    public var needsFrames: Bool { self == .frameCount || self == .spacing || self == .loop }
}

/// How far a thing moves from one frame to the next.
public enum LearnSpacing: String, Codable, Hashable, Sendable, CaseIterable {
    /// Same distance every frame: steady speed.
    case even
    /// Starts slow and speeds up (gaps get bigger).
    case easeIn
    /// Starts fast and slows down (gaps get smaller).
    case easeOut
    /// Slow at both ends, fast in the middle.
    case easeInOut

    public var words: String {
        switch self {
        case .even: return "the same gap every frame"
        case .easeIn: return "small gaps first, then bigger ones (speeding up)"
        case .easeOut: return "big gaps first, then smaller ones (slowing down)"
        case .easeInOut: return "small gaps at the start and end, big gaps in the middle"
        }
    }
}

/// One thing to check about a drawing.
public struct LearnCheck: Codable, Hashable, Sendable {
    public var type: LearnCheckType
    /// trace: share of the guide that must be covered (0...1).
    public var coverage: Double?
    /// trace: share of the learner's ink that must be on the guide (0...1).
    public var accuracy: Double?
    /// trace: how close counts as "on the line", in lesson units.
    public var tolerance: Double?
    /// straight: biggest bend (as a share of the line's length).
    /// closed: biggest gap between ends, in lesson units.
    /// smooth: biggest wobble.
    /// loop: how much bigger the jump from the last frame to the first may be than a normal step.
    public var value: Double?
    /// frameCount: fewest frames with a drawing.
    public var minFrames: Int?
    /// frameCount: most frames with a drawing.
    public var maxFrames: Int?
    /// spacing: the spacing to look for.
    public var spacing: LearnSpacing?

    public static let defaultCoverage = 0.7
    public static let defaultAccuracy = 0.7
    public static let defaultTolerance = 0.05
    public static let defaultStraight = 0.06
    public static let defaultClosedGap = 0.06
    public static let defaultSmooth = 0.35
    public static let defaultLoop = 2.0

    public init(type: LearnCheckType, coverage: Double? = nil, accuracy: Double? = nil, tolerance: Double? = nil,
                value: Double? = nil, minFrames: Int? = nil, maxFrames: Int? = nil, spacing: LearnSpacing? = nil) {
        self.type = type
        self.coverage = coverage
        self.accuracy = accuracy
        self.tolerance = tolerance
        self.value = value
        self.minFrames = minFrames
        self.maxFrames = maxFrames
        self.spacing = spacing
    }

    public static func trace(coverage: Double = defaultCoverage, accuracy: Double = defaultAccuracy,
                             tolerance: Double = defaultTolerance) -> LearnCheck {
        LearnCheck(type: .trace, coverage: coverage, accuracy: accuracy, tolerance: tolerance)
    }

    enum CodingKeys: String, CodingKey {
        case type, coverage, accuracy, tolerance, value, minFrames = "min", maxFrames = "max", spacing
    }
}

// MARK: - Quiz and app tools

public struct LearnQuiz: Codable, Hashable, Sendable {
    public var question: String
    public var choices: [String]
    /// Index of the right choice.
    public var answer: Int
    /// Why the answer is right (shown after answering).
    public var explain: String

    public init(question: String, choices: [String], answer: Int, explain: String) {
        self.question = question
        self.choices = choices
        self.answer = answer
        self.explain = explain
    }
}

/// Gale tools that "try it in the app" steps talk about.
public enum LearnAppTool: String, Codable, Hashable, Sendable, CaseIterable {
    case brush, stabilizer, layers, onionSkin, loops, stash, hairSway, motionBlur, timeline

    public var title: String {
        switch self {
        case .brush: return "Brushes"
        case .stabilizer: return "Stabilizer"
        case .layers: return "Layers"
        case .onionSkin: return "Onion Skin"
        case .loops: return "Loops"
        case .stash: return "Stash"
        case .hairSway: return "Hair Sway"
        case .motionBlur: return "Motion Blur"
        case .timeline: return "Timeline"
        }
    }

    /// SF Symbol name for the tool.
    public var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .stabilizer: return "scribble.variable"
        case .layers: return "square.3.layers.3d"
        case .onionSkin: return "circle.dashed"
        case .loops: return "repeat"
        case .stash: return "tray.full"
        case .hairSway: return "wind"
        case .motionBlur: return "hare"
        case .timeline: return "film"
        }
    }
}

public struct LearnToolTask: Codable, Hashable, Sendable {
    public var tool: LearnAppTool
    /// Small things to try, in order.
    public var tasks: [String]

    public init(tool: LearnAppTool, tasks: [String]) {
        self.tool = tool
        self.tasks = tasks
    }
}

// MARK: - Steps, lessons, courses

public enum LearnStepKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Read and watch an animated guide.
    case read
    /// Trace over a guide drawing.
    case trace
    /// Draw several frames (with onion skin) that match the guide's frames.
    case frames
    /// Pick the right answer.
    case quiz
    /// Try a Gale tool.
    case tool
    /// Watch and listen: a narrated demo, played beat by beat, with onion skin, motion trails and timing charts.
    case watch
    /// Animate it for real: the lesson opens a Gale project with the guide on a locked layer,
    /// you animate in the real editor, then the lesson checks the frames you drew.
    case animate

    /// Steps that are checked and give stars.
    public var isScored: Bool { self == .trace || self == .frames || self == .quiz || self == .animate }

    /// Steps where the learner draws frames that are checked against the guide's frames.
    public var drawsFrames: Bool { self == .frames || self == .animate }
}

// MARK: - Watch beats

/// Extra drawings laid over a watch step's demo.
public enum LearnOverlay: String, Codable, Hashable, Sendable, CaseIterable {
    /// Every frame of the beat shows faintly at once (like onion skin), so you see the spacing.
    case onion
    /// The path the tracked point travels, with a dot on every frame.
    case trail
    /// An animator's timing chart: one tick per frame, spaced like the drawings.
    case chart
    /// Plays the beat at half speed.
    case slow

    /// Unknown overlays from newer lesson files are skipped, not an error.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = LearnOverlay(rawValue: s) ?? .slow
    }
}

/// One spoken moment of a watch step: what is said, which frames play while it's said, and what's laid over them.
public struct LearnBeat: Codable, Hashable, Sendable {
    /// Spoken out loud and shown as a caption.
    public var say: String
    /// First frame that plays (0-based).
    public var from: Int
    /// Last frame that plays. Same as `from` to hold one drawing still.
    public var to: Int
    public var overlays: [LearnOverlay]

    public init(say: String, from: Int, to: Int, overlays: [LearnOverlay] = []) {
        self.say = say
        self.from = from
        self.to = to
        self.overlays = overlays
    }

    public var range: ClosedRange<Int> { min(from, to)...max(from, to) }
    public var holdsStill: Bool { from == to }
    public func has(_ o: LearnOverlay) -> Bool { overlays.contains(o) }

    enum CodingKeys: String, CodingKey { case say, from, to, overlays = "show" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = try c.decode(String.self, forKey: .say)
        from = try c.decodeIfPresent(Int.self, forKey: .from) ?? 0
        to = try c.decodeIfPresent(Int.self, forKey: .to) ?? from
        overlays = try c.decodeIfPresent([LearnOverlay].self, forKey: .overlays) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(say, forKey: .say)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        if !overlays.isEmpty { try c.encode(overlays, forKey: .overlays) }
    }
}

public struct LearnStep: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: LearnStepKind
    public var title: String
    public var text: String
    /// Extra help shown after the first miss.
    public var hint: String?
    public var guide: LearnGuide?
    public var checks: [LearnCheck]
    public var quiz: LearnQuiz?
    public var tool: LearnToolTask?
    /// What the narrator says for this step. Empty = it reads the title and text.
    public var say: [String]
    /// Watch steps: the narrated beats, in order.
    public var beats: [LearnBeat]

    public init(id: String, kind: LearnStepKind, title: String, text: String, hint: String? = nil,
                guide: LearnGuide? = nil, checks: [LearnCheck] = [], quiz: LearnQuiz? = nil, tool: LearnToolTask? = nil,
                say: [String] = [], beats: [LearnBeat] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.hint = hint
        self.guide = guide
        self.checks = checks
        self.quiz = quiz
        self.tool = tool
        self.say = say
        self.beats = beats
    }

    /// The trace check, if there is one.
    public var traceCheck: LearnCheck? { checks.first { $0.type == .trace } }

    enum CodingKeys: String, CodingKey { case id, kind, title, text, hint, guide, checks, quiz, tool, say, beats }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(LearnStepKind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        guide = try c.decodeIfPresent(LearnGuide.self, forKey: .guide)
        checks = try c.decodeIfPresent([LearnCheck].self, forKey: .checks) ?? []
        quiz = try c.decodeIfPresent(LearnQuiz.self, forKey: .quiz)
        tool = try c.decodeIfPresent(LearnToolTask.self, forKey: .tool)
        say = try c.decodeIfPresent([String].self, forKey: .say) ?? []
        beats = try c.decodeIfPresent([LearnBeat].self, forKey: .beats) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(hint, forKey: .hint)
        try c.encodeIfPresent(guide, forKey: .guide)
        if !checks.isEmpty { try c.encode(checks, forKey: .checks) }
        try c.encodeIfPresent(quiz, forKey: .quiz)
        try c.encodeIfPresent(tool, forKey: .tool)
        if !say.isEmpty { try c.encode(say, forKey: .say) }
        if !beats.isEmpty { try c.encode(beats, forKey: .beats) }
    }
}

public struct LearnLesson: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    /// About how long it takes.
    public var minutes: Int
    public var steps: [LearnStep]

    public init(id: String, title: String, summary: String, minutes: Int, steps: [LearnStep]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.minutes = minutes
        self.steps = steps
    }
}

public struct LearnCourse: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Id of the track this course belongs to.
    public var track: String
    public var title: String
    public var subtitle: String
    /// SF Symbol name.
    public var symbol: String
    /// Courses to finish before this one opens.
    public var requires: [String]
    public var lessons: [LearnLesson]

    public init(id: String, track: String, title: String, subtitle: String, symbol: String,
                requires: [String] = [], lessons: [LearnLesson]) {
        self.id = id
        self.track = track
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.requires = requires
        self.lessons = lessons
    }

    enum CodingKeys: String, CodingKey { case id, track, title, subtitle, symbol, requires, lessons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        track = try c.decode(String.self, forKey: .track)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "book"
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        lessons = try c.decode([LearnLesson].self, forKey: .lessons)
    }
}

/// A track as listed in the index file (course ids in order).
public struct LearnTrackInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var courses: [String]

    public init(id: String, title: String, subtitle: String, symbol: String, courses: [String]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.courses = courses
    }
}

/// The index file that lists every track.
public struct LearnTrackIndex: Codable, Hashable, Sendable {
    public var version: Int
    public var tracks: [LearnTrackInfo]

    public init(version: Int = 1, tracks: [LearnTrackInfo]) {
        self.version = version
        self.tracks = tracks
    }
}

/// A track with its courses loaded.
public struct LearnTrack: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var courses: [LearnCourse]

    public init(id: String, title: String, subtitle: String, symbol: String, courses: [LearnCourse]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.courses = courses
    }
}

// MARK: - Answers

/// What the learner hands in for a step.
public enum LearnAnswer: Hashable, Sendable {
    /// Read and tool steps: "Got it" / "I did it".
    case done
    /// Trace steps: the lines drawn, in lesson units.
    case strokes([[LearnPoint]])
    /// Frame steps: the lines drawn on each frame.
    case frames([[[LearnPoint]]])
    /// Quiz steps: the picked choice.
    case choice(Int)
}
