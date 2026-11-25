import SwiftUI
import GaleLearn

/// Holds the built-in courses and the kid's own progress (stars, streak, and projects made in lessons).
/// Every course is open from the start.
/// Progress is saved on this device only, in Application Support/Learn/progress.json.
@MainActor
final class LearnStore: ObservableObject {
    @Published private(set) var library: LearnCourseLibrary?
    @Published private(set) var loadError: String?
    @Published private(set) var progress = LearnProgress()
    @Published var saveError: String?

    private let progressURL: URL?
    private var loading = false

    init() {
        progressURL = try? LearnProgress.defaultURL()
        guard let url = progressURL else { return }
        do {
            progress = try LearnProgress.load(from: url)
        } catch {
            // A broken file is kept to the side instead of being thrown away.
            let backup = url.deletingLastPathComponent().appendingPathComponent("progress-unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            progress = LearnProgress()
        }
    }

    /// Loads the lessons that ship inside the app (off the main thread, they are a big file).
    func load() async {
        guard library == nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let lib = try await Task.detached(priority: .userInitiated) { () throws -> LearnCourseLibrary in
                try LearnCourseLibrary.loadBuiltIn()
            }.value
            library = lib
            loadError = nil
            if !progress.refreshUnlocks(library: lib).isEmpty { save() }
        } catch {
            loadError = "The lessons couldn't be opened. (\(error))"
        }
    }

    // MARK: Reading

    var streak: Int { progress.streak() }
    var totalStars: Int { progress.totalStars }

    func stars(for lesson: LearnLesson) -> Int { progress.stars(for: lesson.id) }
    func isDone(_ lesson: LearnLesson) -> Bool { progress.isCompleted(lesson.id) }

    func isUnlocked(_ course: LearnCourse) -> Bool {
        guard let lib = library else { return false }
        return progress.isCourseUnlocked(course, in: lib)
    }

    func isUnlocked(_ lesson: LearnLesson, in course: LearnCourse) -> Bool {
        guard let lib = library else { return false }
        return progress.isLessonUnlocked(lesson, in: course, library: lib)
    }

    /// Titles of the courses that must be finished first.
    func missingCourses(for course: LearnCourse) -> [String] {
        guard let lib = library else { return [] }
        return course.requires.compactMap { lib.course(id: $0) }.filter { !progress.isCourseCompleted($0) }.map(\.title)
    }

    func course(containing lesson: LearnLesson) -> LearnCourse? { library?.course(containing: lesson.id) }

    /// The lesson to do next: the first unfinished, open lesson, in course order.
    var nextUp: (course: LearnCourse, lesson: LearnLesson)? {
        guard let lib = library else { return nil }
        for course in lib.courses where progress.isCourseUnlocked(course, in: lib) {
            if let lesson = course.lessons.first(where: { !progress.isCompleted($0.id) }) {
                return (course, lesson)
            }
        }
        return nil
    }

    /// The lesson after this one, if it is open.
    func lesson(after lesson: LearnLesson) -> LearnLesson? {
        guard let lib = library, let next = lib.nextLesson(after: lesson.id),
              let course = lib.course(containing: next.id),
              progress.isLessonUnlocked(next, in: course, library: lib) else { return nil }
        return next
    }

    // MARK: Writing

    /// Saves a finished lesson. Returns the courses that just opened up.
    @discardableResult
    func finish(_ lesson: LearnLesson, stars: Int) -> [LearnCourse] {
        progress.recordLesson(lesson.id, stars: stars)
        var opened: [LearnCourse] = []
        if let lib = library {
            opened = progress.refreshUnlocks(library: lib).compactMap { lib.course(id: $0) }
        }
        save()
        return opened
    }

    // MARK: Animate steps

    /// The Gale project made for an "animate it" step, if one was made before.
    func studioProjectID(lesson: LearnLesson, step: LearnStep) -> String? {
        progress.studioProject(lesson: lesson.id, step: step.id)
    }

    func setStudioProject(_ projectID: String?, lesson: LearnLesson, step: LearnStep) {
        progress.setStudioProject(projectID, lesson: lesson.id, step: step.id)
        save()
    }

    func save() {
        guard let url = progressURL else {
            saveError = "Your progress can't be saved on this device."
            return
        }
        do {
            try progress.save(to: url)
            saveError = nil
        } catch {
            saveError = "Your progress couldn't be saved. (\(error.localizedDescription))"
        }
    }
}
