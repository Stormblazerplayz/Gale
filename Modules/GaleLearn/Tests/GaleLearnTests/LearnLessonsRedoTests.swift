import XCTest
@testable import GaleLearn

/// The redone lessons (one-lesson bounce, acting, lip sync, hair and cloth), frame tips, voice pacing,
/// voice choice and the course look.
final class LearnLessonsRedoTests: XCTestCase {
    static var cached: LearnCourseLibrary?

    func library() throws -> LearnCourseLibrary {
        if let c = Self.cached { return c }
        let lib = try LearnCourseLibrary.loadBuiltIn()
        Self.cached = lib
        return lib
    }

    // MARK: Content

    func testBouncingBallIsOneWholeLesson() throws {
        let lib = try library()
        let bounce = try XCTUnwrap(lib.lesson(id: "pro.bounce"))
        let animate = try XCTUnwrap(bounce.steps.first { $0.kind == .animate })
        let frames = try XCTUnwrap(animate.guide?.frames)
        XCTAssertEqual(frames.count, 10)
        // Drop, squash on the floor, recoil: the lowest ball is the squash, and the ball goes back up after it.
        let centres: [Double] = frames.map { f in
            let pts = f.paths.filter { $0.role == .ink }.flatMap(\.points)
            return pts.map(\.y).reduce(0, +) / Double(max(1, pts.count))
        }
        let lowest = try XCTUnwrap(centres.indices.max { centres[$0] < centres[$1] })
        XCTAssertGreaterThan(lowest, 2)
        XCTAssertLessThan(lowest, frames.count - 2)
        XCTAssertLessThan(centres.last!, centres[lowest])
        XCTAssertLessThan(centres.first!, centres.last!)  // it doesn't bounce as high as it fell from
        // The narrated demo follows the ball with a trail.
        XCTAssertTrue(bounce.steps.contains { $0.kind == .watch && ($0.guide?.track.count ?? 0) >= 10 })
        // The old three-lesson split is gone.
        for gone in ["ball.drop", "ball.bounce", "ball.squash"] { XCTAssertNil(lib.lesson(id: gone), gone) }
    }

    func testNewCoursesAreThereInDepth() throws {
        let lib = try library()
        let expected: [String: [String]] = [
            "acting": ["acting.pose", "acting.blink", "acting.eyes", "acting.take", "acting.breath"],
            "lipsync": ["lipsync.shapes", "lipsync.listen", "lipsync.hello", "lipsync.jaw", "lipsync.line"],
            "hair": ["hair.follow", "hair.bounce", "hair.wind", "hair.flag", "hair.cape", "hair.land"],
        ]
        for (courseID, lessons) in expected {
            let course = try XCTUnwrap(lib.course(id: courseID), courseID)
            XCTAssertEqual(course.lessons.map(\.id), lessons)
            for lesson in course.lessons {
                // Every lesson has a narrated demo, and all but the listening lesson have you animate in Gale.
                XCTAssertTrue(lesson.steps.contains { $0.kind == .watch && $0.beats.count >= 4 }, lesson.id)
                if lesson.id != "lipsync.listen" && lesson.id != "lipsync.shapes" {
                    XCTAssertTrue(lesson.steps.contains { $0.kind == .animate }, lesson.id)
                }
            }
        }
    }

    func testEveryAnimateStepTalksYouThroughEachFrame() throws {
        let lib = try library()
        var count = 0
        for lesson in lib.lessons {
            for step in lesson.steps where !step.tips.isEmpty || step.kind == .animate {
                let where_ = "\(lesson.id)/\(step.id)"
                XCTAssertEqual(step.kind, .animate, where_)
                XCTAssertEqual(step.tips.count, step.guide?.frames.count, where_)
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 15)
    }

    func testSpokenLinesStayShortEnoughToFollow() throws {
        let lib = try library()
        for lesson in lib.lessons {
            for step in lesson.steps {
                for line in step.beats.map(\.say) + step.tips {
                    let words = LearnNarration.wordRanges(in: line).count
                    XCTAssertLessThanOrEqual(words, 34, "\(lesson.id)/\(step.id): \(line)")
                }
            }
        }
    }

    func testTipsMustMatchFrames() {
        let guide = LearnGuide(frames: [LearnGuideFrame(paths: []), LearnGuideFrame(paths: [])])
        var step = LearnStep(id: "s1", kind: .animate, title: "T", text: "X", guide: guide, tips: ["One"])
        let lesson = { (s: LearnStep) in LearnLesson(id: "x", title: "X", summary: "", minutes: 1, steps: [s]) }
        XCTAssertTrue(LearnCourseLibrary.problems(in: lesson(step)).contains { $0.contains("one tip per frame") })
        step.tips = ["One", "Two"]
        XCTAssertFalse(LearnCourseLibrary.problems(in: lesson(step)).contains { $0.contains("tip") })
        step.kind = .watch
        XCTAssertTrue(LearnCourseLibrary.problems(in: lesson(step)).contains { $0.contains("only animate steps") })
    }

    // MARK: Narration

    func testTipAndPlanLines() {
        let guide = LearnGuide(frames: [LearnGuideFrame(paths: []), LearnGuideFrame(paths: [])])
        let step = LearnStep(id: "s1", kind: .animate, title: "T", text: "X", guide: guide,
                             tips: ["Draw the ball up high", "Squash it on the floor."])
        XCTAssertEqual(LearnNarration.tipLines(for: step, frame: 0), ["Frame 1 of 2.", "Draw the ball up high."])
        XCTAssertEqual(LearnNarration.tipLines(for: step, frame: 1), ["Frame 2 of 2.", "Squash it on the floor."])
        XCTAssertEqual(LearnNarration.tipLines(for: step, frame: 2), [])
        let plan = LearnNarration.planLines(for: step)
        XCTAssertEqual(plan.first, "Here's the plan, 2 frames.")
        XCTAssertEqual(plan[1], "Frame 1. Draw the ball up high.")
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(LearnNarration.planLines(for: LearnStep(id: "s", kind: .read, title: "T", text: "X")), [])
        XCTAssertEqual(LearnNarration.lines(for: step), ["T.", "X", LearnNarration.tapFrameLine])
        // Tips round-trip through JSON.
        let data = try? JSONEncoder().encode(step)
        let back = data.flatMap { try? JSONDecoder().decode(LearnStep.self, from: $0) }
        XCTAssertEqual(back?.tips, step.tips)
    }

    func testPacingSoundsHuman() {
        let q = LearnNarration.pacing(for: "Which one is faster?", index: 0, count: 3)
        let s = LearnNarration.pacing(for: "Then it settles back down, nice and slow.", index: 1, count: 3)
        let short = LearnNarration.pacing(for: "Pop!", index: 1, count: 3)
        let last = LearnNarration.pacing(for: "That's it.", index: 2, count: 3)
        XCTAssertGreaterThan(q.pitch, s.pitch)              // questions lift at the end
        XCTAssertGreaterThan(q.postDelay, s.postDelay)      // and leave time to think
        XCTAssertGreaterThan(q.preDelay, 0)
        XCTAssertEqual(s.preDelay, 0)
        XCTAssertLessThan(short.rate, s.rate + 0.03)        // short lines aren't rushed
        XCTAssertLessThan(last.postDelay, s.postDelay)      // no long gap after the last line
        for p in [q, s, short, last] {
            XCTAssertTrue((0.8...1.1).contains(p.rate))
            XCTAssertTrue((0.9...1.1).contains(p.pitch))
        }
    }

    // MARK: Voice

    func testVoiceChoicePrefersNaturalHighQualityVoices() {
        let voices = [
            LearnVoiceCandidate(id: "com.apple.speech.synthesis.voice.Bells", name: "Bells", language: "en-US",
                                quality: .premium, isNovelty: true),
            LearnVoiceCandidate(id: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", quality: .enhanced),
            LearnVoiceCandidate(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US",
                                quality: .standard),
            LearnVoiceCandidate(id: "com.apple.voice.enhanced.en-GB.Serena", name: "Serena", language: "en-GB",
                                quality: .enhanced),
            LearnVoiceCandidate(id: "com.apple.voice.premium.en-US.Zoe", name: "Zoe", language: "en-US", quality: .premium),
            LearnVoiceCandidate(id: "com.apple.voice.premium.fr-FR.Amelie", name: "Amélie", language: "fr-FR",
                                quality: .premium),
        ]
        XCTAssertEqual(LearnVoiceChoice.best(voices, preferredLanguage: "en-US")?.name, "Zoe")
        let ranked = LearnVoiceChoice.ranked(voices, preferredLanguage: "en-US").map(\.name)
        XCTAssertFalse(ranked.contains("Bells"))
        XCTAssertFalse(ranked.contains("Amélie"))
        XCTAssertLessThan(ranked.firstIndex(of: "Serena")!, ranked.firstIndex(of: "Eddy")!)
        // The learner's own pick wins while it's on the device.
        XCTAssertEqual(LearnVoiceChoice.best(voices, preferredLanguage: "en-US",
                                             picked: "com.apple.voice.compact.en-US.Samantha")?.name, "Samantha")
        XCTAssertEqual(LearnVoiceChoice.best(voices, preferredLanguage: "en-US", picked: "gone")?.name, "Zoe")
        XCTAssertFalse(LearnVoiceChoice.shouldSuggestDownload(voices))
        XCTAssertTrue(LearnVoiceChoice.shouldSuggestDownload([voices[2]]))
        XCTAssertEqual(LearnVoiceChoice.preferredLanguage(deviceLanguage: "en-AU"), "en-AU")
        XCTAssertEqual(LearnVoiceChoice.preferredLanguage(deviceLanguage: "de-DE"), "en-US")
    }

    // MARK: Look

    func testEveryCourseHasItsOwnColourAndAMovingPreview() throws {
        let lib = try library()
        var hues: [Double] = []
        for course in lib.courses {
            let look = LearnCourseStyle.look(for: course.id)
            XCTAssertTrue((0..<1).contains(look.hue))
            XCTAssertNotNil(LearnCourseStyle.hues[course.id], "\(course.id) has no hand-picked colour")
            hues.append(look.hue)
            let preview = try XCTUnwrap(LearnCourseStyle.previewGuide(for: course), course.id)
            XCTAssertGreaterThanOrEqual(preview.frames.count, 2, course.id)
        }
        XCTAssertEqual(Set(hues).count, hues.count)
        XCTAssertEqual(LearnCourseStyle.hashHue("new-course"), LearnCourseStyle.hashHue("new-course"))
        XCTAssertTrue((0..<1).contains(LearnCourseStyle.look(for: "new-course").hue2))
    }

    func testPreviewFrameHonoursHolds() {
        let g = LearnGuide(fps: 2, frames: [LearnGuideFrame(paths: [], hold: 2), LearnGuideFrame(paths: [], hold: 1)])
        XCTAssertEqual(LearnCourseStyle.previewFrame(g, at: 0), 0)
        XCTAssertEqual(LearnCourseStyle.previewFrame(g, at: 0.6), 0)
        XCTAssertEqual(LearnCourseStyle.previewFrame(g, at: 1.0), 1)
        XCTAssertEqual(LearnCourseStyle.previewFrame(g, at: 1.5), 0)  // loops
    }

    func testLessonPathHasOneNext() {
        let done: Set<String> = ["a", "c"]
        let states = LearnCourseStyle.pathStates(lessonIDs: ["a", "b", "c", "d"]) { done.contains($0) }
        XCTAssertEqual(states, [.done, .next, .done, .later])
        XCTAssertEqual(LearnCourseStyle.pathStates(lessonIDs: ["a"]) { _ in true }, [.done])
    }
}
