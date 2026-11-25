import XCTest
@testable import GaleLearn

/// Small seeded random numbers so scribble tests are the same every run.
struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
}

final class LibraryTests: XCTestCase {
    static var cached: LearnCourseLibrary?

    func library() throws -> LearnCourseLibrary {
        if let c = LibraryTests.cached { return c }
        let lib = try LearnCourseLibrary.loadBuiltIn()
        LibraryTests.cached = lib
        return lib
    }

    func testLibraryLoadsAndValidates() throws {
        let lib = try library()
        XCTAssertEqual(lib.tracks.map(\.id), ["animation", "3d"])
        XCTAssertGreaterThanOrEqual(lib.lessons.count, 50)
        XCTAssertGreaterThanOrEqual(lib.courses.count, 14)
        let problems = lib.validate()
        XCTAssertEqual(problems, [], problems.prefix(20).joined(separator: "\n"))
        for lesson in lib.lessons {
            XCTAssertTrue((3...8).contains(lesson.steps.count), lesson.id)
        }
        // Every step kind is used somewhere.
        let kinds = Set(lib.lessons.flatMap { $0.steps.map(\.kind) })
        XCTAssertEqual(kinds, Set(LearnStepKind.allCases))
        // Lookups.
        let first = try XCTUnwrap(lib.courses.first?.lessons.first)
        XCTAssertEqual(lib.lesson(id: first.id)?.id, first.id)
        XCTAssertEqual(lib.course(containing: first.id)?.id, lib.courses.first?.id)
        XCTAssertNotNil(lib.nextLesson(after: first.id))
    }

    func testEveryDrawingStepPassesWithItsOwnGuide() throws {
        let lib = try library()
        let problems = lib.selfCheck()
        XCTAssertEqual(problems, [], problems.prefix(20).joined(separator: "\n"))
        var drawingSteps = 0
        for lesson in lib.lessons {
            for step in lesson.steps where step.kind == .trace || step.kind.drawsFrames {
                drawingSteps += 1
                let r = LearnEvaluator.evaluate(step, answer: LearnEvaluator.perfectAnswer(for: step))
                XCTAssertTrue(r.passed, "\(lesson.id)/\(step.id): \(r.message)")
                XCTAssertGreaterThanOrEqual(r.quality, 0.9, "\(lesson.id)/\(step.id)")
            }
        }
        XCTAssertGreaterThan(drawingSteps, 60)
    }

    func testScribblesFail() throws {
        let lib = try library()
        var rng = SeededRandom(42)
        for lesson in lib.lessons {
            for step in lesson.steps where step.kind == .trace || step.kind.drawsFrames {
                let aspect = step.guide?.aspect ?? LearnGuide.defaultAspect
                func scribble() -> [[LearnPoint]] {
                    [(0..<40).map { _ in LearnPoint(rng.range(0.05, aspect - 0.05), rng.range(0.05, 0.95)) }]
                }
                let count = step.guide?.frames.count ?? 1
                let scribbled: LearnAnswer = step.kind == .trace ? .strokes(scribble())
                    : .frames((0..<count).map { _ in scribble() })
                XCTAssertFalse(LearnEvaluator.evaluate(step, answer: scribbled).passed, "scribble passed \(lesson.id)/\(step.id)")

                // Nothing drawn, or a single dot, never passes.
                let empty: LearnAnswer = step.kind == .trace ? .strokes([]) : .frames([])
                XCTAssertFalse(LearnEvaluator.evaluate(step, answer: empty).passed, "\(lesson.id)/\(step.id)")
                let dot = [[LearnPoint(aspect / 2, 0.5)]]
                let dotted: LearnAnswer = step.kind == .trace ? .strokes(dot) : .frames(Array(repeating: dot, count: count))
                XCTAssertFalse(LearnEvaluator.evaluate(step, answer: dotted).passed, "\(lesson.id)/\(step.id)")
            }
        }
    }

    func testFramesStepNeedsEveryFrame() throws {
        let lib = try library()
        let step = try XCTUnwrap(lib.lessons.flatMap(\.steps).first { $0.kind == .frames })
        var frames = step.guide!.frames.map(\.inkStrokes)
        frames[frames.count - 1] = []
        let r = LearnEvaluator.evaluate(step, answer: .frames(frames))
        XCTAssertFalse(r.passed)
    }

    func testGuidePlaybackHonoursHolds() {
        let f = LearnGuideFrame(paths: [LearnPath(points: [LearnPoint(0, 0), LearnPoint(1, 1)])])
        var g = LearnGuide(fps: 10, loop: true, frames: [f, LearnGuideFrame(paths: f.paths, hold: 3), f])
        XCTAssertEqual(g.totalTicks, 5)
        XCTAssertEqual((0..<6).map { g.frameIndex(atTick: $0) }, [0, 1, 1, 1, 2, 0])
        XCTAssertEqual(g.frameIndex(atTime: 0.15), 1)
        g.loop = false
        XCTAssertEqual(g.frameIndex(atTick: 99), 2)
    }

    func testCourseJSONRoundTrip() throws {
        let lib = try library()
        let course = try XCTUnwrap(lib.courses.first)
        let data = try JSONEncoder().encode(course)
        let back = try JSONDecoder().decode(LearnCourse.self, from: data)
        XCTAssertEqual(back, course)
    }
}

final class ScoringTests: XCTestCase {
    func line(_ a: LearnPoint, _ b: LearnPoint, n: Int = 20) -> [LearnPoint] {
        (0...n).map { LearnPoint.lerp(a, b, Double($0) / Double(n)) }
    }

    func testTraceScorerFindsTheMissedArea() {
        let guide = [line(LearnPoint(0.1, 0.5), LearnPoint(1.2, 0.5))]
        let halfway = [line(LearnPoint(0.1, 0.5), LearnPoint(0.6, 0.5))]
        let r = LearnTraceScorer.score(guide: guide, strokes: halfway)
        XCTAssertLessThan(r.coverage, 0.6)
        XCTAssertGreaterThan(r.accuracy, 0.95)
        XCTAssertEqual(r.missedArea, .right)
        let hint = LearnTraceScorer.hint(for: r, minCoverage: 0.7, minAccuracy: 0.7)
        XCTAssertTrue(hint?.contains("right side") == true, hint ?? "")

        let full = LearnTraceScorer.score(guide: guide, strokes: guide)
        XCTAssertEqual(full.coverage, 1, accuracy: 1e-9)
        XCTAssertEqual(full.accuracy, 1, accuracy: 1e-9)
        XCTAssertNil(LearnTraceScorer.hint(for: full, minCoverage: 0.7, minAccuracy: 0.7))

        // Ink that wanders off is named too.
        let wander = [line(LearnPoint(0.1, 0.5), LearnPoint(1.2, 0.5)), line(LearnPoint(0.1, 0.1), LearnPoint(0.4, 0.1))]
        let w = LearnTraceScorer.score(guide: guide, strokes: wander)
        XCTAssertEqual(w.strayArea, .topLeft)

        // Going over everything again and again is a scribble.
        let many = Array(repeating: guide[0], count: 4)
        XCTAssertTrue(LearnTraceScorer.score(guide: guide, strokes: many).isScribble)
    }

    func testShapeChecks() {
        let straight = line(LearnPoint(0.1, 0.5), LearnPoint(1.0, 0.6))
        let bent = (0...30).map { i -> LearnPoint in
            let t = Double(i) / 30
            return LearnPoint(0.1 + 0.9 * t, 0.5 - 0.2 * sin(Double.pi * t))
        }
        XCTAssertLessThan(LearnMeasure.bend(straight), 0.01)
        XCTAssertGreaterThan(LearnMeasure.bend(bent), 0.15)

        let ring = (0...48).map { i -> LearnPoint in
            let a = 2 * Double.pi * Double(i) / 48
            return LearnPoint(0.6 + 0.3 * cos(a), 0.5 + 0.3 * sin(a))
        }
        XCTAssertLessThan(LearnMeasure.endGap([ring]), 0.001)
        XCTAssertGreaterThan(LearnMeasure.endGap([Array(ring.prefix(30))]), 0.2)
        XCTAssertLessThan(LearnMeasure.wobble(ring), 0.2)

        var rng = SeededRandom(9)
        let shaky = straight.flatMap { p in
            (0..<4).map { _ in LearnPoint(p.x + rng.range(-0.012, 0.012), p.y + rng.range(-0.012, 0.012)) }
        }.enumerated().sorted { $0.element.x < $1.element.x }.map(\.element)
        XCTAssertGreaterThan(LearnMeasure.wobble(shaky), LearnCheck.defaultSmooth)
    }

    func testSpacingChecks() {
        XCTAssertTrue(LearnMeasure.matches([0.1, 0.1, 0.11, 0.1], .even))
        XCTAssertFalse(LearnMeasure.matches([0.02, 0.1, 0.3], .even))
        XCTAssertTrue(LearnMeasure.matches([0.02, 0.06, 0.1, 0.14], .easeIn))
        XCTAssertFalse(LearnMeasure.matches([0.14, 0.1, 0.06, 0.02], .easeIn))
        XCTAssertTrue(LearnMeasure.matches([0.14, 0.1, 0.06, 0.02], .easeOut))
        XCTAssertTrue(LearnMeasure.matches([0.03, 0.1, 0.1, 0.03], .easeInOut))
        XCTAssertFalse(LearnMeasure.matches([0.1, 0.1, 0.1, 0.1], .easeInOut))
    }
}

final class LessonRunTests: XCTestCase {
    func sampleLesson() -> LearnLesson {
        let guideLine = LearnPath(points: [LearnPoint(0.2, 0.5), LearnPoint(1.1, 0.5)])
        return LearnLesson(id: "test.lesson", title: "Test", summary: "A test lesson", minutes: 2, steps: [
            LearnStep(id: "s1", kind: .read, title: "Read", text: "Hello"),
            LearnStep(id: "s2", kind: .trace, title: "Trace", text: "Trace it", hint: "Go slowly",
                      guide: LearnGuide(frames: [LearnGuideFrame(paths: [guideLine])]),
                      checks: [.trace(), LearnCheck(type: .straight)]),
            LearnStep(id: "s3", kind: .quiz, title: "Quiz", text: "",
                      quiz: LearnQuiz(question: "Pick B", choices: ["A", "B"], answer: 1, explain: "B is right.")),
        ])
    }

    func testPerfectRunEarnsThreeStars() {
        var run = LearnLessonRun(lesson: sampleLesson())
        XCTAssertTrue(run.canAdvance)                  // read steps can always move on
        XCTAssertTrue(run.advance())
        XCTAssertFalse(run.canAdvance)                 // trace must be done first
        XCTAssertFalse(run.advance())
        let fb = run.submit(.strokes([[LearnPoint(0.2, 0.5), LearnPoint(1.1, 0.5)]]))
        XCTAssertTrue(fb.passed)
        XCTAssertEqual(fb.stars, 3)
        XCTAssertTrue(run.advance())
        XCTAssertTrue(run.submit(.choice(1)).passed)
        XCTAssertTrue(run.advance())
        XCTAssertTrue(run.isFinished)
        XCTAssertEqual(run.stars, 3)
        XCTAssertEqual(run.progress, 1)
    }

    func testHintAfterOneMissAndSkipAfterThree() {
        var run = LearnLessonRun(lesson: sampleLesson())
        run.advance()
        XCTAssertFalse(run.showHint)
        let wrong = LearnAnswer.strokes([[LearnPoint(0.2, 0.1), LearnPoint(0.3, 0.2)]])

        let first = run.submit(wrong)
        XCTAssertFalse(first.passed)
        XCTAssertEqual(first.hint, "Go slowly")      // hint after the first miss
        XCTAssertTrue(run.showHint)
        XCTAssertFalse(first.canSkip)
        XCTAssertFalse(run.skip())

        XCTAssertFalse(run.submit(wrong).canSkip)
        let third = run.submit(wrong)
        XCTAssertTrue(third.canSkip)                 // skip after three misses
        XCTAssertTrue(run.canSkip)
        XCTAssertTrue(run.skip())
        XCTAssertEqual(run.index, 2)
        XCTAssertTrue(run.records[1].skipped)

        // Back keeps what was done.
        XCTAssertTrue(run.back())
        XCTAssertEqual(run.index, 1)
        XCTAssertTrue(run.canAdvance)
        XCTAssertTrue(run.advance())

        XCTAssertFalse(run.submit(.choice(0)).passed)
        let ok = run.submit(.choice(1))
        XCTAssertTrue(ok.passed)
        XCTAssertEqual(ok.stars, 2)                  // right on the second try
        XCTAssertTrue(run.advance())
        XCTAssertTrue(run.isFinished)
        XCTAssertEqual(run.stars, 1)                 // (0 skipped + 2) / 2 rounds to 1
    }

    func testStarRules() {
        XCTAssertEqual(LearnLessonRun.stars(for: .trace, quality: 0.95, fails: 0), 3)
        XCTAssertEqual(LearnLessonRun.stars(for: .trace, quality: 0.8, fails: 0), 2)
        XCTAssertEqual(LearnLessonRun.stars(for: .trace, quality: 0.7, fails: 0), 1)
        XCTAssertEqual(LearnLessonRun.stars(for: .trace, quality: 0.95, fails: 2), 2)
        XCTAssertEqual(LearnLessonRun.stars(for: .quiz, quality: 1, fails: 0), 3)
        XCTAssertEqual(LearnLessonRun.stars(for: .quiz, quality: 1, fails: 5), 1)
    }

    func testRealLessonPlaysThrough() throws {
        let lib = try LearnCourseLibrary.loadBuiltIn()
        for lesson in lib.lessons {
            var run = LearnLessonRun(lesson: lesson)
            var guardCount = 0
            while !run.isFinished && guardCount < 20 {
                guardCount += 1
                if run.step.kind.isScored {
                    XCTAssertTrue(run.submit(LearnEvaluator.perfectAnswer(for: run.step)).passed, "\(lesson.id)/\(run.step.id)")
                }
                XCTAssertTrue(run.advance(), "\(lesson.id)/\(run.step.id)")
            }
            XCTAssertTrue(run.isFinished, lesson.id)
            XCTAssertEqual(run.stars, 3, lesson.id)
        }
    }
}

final class ProgressTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func day(_ d: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 3, day: d, hour: 15))!
    }

    func testRoundTripAndStreak() throws {
        var p = LearnProgress()
        XCTAssertEqual(p.streak(asOf: day(10), calendar: utc), 0)
        p.recordLesson("a", stars: 2, on: day(8), calendar: utc)
        p.recordLesson("b", stars: 3, on: day(9), calendar: utc)
        p.recordLesson("a", stars: 1, on: day(10), calendar: utc)
        XCTAssertEqual(p.stars(for: "a"), 2)        // best stars are kept
        XCTAssertEqual(p.lessons["a"]?.times, 2)
        XCTAssertEqual(p.lessons["a"]?.firstDone, "2026-03-08")
        XCTAssertEqual(p.totalStars, 5)
        XCTAssertEqual(p.activeDays, ["2026-03-08", "2026-03-09", "2026-03-10"])
        XCTAssertEqual(p.streak(asOf: day(10), calendar: utc), 3)
        XCTAssertEqual(p.streak(asOf: day(11), calendar: utc), 3)   // still alive until the day ends
        XCTAssertEqual(p.streak(asOf: day(12), calendar: utc), 0)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("learn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Learn/progress.json")
        XCTAssertEqual(try LearnProgress.load(from: url), LearnProgress())   // missing file = fresh start
        try p.save(to: url)
        XCTAssertEqual(try LearnProgress.load(from: url), p)
    }

    func testEverythingIsOpen() throws {
        let lib = try LearnCourseLibrary.loadBuiltIn()
        var p = LearnProgress()
        let opened = p.refreshUnlocks(library: lib)
        // Every course and every lesson is open from day one: no circles before real animation.
        XCTAssertEqual(Set(opened), Set(lib.courses.map(\.id)))
        for course in lib.courses {
            XCTAssertTrue(p.isCourseUnlocked(course, in: lib), course.id)
            for lesson in course.lessons {
                XCTAssertTrue(p.isLessonUnlocked(lesson, in: course, library: lib), lesson.id)
            }
        }
        XCTAssertEqual(p.refreshUnlocks(library: lib), [])
        // "Ready" still tells you which courses build on others, as a tip.
        let basics = try XCTUnwrap(lib.course(id: "basics"))
        let principles = try XCTUnwrap(lib.course(id: "principles"))
        XCTAssertTrue(p.isCourseReady(basics, in: lib))
        XCTAssertFalse(p.isCourseReady(principles, in: lib))
        for l in basics.lessons { p.recordLesson(l.id, stars: 3) }
        XCTAssertTrue(p.isCourseReady(principles, in: lib))
        // The real animation course comes first and needs nothing.
        let pro = try XCTUnwrap(lib.course(id: "pro"))
        XCTAssertEqual(lib.tracks.first?.courses.first?.id, "pro")
        XCTAssertEqual(pro.requires, [])
    }

    func testStudioProjectsAreRemembered() throws {
        var p = LearnProgress()
        XCTAssertNil(p.studioProject(lesson: "pro.walk", step: "s3"))
        p.setStudioProject("abc", lesson: "pro.walk", step: "s3")
        XCTAssertEqual(p.studioProject(lesson: "pro.walk", step: "s3"), "abc")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(LearnProgress.self, from: data), p)
        p.setStudioProject(nil, lesson: "pro.walk", step: "s3")
        XCTAssertNil(p.studioProject(lesson: "pro.walk", step: "s3"))
        // Old progress files without the field still load.
        let old = #"{"version":1,"lessons":{},"activeDays":[],"unlockedCourses":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(LearnProgress.self, from: Data(old.utf8)).studioProjects, [:])
    }
}
