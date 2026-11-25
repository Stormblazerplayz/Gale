import XCTest
import GaleFormat
@testable import GaleLearn

final class NarrationTests: XCTestCase {
    func testSentencesKeepAbbreviationsAndQuotes() {
        XCTAssertEqual(LearnNarration.sentences("Squash it. Then stretch it! Ready?"),
                       ["Squash it.", "Then stretch it!", "Ready?"])
        XCTAssertEqual(LearnNarration.sentences("Pick a sound, e.g. the O. Hold it."),
                       ["Pick a sound, e.g. the O.", "Hold it."])
        XCTAssertEqual(LearnNarration.sentences("Say \"hello.\" Then rest"), ["Say \"hello.\"", "Then rest"])
        XCTAssertEqual(LearnNarration.sentences("  "), [])
    }

    func testStepScripts() {
        let read = LearnStep(id: "s1", kind: .read, title: "Squish", text: "It squashes. It stretches.")
        XCTAssertEqual(LearnNarration.lines(for: read), ["Squish.", "It squashes.", "It stretches."])

        let quiz = LearnStep(id: "s2", kind: .quiz, title: "Quick quiz", text: "",
                             quiz: LearnQuiz(question: "Which is slow?", choices: ["Close ticks", "Far ticks"],
                                             answer: 0, explain: ""))
        XCTAssertEqual(LearnNarration.lines(for: quiz), ["Which is slow?", "A. Close ticks", "B. Far ticks"])

        let guide = LearnGuide(frames: [LearnGuideFrame(paths: [])])
        let watch = LearnStep(id: "s3", kind: .watch, title: "T", text: "X", guide: guide,
                              beats: [LearnBeat(say: "One.", from: 0, to: 0), LearnBeat(say: "Two.", from: 0, to: 0)])
        XCTAssertEqual(LearnNarration.lines(for: watch), ["One.", "Two."])

        var own = read
        own.say = ["Custom line."]
        XCTAssertEqual(LearnNarration.lines(for: own), ["Custom line."])
    }

    func testFeedbackScriptAddsHintOnlyAfterAMiss() {
        let miss = LearnFeedback(passed: false, title: "Almost", message: "Cover more of the line.", hint: "Go slower.",
                                 canSkip: false, stars: 0)
        XCTAssertEqual(LearnNarration.lines(for: miss), ["Almost.", "Cover more of the line.", "Go slower."])
        let hit = LearnFeedback(passed: true, title: "Nice!", message: "Spot on.", hint: "Go slower.",
                                canSkip: false, stars: 3)
        XCTAssertEqual(LearnNarration.lines(for: hit), ["Nice!", "Spot on."])
    }

    func testSpeechTextAndCaptionWords() {
        XCTAssertEqual(LearnNarration.speechText("Squash & stretch, e.g. a \"ball\""),
                       "Squash and stretch, for example a ball")
        let text = "Hi there, it's me"
        let ranges = LearnNarration.wordRanges(in: text)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(LearnNarration.wordIndex(atUTF16: 0, in: ranges), 0)
        XCTAssertEqual(LearnNarration.wordIndex(atUTF16: 4, in: ranges), 1)
        XCTAssertEqual(LearnNarration.wordIndex(atUTF16: 10, in: ranges), 2)  // "it's" stays one word
        XCTAssertEqual(LearnNarration.wordIndex(atUTF16: 999, in: ranges), 3)
        // Same words spoken and shown: same index.
        XCTAssertEqual(LearnNarration.captionWord(shown: text, spoken: text, spokenOffset: 10), 2)
        // "&" becomes "and": the caption still lands on a sensible word.
        let shown = "Squash & stretch now"
        let spoken = LearnNarration.speechText(shown)
        let last = (spoken as NSString).range(of: "now").location
        XCTAssertEqual(LearnNarration.captionWord(shown: shown, spoken: spoken, spokenOffset: last), 2)
        XCTAssertGreaterThanOrEqual(LearnNarration.readingSeconds("Hi"), 1.8)
        XCTAssertEqual(LearnNarration.letter(2), "C")
    }

    func testEveryBuiltInStepHasSomethingToSay() throws {
        let lib = try LearnCourseLibrary.loadBuiltIn()
        for lesson in lib.lessons {
            for step in lesson.steps {
                XCTAssertFalse(LearnNarration.lines(for: step).isEmpty, "\(lesson.id)/\(step.id) is silent")
            }
        }
    }
}

final class MotionTests: XCTestCase {
    func guide(_ xs: [Double]) -> LearnGuide {
        LearnGuide(frames: xs.map { x in
            LearnGuideFrame(paths: [LearnPath(points: [LearnPoint(x - 0.01, 0.5), LearnPoint(x + 0.01, 0.5)])])
        })
    }

    func testTrailChartAndSpacing() {
        let g = guide([0.1, 0.12, 0.2, 0.4, 0.6, 0.68, 0.7])
        let trail = LearnMotion.trail(g, range: 0...6)
        XCTAssertEqual(trail.count, 7)
        XCTAssertEqual(trail[0].x, 0.1, accuracy: 1e-9)
        let chart = LearnMotion.chart(trail)
        XCTAssertEqual(chart.first, 0)
        XCTAssertEqual(chart.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(LearnMotion.spacing(of: LearnMotion.gaps(trail)), .easeInOut)
        XCTAssertEqual(LearnMotion.spacing(of: LearnMotion.gaps(LearnMotion.trail(guide([0.1, 0.2, 0.3, 0.4]),
                                                                                    range: 0...3))), .even)
        XCTAssertNil(LearnMotion.spacing(of: [0.1]))
        // A guide track wins over the middle of the ink.
        var tracked = g
        tracked.track = (0..<7).map { LearnPoint(Double($0), 0) }
        XCTAssertEqual(tracked.trackPoint(frame: 3), LearnPoint(3, 0))
        // A range past the end is clamped.
        XCTAssertEqual(LearnMotion.trail(g, range: 5...20).count, 2)
    }

    func testBeatPlayback() {
        var g = guide([0.1, 0.2, 0.3, 0.4])
        g.fps = 10
        g.frames[1].hold = 3
        let b = LearnBeat(say: "x", from: 1, to: 2)
        XCTAssertEqual(LearnMotion.playlist(g, beat: b).map(\.frame), [1, 2])
        XCTAssertEqual(LearnMotion.playlist(g, beat: b).map(\.ticks), [3, 1])
        XCTAssertEqual(LearnMotion.frame(g, beat: b, seconds: 0), 1)
        XCTAssertEqual(LearnMotion.frame(g, beat: b, seconds: 0.25), 1)
        XCTAssertEqual(LearnMotion.frame(g, beat: b, seconds: 0.35), 2)
        // Half speed takes twice as long.
        XCTAssertEqual(LearnMotion.frame(g, beat: b, seconds: 0.35, speed: 0.5), 1)
        // Holding one drawing always shows it.
        XCTAssertEqual(LearnMotion.frame(g, beat: LearnBeat(say: "x", from: 3, to: 3), seconds: 9), 3)
        XCTAssertEqual(g.startTick(ofFrame: 2), 4)
    }

    func testBeatsAndTracksSurviveJSON() throws {
        let step = LearnStep(id: "s1", kind: .watch, title: "W", text: "",
                             guide: LearnGuide(frames: [LearnGuideFrame(paths: []), LearnGuideFrame(paths: [])],
                                               track: [LearnPoint(0.1, 0.2), LearnPoint(0.3, 0.4)]),
                             say: ["Hello."], beats: [LearnBeat(say: "Look.", from: 0, to: 1, overlays: [.trail, .chart])])
        let data = try JSONEncoder().encode(step)
        let back = try JSONDecoder().decode(LearnStep.self, from: data)
        XCTAssertEqual(back, step)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"show\""))
        XCTAssertTrue(json.contains("\"track\":[0.1,0.2,0.3,0.4]"))
        // Unknown overlays from a newer lesson file don't break loading.
        let newer = #"{"say":"Hi","from":0,"to":0,"show":["sparkles"]}"#
        XCTAssertEqual(try JSONDecoder().decode(LearnBeat.self, from: Data(newer.utf8)).overlays, [.slow])
        // A track with an odd number of values is rejected.
        let odd = #"{"frames":[{"paths":[]}],"track":[0.1]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LearnGuide.self, from: Data(odd.utf8)))
    }

    func testWatchStepsAreChecked() throws {
        let lib = try LearnCourseLibrary.loadBuiltIn()
        let watch = try XCTUnwrap(lib.lessons.flatMap(\.steps).first { $0.kind == .watch })
        XCTAssertTrue(LearnEvaluator.evaluate(watch, answer: .done).passed)
        var bad = watch
        bad.beats.append(LearnBeat(say: "Out of range", from: 0, to: 999))
        let lesson = LearnLesson(id: "t", title: "T", summary: "", minutes: 1, steps: [bad, bad, bad])
        XCTAssertFalse(LearnCourseLibrary.problems(in: lesson).isEmpty)
    }
}

final class StudioTests: XCTestCase {
    func animateStep() throws -> (LearnLesson, LearnStep) {
        let lib = try LearnCourseLibrary.loadBuiltIn()
        for lesson in lib.lessons {
            if let s = lesson.steps.first(where: { $0.kind == .animate }) { return (lesson, s) }
        }
        throw XCTSkip("no animate step")
    }

    func testProjectHasGuideAndDrawLayers() throws {
        let (lesson, step) = try animateStep()
        let guide = try XCTUnwrap(step.guide)
        let project = try XCTUnwrap(LearnStudio.makeProject(for: step, lessonTitle: lesson.title))
        XCTAssertEqual(project.layers.map(\.name), [LearnStudio.guideLayerName, LearnStudio.drawLayerName])
        XCTAssertTrue(project.layers[0].locked)
        XCTAssertFalse(project.layers[1].locked)
        XCTAssertEqual(project.frames.count, guide.frames.count)
        XCTAssertEqual(project.frames.map(\.hold), guide.frames.map { max(1, $0.hold) })
        XCTAssertEqual(project.fps, guide.fps)
        XCTAssertEqual(project.canvas.height, LearnStudio.canvasHeight)
        XCTAssertEqual(project.canvas.width, (guide.aspect * LearnStudio.canvasHeight).rounded())
        let ids = LearnStudio.layerIDs(in: project)
        for frame in project.frames {
            XCTAssertFalse(frame.cel(ids.guide!).strokes.isEmpty)
            XCTAssertTrue(frame.cel(ids.draw!).strokes.isEmpty)
        }
        // Nothing drawn yet: nothing to check, and it doesn't pass.
        let empty = LearnStudio.answerFrames(from: project)
        XCTAssertEqual(LearnStudio.drawnFrameCount(empty), 0)
        XCTAssertFalse(LearnEvaluator.evaluate(step, answer: .frames(empty)).passed)
        // The project saves and loads in Gale's real format.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try GaleIO.writeProject(project, to: dir)
        let back = try GaleIO.readProject(at: dir)
        XCTAssertEqual(back.layers.map(\.name), project.layers.map(\.name))
        XCTAssertEqual(back.frames.count, project.frames.count)
    }

    /// Draws the guide's own lines on the learner's layer, like a careful learner would.
    func drawPerfectly(_ project: inout GaleProject, step: LearnStep) {
        let ids = LearnStudio.layerIDs(in: project)
        let h = project.canvas.height
        for (i, gf) in step.guide!.frames.enumerated() {
            var cel = project.frames[i].cel(ids.draw!)
            for line in gf.inkStrokes {
                let pts = line.map { StrokePoint(x: $0.x * h, y: $0.y * h, pressure: 0.6) }
                cel.append(Stroke(brush: Brush(kind: .pen, color: .black, size: 6), points: pts))
            }
            project.frames[i].cels[ids.draw!] = cel
        }
    }

    func testDrawingInTheProjectPassesTheChecks() throws {
        let (lesson, step) = try animateStep()
        var project = try XCTUnwrap(LearnStudio.makeProject(for: step, lessonTitle: lesson.title))
        drawPerfectly(&project, step: step)
        let answer = LearnStudio.answerFrames(from: project)
        XCTAssertEqual(LearnStudio.drawnFrameCount(answer), step.guide!.frames.count)
        let r = LearnEvaluator.evaluate(step, answer: .frames(answer))
        XCTAssertTrue(r.passed, r.message)

        // The guide layer alone never counts as the learner's work.
        let guideOnly = try XCTUnwrap(LearnStudio.makeProject(for: step, lessonTitle: lesson.title))
        XCTAssertFalse(LearnEvaluator.evaluate(step, answer: .frames(LearnStudio.answerFrames(from: guideOnly))).passed)

        // Rubbing everything out on one frame makes it fail again.
        let ids = LearnStudio.layerIDs(in: project)
        let h = project.canvas.height
        var cel = project.frames[0].cel(ids.draw!)
        var sweep: [StrokePoint] = []
        for row in stride(from: 0.0, through: 1.0, by: 0.02) {
            sweep.append(StrokePoint(x: 0, y: row * h))
            sweep.append(StrokePoint(x: 2.5 * h, y: row * h))
        }
        cel.append(Stroke(brush: Brush(kind: .eraser, color: .black, size: 0.05 * h), points: sweep))
        project.frames[0].cels[ids.draw!] = cel
        let rubbed = LearnStudio.answerFrames(from: project)
        XCTAssertTrue(rubbed[0].isEmpty)
        XCTAssertFalse(LearnEvaluator.evaluate(step, answer: .frames(rubbed)).passed)
    }

    func testEraserCutsLines() {
        let line = [LearnPoint(0, 0.5), LearnPoint(1, 0.5)]
        let cut = LearnStudio.erase([line], along: [LearnPoint(0.5, 0.4), LearnPoint(0.5, 0.6)], radius: 0.05)
        XCTAssertEqual(cut.count, 2)
        XCTAssertLessThan(cut[0].last!.x, 0.46)
        XCTAssertGreaterThan(cut[1].first!.x, 0.54)
        XCTAssertEqual(LearnStudio.erase([line], along: [], radius: 0.05), [line])
    }

    func testEveryAnimateStepBuildsAProject() throws {
        let lib = try LearnCourseLibrary.loadBuiltIn()
        var count = 0
        for lesson in lib.lessons {
            for step in lesson.steps where step.kind == .animate {
                count += 1
                var project = try XCTUnwrap(LearnStudio.makeProject(for: step, lessonTitle: lesson.title), lesson.id)
                drawPerfectly(&project, step: step)
                let r = LearnEvaluator.evaluate(step, answer: .frames(LearnStudio.answerFrames(from: project)))
                XCTAssertTrue(r.passed, "\(lesson.id)/\(step.id): \(r.message)")
            }
        }
        XCTAssertGreaterThanOrEqual(count, 8)
    }
}
