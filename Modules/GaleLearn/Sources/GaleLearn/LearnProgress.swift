import Foundation

/// How a finished lesson went.
public struct LearnLessonRecord: Codable, Hashable, Sendable {
    /// Best stars so far (1...3).
    public var stars: Int
    /// Day it was first finished ("yyyy-MM-dd").
    public var firstDone: String
    /// Day it was last finished.
    public var lastDone: String
    /// How many times it was finished.
    public var times: Int

    public init(stars: Int, firstDone: String, lastDone: String, times: Int = 1) {
        self.stars = stars
        self.firstDone = firstDone
        self.lastDone = lastDone
        self.times = times
    }
}

/// Everything the learner has done, saved as a small JSON file on the device.
/// No accounts, nothing leaves the device.
public struct LearnProgress: Codable, Hashable, Sendable {
    public var version: Int
    /// Finished lessons by lesson id.
    public var lessons: [String: LearnLessonRecord]
    /// Days with at least one finished lesson ("yyyy-MM-dd"), oldest first.
    public var activeDays: [String]
    /// Courses that are open, in the order they opened.
    public var unlockedCourses: [String]
    /// Gale projects made by "animate it" steps, by step ("lessonID/stepID" → project id),
    /// so coming back to a step opens the same animation instead of a new one.
    public var studioProjects: [String: String]

    public init() {
        version = 1
        lessons = [:]
        activeDays = []
        unlockedCourses = []
        studioProjects = [:]
    }

    enum CodingKeys: String, CodingKey { case version, lessons, activeDays, unlockedCourses, studioProjects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        lessons = try c.decodeIfPresent([String: LearnLessonRecord].self, forKey: .lessons) ?? [:]
        activeDays = try c.decodeIfPresent([String].self, forKey: .activeDays) ?? []
        unlockedCourses = try c.decodeIfPresent([String].self, forKey: .unlockedCourses) ?? []
        studioProjects = try c.decodeIfPresent([String: String].self, forKey: .studioProjects) ?? [:]
    }

    // MARK: Animate steps

    public static func studioKey(lesson: String, step: String) -> String { "\(lesson)/\(step)" }

    public func studioProject(lesson: String, step: String) -> String? {
        studioProjects[LearnProgress.studioKey(lesson: lesson, step: step)]
    }

    public mutating func setStudioProject(_ projectID: String?, lesson: String, step: String) {
        studioProjects[LearnProgress.studioKey(lesson: lesson, step: step)] = projectID
    }

    // MARK: Lessons

    public func isCompleted(_ lessonID: String) -> Bool { lessons[lessonID] != nil }
    public func stars(for lessonID: String) -> Int { lessons[lessonID]?.stars ?? 0 }
    public var totalStars: Int { lessons.values.reduce(0) { $0 + $1.stars } }
    public var completedCount: Int { lessons.count }

    public func completedCount(in course: LearnCourse) -> Int {
        course.lessons.filter { isCompleted($0.id) }.count
    }

    public func isCourseCompleted(_ course: LearnCourse) -> Bool {
        !course.lessons.isEmpty && completedCount(in: course) == course.lessons.count
    }

    /// Saves a finished lesson (keeps the best stars) and marks today as active.
    public mutating func recordLesson(_ lessonID: String, stars: Int, on date: Date = Date(), calendar: Calendar = .current) {
        let day = LearnProgress.dayKey(date, calendar: calendar)
        let s = max(1, min(3, stars))
        if var rec = lessons[lessonID] {
            rec.stars = max(rec.stars, s)
            rec.lastDone = day
            rec.times += 1
            lessons[lessonID] = rec
        } else {
            lessons[lessonID] = LearnLessonRecord(stars: s, firstDone: day, lastDone: day)
        }
        markActive(on: date, calendar: calendar)
    }

    /// Marks a day as active (for the streak).
    public mutating func markActive(on date: Date = Date(), calendar: Calendar = .current) {
        let day = LearnProgress.dayKey(date, calendar: calendar)
        if !activeDays.contains(day) {
            activeDays.append(day)
            activeDays.sort()
            if activeDays.count > 400 { activeDays.removeFirst(activeDays.count - 400) }
        }
    }

    // MARK: Streak

    /// Days in a row with a finished lesson, counting today (or yesterday, if today has nothing yet).
    public func streak(asOf date: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(activeDays)
        guard !days.isEmpty else { return 0 }
        var cursor = calendar.startOfDay(for: date)
        if !days.contains(LearnProgress.dayKey(cursor, calendar: calendar)) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = y
        }
        var count = 0
        while days.contains(LearnProgress.dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// "yyyy-MM-dd" for a date in the calendar's time zone.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ v: Int, _ n: Int) -> String {
            let s = String(v)
            return s.count >= n ? s : String(repeating: "0", count: n - s.count) + s
        }
        return "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0, 2))-\(pad(c.day ?? 0, 2))"
    }

    // MARK: Unlocks

    /// Every course is open from day one: nobody has to trace circles before they're allowed to animate.
    /// A course's `requires` list is only advice ("best after").
    public func isCourseUnlocked(_ course: LearnCourse, in library: LearnCourseLibrary) -> Bool {
        library.course(id: course.id) != nil
    }

    /// Whether the courses this one builds on are finished (shown as "Best after ..." when they aren't).
    public func isCourseReady(_ course: LearnCourse, in library: LearnCourseLibrary) -> Bool {
        course.requires.allSatisfy { id in
            guard let needed = library.course(id: id) else { return true }
            return isCourseCompleted(needed)
        }
    }

    /// Every lesson of a course is open. Lessons are still listed in the best order to do them.
    public func isLessonUnlocked(_ lesson: LearnLesson, in course: LearnCourse, library: LearnCourseLibrary) -> Bool {
        isCourseUnlocked(course, in: library) && course.lessons.contains { $0.id == lesson.id }
    }

    /// Adds newly opened courses to `unlockedCourses` and returns their ids.
    @discardableResult
    public mutating func refreshUnlocks(library: LearnCourseLibrary) -> [String] {
        var added: [String] = []
        for course in library.courses where isCourseUnlocked(course, in: library) && !unlockedCourses.contains(course.id) {
            unlockedCourses.append(course.id)
            added.append(course.id)
        }
        return added
    }

    // MARK: Saving

    /// Application Support/Learn/progress.json
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("Learn", isDirectory: true).appendingPathComponent("progress.json")
    }

    /// Loads saved progress. A missing file means a fresh start.
    public static func load(from url: URL) throws -> LearnProgress {
        guard FileManager.default.fileExists(atPath: url.path) else { return LearnProgress() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LearnProgress.self, from: data)
    }

    /// Saves progress (atomically, so a crash never leaves half a file).
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
