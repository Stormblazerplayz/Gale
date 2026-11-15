import Foundation

public enum LearnLibraryError: Error, CustomStringConvertible, Sendable {
    case noResources
    case missingIndex
    case missingCourse(String)
    case badFile(String, String)

    public var description: String {
        switch self {
        case .noResources: return "The course files could not be found."
        case .missingIndex: return "The course list (\(LearnCourseLibrary.indexFile)) is missing."
        case .missingCourse(let id): return "The course \"\(id)\" is missing."
        case .badFile(let name, let why): return "The file \(name) could not be read: \(why)"
        }
    }
}

/// All built-in courses, grouped into tracks.
public struct LearnCourseLibrary: Hashable, Sendable {
    public static let indexFile = "learn-tracks.json"
    public static func courseFile(_ id: String) -> String { "learn-course-\(id).json" }

    public var tracks: [LearnTrack]

    public init(tracks: [LearnTrack]) {
        self.tracks = tracks
    }

    /// Every course, track by track.
    public var courses: [LearnCourse] { tracks.flatMap(\.courses) }
    /// Every lesson, course by course.
    public var lessons: [LearnLesson] { courses.flatMap(\.lessons) }

    public func track(id: String) -> LearnTrack? { tracks.first { $0.id == id } }
    public func course(id: String) -> LearnCourse? { courses.first { $0.id == id } }

    /// The course that holds a lesson.
    public func course(containing lessonID: String) -> LearnCourse? {
        courses.first { c in c.lessons.contains { $0.id == lessonID } }
    }

    public func lesson(id: String) -> LearnLesson? {
        for c in courses {
            if let l = c.lessons.first(where: { $0.id == id }) { return l }
        }
        return nil
    }

    /// The lesson after this one in the same course, if any.
    public func nextLesson(after lessonID: String) -> LearnLesson? {
        guard let c = course(containing: lessonID), let i = c.lessons.firstIndex(where: { $0.id == lessonID }),
              i + 1 < c.lessons.count else { return nil }
        return c.lessons[i + 1]
    }

    // MARK: Loading

    /// Loads the courses that ship inside GaleLearn.
    public static func loadBuiltIn() throws -> LearnCourseLibrary {
        let bundle = Bundle.module
        let root = bundle.resourceURL ?? bundle.bundleURL
        return try load(from: root)
    }

    /// Loads courses from a folder (searched recursively for the index and course files).
    public static func load(from directory: URL) throws -> LearnCourseLibrary {
        var files: [String: URL] = [:]
        if let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension.lowercased() == "json" {
                let name = url.lastPathComponent
                if files[name] == nil { files[name] = url }
            }
        }
        guard !files.isEmpty else { throw LearnLibraryError.noResources }
        guard let indexURL = files[indexFile] else { throw LearnLibraryError.missingIndex }
        let decoder = JSONDecoder()
        let index: LearnTrackIndex
        do {
            index = try decoder.decode(LearnTrackIndex.self, from: Data(contentsOf: indexURL))
        } catch {
            throw LearnLibraryError.badFile(indexFile, String(describing: error))
        }
        var tracks: [LearnTrack] = []
        for info in index.tracks {
            var courses: [LearnCourse] = []
            for id in info.courses {
                let name = courseFile(id)
                guard let url = files[name] else { throw LearnLibraryError.missingCourse(id) }
                do {
                    courses.append(try decoder.decode(LearnCourse.self, from: Data(contentsOf: url)))
                } catch {
                    throw LearnLibraryError.badFile(name, String(describing: error))
                }
            }
            tracks.append(LearnTrack(id: info.id, title: info.title, subtitle: info.subtitle, symbol: info.symbol, courses: courses))
        }
        return LearnCourseLibrary(tracks: tracks)
    }

    // MARK: Checking

    /// Everything wrong with the course data (empty when all is well).
    public func validate() -> [String] {
        var problems: [String] = []
        if tracks.isEmpty { problems.append("No tracks.") }
        var courseIDs = Set<String>()
        var lessonIDs = Set<String>()
        for t in tracks {
            if t.title.isEmpty { problems.append("Track \(t.id) has no title.") }
            if t.courses.isEmpty { problems.append("Track \(t.id) has no courses.") }
            for c in t.courses {
                if !courseIDs.insert(c.id).inserted { problems.append("Course id \(c.id) is used twice.") }
                if c.track != t.id { problems.append("Course \(c.id) says track \(c.track) but is listed in \(t.id).") }
                if c.title.isEmpty { problems.append("Course \(c.id) has no title.") }
                if c.lessons.isEmpty { problems.append("Course \(c.id) has no lessons.") }
                for l in c.lessons {
                    if !lessonIDs.insert(l.id).inserted { problems.append("Lesson id \(l.id) is used twice.") }
                    problems += LearnCourseLibrary.problems(in: l)
                }
            }
        }
        for c in courses {
            for r in c.requires {
                if r == c.id { problems.append("Course \(c.id) requires itself.") }
                if !courseIDs.contains(r) { problems.append("Course \(c.id) requires unknown course \(r).") }
            }
        }
        if hasRequireCycle() { problems.append("Course requirements go round in a circle.") }
        return problems
    }

    /// Every drawing step must pass when the guide's own lines are handed in.
    public func selfCheck() -> [String] {
        var problems: [String] = []
        for l in lessons {
            for s in l.steps where s.kind == .trace || s.kind == .frames || s.kind == .quiz {
                let r = LearnEvaluator.evaluate(s, answer: LearnEvaluator.perfectAnswer(for: s))
                if !r.passed {
                    let fails = r.outcomes.filter { !$0.passed }.map { "\($0.type.rawValue): \($0.message)" }
                    problems.append("\(l.id)/\(s.id) fails its own guide: \(fails.joined(separator: "; "))")
                }
            }
        }
        return problems
    }

    func hasRequireCycle() -> Bool {
        var state: [String: Int] = [:]  // 1 visiting, 2 done
        let byID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func visit(_ id: String) -> Bool {
            if state[id] == 1 { return true }
            if state[id] == 2 { return false }
            state[id] = 1
            for r in byID[id]?.requires ?? [] where visit(r) { return true }
            state[id] = 2
            return false
        }
        return courses.contains { visit($0.id) }
    }

    static func problems(in lesson: LearnLesson) -> [String] {
        var p: [String] = []
        let where_ = "Lesson \(lesson.id)"
        if lesson.title.isEmpty { p.append("\(where_) has no title.") }
        if lesson.summary.isEmpty { p.append("\(where_) has no summary.") }
        if lesson.minutes < 1 { p.append("\(where_) needs minutes.") }
        if lesson.steps.count < 3 || lesson.steps.count > 8 {
            p.append("\(where_) has \(lesson.steps.count) steps (needs 3 to 8).")
        }
        var stepIDs = Set<String>()
        for s in lesson.steps {
            let at = "\(lesson.id)/\(s.id)"
            if !stepIDs.insert(s.id).inserted { p.append("Step id \(at) is used twice.") }
            if s.title.isEmpty { p.append("\(at) has no title.") }
            if s.kind != .quiz && s.text.isEmpty { p.append("\(at) has no text.") }
            if let g = s.guide { p += problems(in: g, at: at) }
            for c in s.checks {
                if c.type.needsFrames && s.kind != .frames { p.append("\(at): \(c.type.rawValue) check only works on frame steps.") }
                p += problems(in: c, at: at, frameCount: s.guide?.frames.count ?? 0)
            }
            switch s.kind {
            case .read:
                if !s.checks.isEmpty { p.append("\(at): read steps have no checks.") }
            case .trace:
                guard let g = s.guide, let f = g.frames.first else { p.append("\(at): trace needs a guide."); break }
                if f.inkPaths.isEmpty { p.append("\(at): trace guide has no ink lines.") }
                if s.traceCheck == nil { p.append("\(at): trace needs a trace check.") }
            case .frames:
                guard let g = s.guide else { p.append("\(at): frames needs a guide."); break }
                if g.frames.count < 2 { p.append("\(at): frames needs at least 2 frames.") }
                if g.frames.count > 12 { p.append("\(at): frames has too many frames to draw (max 12).") }
                if g.frames.contains(where: { $0.inkPaths.isEmpty }) { p.append("\(at): every frame needs ink lines.") }
                if s.traceCheck == nil { p.append("\(at): frames needs a trace check.") }
            case .quiz:
                guard let q = s.quiz else { p.append("\(at): quiz missing."); break }
                if q.question.isEmpty { p.append("\(at): quiz has no question.") }
                if q.choices.count < 2 || q.choices.count > 4 { p.append("\(at): quiz needs 2 to 4 choices.") }
                if q.choices.contains(where: { $0.isEmpty }) { p.append("\(at): quiz has an empty choice.") }
                if Set(q.choices).count != q.choices.count { p.append("\(at): quiz has the same choice twice.") }
                if q.answer < 0 || q.answer >= q.choices.count { p.append("\(at): quiz answer is out of range.") }
                if q.explain.isEmpty { p.append("\(at): quiz needs an explanation.") }
                if !s.checks.isEmpty { p.append("\(at): quiz steps have no checks.") }
            case .tool:
                guard let t = s.tool else { p.append("\(at): tool missing."); break }
                if t.tasks.isEmpty || t.tasks.contains(where: { $0.isEmpty }) { p.append("\(at): tool needs tasks.") }
                if !s.checks.isEmpty { p.append("\(at): tool steps have no checks.") }
            }
        }
        return p
    }

    static func problems(in guide: LearnGuide, at: String) -> [String] {
        var p: [String] = []
        if !(guide.aspect >= 0.5 && guide.aspect <= 2.5) { p.append("\(at): guide aspect \(guide.aspect) is odd.") }
        if guide.fps < 1 || guide.fps > 60 { p.append("\(at): guide fps \(guide.fps) is odd.") }
        if guide.frames.isEmpty { p.append("\(at): guide has no frames.") }
        let pad = 0.3
        func checkPath(_ path: LearnPath, _ label: String) {
            if path.points.count < 2 { p.append("\(at) \(label): a line needs at least 2 points.") }
            if !(path.width > 0 && path.width < 0.1) { p.append("\(at) \(label): line width \(path.width) is odd.") }
            for pt in path.points {
                if !pt.isFinite || pt.x < -pad || pt.x > guide.aspect + pad || pt.y < -pad || pt.y > 1 + pad {
                    p.append("\(at) \(label): point (\(pt.x), \(pt.y)) is off the page.")
                    return
                }
            }
        }
        for path in guide.background { checkPath(path, "background") }
        for (i, f) in guide.frames.enumerated() {
            if f.hold < 1 || f.hold > 96 { p.append("\(at) frame \(i + 1): hold \(f.hold) is odd.") }
            if f.paths.isEmpty && guide.background.isEmpty { p.append("\(at) frame \(i + 1) is empty.") }
            for path in f.paths { checkPath(path, "frame \(i + 1)") }
            for n in f.notes where n.text.isEmpty { p.append("\(at) frame \(i + 1): empty note.") }
        }
        return p
    }

    static func problems(in c: LearnCheck, at: String, frameCount: Int) -> [String] {
        var p: [String] = []
        func unit(_ v: Double?, _ name: String) {
            if let v, !(v > 0 && v <= 1) { p.append("\(at): \(name) \(v) must be in 0...1.") }
        }
        switch c.type {
        case .trace:
            unit(c.coverage, "coverage")
            unit(c.accuracy, "accuracy")
            if let t = c.tolerance, !(t > 0.005 && t <= 0.2) { p.append("\(at): tolerance \(t) is odd.") }
        case .straight, .closed, .smooth:
            if let v = c.value, !(v > 0) { p.append("\(at): \(c.type.rawValue) value must be above 0.") }
        case .frameCount:
            let lo = c.minFrames ?? frameCount
            let hi = c.maxFrames ?? frameCount
            if lo < 1 || lo > hi { p.append("\(at): frameCount range \(lo)...\(hi) is odd.") }
        case .spacing:
            if c.spacing == nil { p.append("\(at): spacing check needs a spacing.") }
            if frameCount < 3 { p.append("\(at): spacing needs at least 3 frames.") }
        case .loop:
            if frameCount < 3 { p.append("\(at): loop needs at least 3 frames.") }
            if let v = c.value, !(v > 0) { p.append("\(at): loop value must be above 0.") }
        }
        return p
    }
}
