import XCTest

/// Opens the Learn section on an iPad simulator and walks through the first "Animate Like a Pro" lesson:
/// the narrated demo shows captions, and the "animate it" step opens the real Gale editor, where a line
/// drawn on the canvas comes back to the lesson as a drawn frame.
/// Screenshots of each step are saved with the test results.
final class LearnUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
    }

    // MARK: Helpers

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @discardableResult
    func waitFor(_ e: XCUIElement, timeout: TimeInterval = 10, _ message: String) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), message)
        return e
    }

    /// Waits until the element's label contains `text`.
    func waitForLabel(_ e: XCUIElement, contains text: String, timeout: TimeInterval = 10, _ message: String) {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        let exp = XCTNSPredicateExpectation(predicate: p, object: e)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        let now = e.exists ? e.label : "the element is gone"
        XCTAssertEqual(result, .completed, "\(message) (label was: \(now))")
    }

    /// Scrolls up until the element can be tapped.
    func scrollTo(_ e: XCUIElement, _ message: String) {
        var tries = 0
        while !(e.exists && e.isHittable) && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(e.exists && e.isHittable, message)
    }

    // MARK: Tests

    func testProLessonTalksAndOpensTheEditor() {
        // Home → Learn.
        let learn = app.buttons["Learn"].firstMatch
        waitFor(learn, timeout: 15, "The home screen should have a Learn button")
        learn.tap()

        // The pro course is first in the 2D Animation track and open from the start.
        let course = element("learnCourse-pro")
        waitFor(course, timeout: 15, "The Animate Like a Pro course should be on the Learn screen")
        scrollTo(course, "The Animate Like a Pro course should be tappable")
        shot("1 Learn home")
        course.tap()

        let lesson = element("learnLesson-pro.timing")
        waitFor(lesson, "The course should list the Timing & Spacing lesson")
        lesson.tap()

        // A narrated demo: captions show the words being said (the voice is off in UI tests).
        let caption = element("learnCaption")
        waitFor(caption, timeout: 10, "The demo should show captions while it plays")
        shot("2 Watch step with captions")

        // Two watch steps, then the animate step.
        for i in 1...2 {
            let next = app.buttons["Next"].firstMatch
            waitFor(next, "Watch step \(i) should have a Next button")
            XCTAssertTrue(next.isEnabled, "Watch step \(i) shouldn't need anything before Next")
            next.tap()
        }

        let open = element("learnOpenInGale")
        waitFor(open, timeout: 10, "The animate step should have an Animate it in Gale button")
        let count = element("learnAnimateCount")
        waitFor(count, "The animate step should say how many frames to draw")
        waitForLabel(count, contains: "frames to animate", "Nothing should be drawn yet")
        shot("3 Animate step")
        open.tap()

        // The real editor opens on the lesson project.
        let canvas = element("canvas")
        waitFor(canvas, timeout: 15, "The Gale editor should open with a canvas")
        shot("4 Editor with the lesson guide")

        // Draw one line on the first frame, like a person would.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let p = NSPredicate(format: "value CONTAINS %@", "strokes 1,")
        let drew = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: canvas)], timeout: 10)
        XCTAssertEqual(drew, .completed,
                       "The line should land on the Your animation layer (canvas: \(canvas.value as? String ?? "nil"))")
        shot("5 Drew a line")

        // Back to the lesson: the drawing comes back as one drawn frame.
        let back = element("learnBackToLesson")
        waitFor(back, "The editor should have a Back to lesson button")
        back.tap()
        waitFor(count, timeout: 10, "The animate step should come back after the editor closes")
        waitForLabel(count, contains: "drawn 1 of", "The line drawn in the editor should count as one frame")
        let check = app.buttons["Check"].firstMatch
        waitFor(check, "The animate step should have a Check button")
        XCTAssertTrue(check.isEnabled, "Check should turn on once something is drawn")
        shot("6 Back in the lesson")
    }
}
