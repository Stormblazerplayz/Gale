import Foundation

/// The colours a course is drawn with on the Learn screens (two hues for a gradient, 0...1 around the colour wheel).
public struct LearnCourseLook: Equatable, Hashable, Sendable {
    public var hue: Double
    public var hue2: Double

    public init(hue: Double, hue2: Double) {
        self.hue = LearnCourseStyle.wrap(hue)
        self.hue2 = LearnCourseStyle.wrap(hue2)
    }
}

/// Where a lesson sits on a course's path of lessons.
public enum LearnPathState: String, Equatable, Sendable {
    /// Finished.
    case done
    /// The first lesson not finished yet: the one to do next.
    case next
    /// Later in the course.
    case later
}

/// How courses look on the Learn screens: each course has its own colour and a little moving preview of its demo.
public enum LearnCourseStyle {
    /// Hand-picked hues, so courses next to each other never look the same.
    public static let hues: [String: Double] = [
        "pro": 0.74, "basics": 0.58, "tools": 0.53, "principles": 0.09, "ball": 0.01, "walk": 0.36,
        "run": 0.29, "acting": 0.88, "lipsync": 0.95, "effects": 0.06, "hair": 0.47,
        "perspective": 0.62, "turnarounds": 0.8, "rotating": 0.42, "camera": 0.67, "characters3d": 0.84,
    ]

    /// The colours for a course. Courses not in the table get a steady colour worked out from their id.
    public static func look(for courseID: String) -> LearnCourseLook {
        let h = hues[courseID] ?? hashHue(courseID)
        return LearnCourseLook(hue: h, hue2: h + 0.07)
    }

    /// A hue from the id that is the same on every launch and every device (unlike `hashValue`).
    public static func hashHue(_ id: String) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Double(h % 1000) / 1000
    }

    static func wrap(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 1)
        return r < 0 ? r + 1 : r
    }

    /// The moving demo to show on a course's card: its first watch demo with at least two frames,
    /// otherwise any step's guide that moves. Nil when the course has nothing that moves.
    public static func previewGuide(for course: LearnCourse) -> LearnGuide? {
        let steps = course.lessons.flatMap(\.steps)
        if let s = steps.first(where: { $0.kind == .watch && ($0.guide?.frames.count ?? 0) >= 2 }) { return s.guide }
        return steps.first(where: { ($0.guide?.frames.count ?? 0) >= 2 })?.guide
    }

    /// Which guide frame to show `seconds` into a looping preview, honouring each frame's hold.
    public static func previewFrame(_ guide: LearnGuide, at seconds: Double) -> Int {
        guard !guide.frames.isEmpty else { return 0 }
        let holds = guide.frames.map { max(1, $0.hold) }
        let total = holds.reduce(0, +)
        let fps = Double(max(1, guide.fps))
        var tick = Int((max(0, seconds) * fps).rounded(.down)) % total
        for (i, h) in holds.enumerated() {
            if tick < h { return i }
            tick -= h
        }
        return guide.frames.count - 1
    }

    /// Done, next or later for every lesson of a course, in order. Only one lesson is ever "next".
    public static func pathStates(lessonIDs: [String], isDone: (String) -> Bool) -> [LearnPathState] {
        var foundNext = false
        return lessonIDs.map { id in
            if isDone(id) { return .done }
            if !foundNext {
                foundNext = true
                return .next
            }
            return .later
        }
    }
}
