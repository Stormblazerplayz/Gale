import XCTest

/// Opens Gale on an iPad simulator, draws like a person would, and checks that every editor control does something.
/// Screenshots of each step are saved with the test results.
final class EditorUITests: XCTestCase {
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

    /// Waits until the element's value contains `text`.
    func waitForValue(_ e: XCUIElement, contains text: String, timeout: TimeInterval = 10, _ message: String) {
        let p = NSPredicate(format: "value CONTAINS %@", text)
        let exp = XCTNSPredicateExpectation(predicate: p, object: e)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        let now = e.exists ? (e.value as? String ?? "nil") : "the element is gone"
        XCTAssertEqual(result, .completed, "\(message) (value was: \(now))")
    }

    /// Waits until the element's value contains none of `texts`.
    func waitForValue(_ e: XCUIElement, notContaining texts: [String], timeout: TimeInterval = 10, _ message: String) {
        let p = NSPredicate { obj, _ in
            guard let el = obj as? XCUIElement, el.exists else { return false }
            let v = el.value as? String ?? ""
            return !texts.contains { v.contains($0) }
        }
        let exp = XCTNSPredicateExpectation(predicate: p, object: e)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        let now = e.exists ? (e.value as? String ?? "nil") : "the element is gone"
        XCTAssertEqual(result, .completed, "\(message) (value was: \(now))")
    }

    /// Waits until a number in the canvas description passes a check, and returns it.
    @discardableResult
    func waitForNumber(_ key: String, timeout: TimeInterval = 10, _ message: String, _ ok: (Int) -> Bool) -> Int {
        let canvas = element("canvas")
        let end = Date().addingTimeInterval(timeout)
        var last = -1
        repeat {
            last = number(key, in: canvas.value as? String ?? "")
            if ok(last) { return last }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        XCTFail("\(message) (\(key) was \(last), canvas: \(canvas.value as? String ?? "nil"))")
        return last
    }

    func number(_ key: String, in text: String) -> Int {
        // The canvas describes itself like "strokes 2, fills 0, ink 1234, onion off, bend 12, zoom 0.69".
        for part in text.components(separatedBy: ", ") {
            let bits = part.split(separator: " ")
            if bits.count == 2, bits[0] == key, let n = Int(bits[1]) { return n }
        }
        return -1
    }

    func canvasValue() -> String { element("canvas").value as? String ?? "" }

    /// Taps somewhere harmless to close a menu or popover (the top-left corner, over the status bar area).
    /// Close a popover or menu the way a person would: tap outside it.
    /// The very top corner is the status bar, which iPadOS ignores, so tap the
    /// popover's dismiss area on the left side, or the empty middle of the top bar.
    func tapAway() {
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.exists {
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.055)).tap()
        }
    }

    /// If a menu is still open after picking from it, close it so the next tap is not swallowed.
    func closeMenu(_ item: XCUIElement) {
        if item.waitForNonExistence(timeout: 2) { return }
        tapAway()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "The menu should close")
    }

    func openNewProject() {
        waitFor(element("newProject"), "The New button should be on the home screen").tap()
        waitFor(element("createProject"), "The new project sheet should open").tap()
        waitFor(element("canvas"), timeout: 15, "The editor should open with a canvas")
    }

    /// The paper must sit in the middle and fill the space, not hide as a small box in a corner.
    func checkCanvasFills(_ label: String) {
        let canvas = element("canvas")
        let window = app.windows.firstMatch.frame
        let f = canvas.frame
        let fills = f.width >= window.width * 0.8 || f.height >= window.height * 0.6
        XCTAssertTrue(fills, "\(label): canvas \(f) is too small for the screen \(window)")
        XCTAssertLessThan(abs(f.midX - window.midX), 30, "\(label): canvas \(f) isn't centered left to right in \(window)")
        XCTAssertGreaterThanOrEqual(f.minX, window.minX - 1, "\(label): canvas \(f) runs off the left side")
        XCTAssertLessThanOrEqual(f.maxX, window.maxX + 1, "\(label): canvas \(f) runs off the right side")
        XCTAssertGreaterThan(f.minY, window.minY + 40, "\(label): canvas \(f) is stuck at the top")
        XCTAssertLessThan(f.maxY, window.maxY - 80, "\(label): canvas \(f) covers the frames strip")
        // Equal space above and below (between the top bar and the frames strip), within a few points.
        let bar = app.navigationBars.firstMatch.frame
        let strip = element("frame-1").frame
        if bar.height > 0, strip.height > 0 {
            let above = f.minY - bar.maxY
            let below = (strip.minY - 10) - f.maxY
            XCTAssertGreaterThan(above, 0, "\(label): canvas overlaps the top bar")
            XCTAssertGreaterThan(below, -10, "\(label): canvas overlaps the frames strip")
        }
    }

    func drawLine(from a: CGVector, to b: CGVector) {
        let canvas = element("canvas")
        canvas.coordinate(withNormalizedOffset: a).press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: b))
    }

    // MARK: The test

    func testEditorDrawsAndEveryButtonWorks() {
        openNewProject()
        let canvas = element("canvas")
        Thread.sleep(forTimeInterval: 1)
        shot("01 New project")

        // 1. Canvas size and position.
        checkCanvasFills("Landscape")

        // 2. Draw a line with a finger.
        drawLine(from: CGVector(dx: 0.2, dy: 0.3), to: CGVector(dx: 0.8, dy: 0.7))
        shot("02a Right after the first line")
        print("Canvas after the first line: \(canvasValue())")
        XCTAssertTrue(canvas.waitForExistence(timeout: 3), "Drawing a line to the right left the editor (the back swipe took it)")
        waitForValue(canvas, contains: "strokes 1,", "Drawing a line should add one stroke")
        let ink = waitForNumber("ink", "The line should show up on the canvas") { $0 > 40 }
        let straightBend = number("bend", in: canvasValue())
        XCTAssertLessThan(straightBend, 25, "A straight finger line came out with a \(straightBend)° kink")
        shot("02 After drawing a line")

        // 3. The frame thumbnail shows the drawing.
        waitForValue(element("frame-1"), contains: "has drawing", "Frame 1's thumbnail should show the line")

        // 4. A shaky wave comes out smooth (same steps as a real finger, with a shaky hand).
        waitFor(element("testScribble"), "Test scribble button").tap()
        waitForValue(canvas, contains: "strokes 2,", "The test scribble should add a stroke")
        let bend = number("bend", in: canvasValue())
        XCTAssertGreaterThanOrEqual(bend, 0)
        XCTAssertLessThan(bend, 35, "Shaky wave still has a \(bend)° kink. Smoothing isn't working while drawing.")
        waitForNumber("ink", "More ink after the scribble") { $0 > ink }
        shot("03 Shaky wave, smoothed")

        // 5. Undo and redo.
        app.buttons["Undo"].tap()
        waitForValue(canvas, contains: "strokes 1,", "Undo should remove the wave")
        app.buttons["Redo"].tap()
        waitForValue(canvas, contains: "strokes 2,", "Redo should bring it back")

        // 5b. The smoothing slider is right on the toolbar, starts light, and Off really draws exactly.
        let smoothing = waitFor(element("smoothing"), "The smoothing slider should be on the toolbar")
        waitForValue(smoothing, contains: "25%", "Smoothing should start light")
        element("smoothingOff").tap()
        waitForValue(smoothing, contains: "Off", "The scribble button next to the slider should turn smoothing off")
        shot("03b Smoothing off")
        element("testScribble").tap()
        waitForValue(canvas, contains: "strokes 3,", "The test scribble should add a stroke with smoothing off")
        let offBend = number("bend", in: canvasValue())
        XCTAssertGreaterThan(offBend, bend, "With smoothing off the shake should stay (\(offBend)° vs \(bend)° smoothed)")
        app.buttons["Undo"].tap()
        waitForValue(canvas, contains: "strokes 2,", "Undo the unsmoothed wave")
        // Drag the knob the way a finger does: hold it, then slide it slowly. A quick synthesized drag can be
        // lost while the app is still busy redrawing after the undo, and the slider then never moves.
        let knob = smoothing.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 16, dy: 0))
        let target = smoothing.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        knob.press(forDuration: 0.4, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForValue(smoothing, notContaining: ["Off"], "Dragging the slider should turn smoothing back on")

        // 5c. Face mode: one tap turns smoothing off for details, one more tap brings the slider back.
        let faceMode = waitFor(element("faceMode"), "The Face mode button should be on the toolbar")
        waitForValue(faceMode, contains: "off", "Face mode should start off")
        faceMode.tap()
        waitForValue(faceMode, contains: "on", "Tapping Face mode should turn it on")
        waitForValue(smoothing, contains: "Face", "The slider should show Face while Face mode is on")
        shot("03c Face mode on")
        element("testScribble").tap()
        waitForValue(canvas, contains: "strokes 3,", "The test scribble should add a stroke in Face mode")
        let faceBend = number("bend", in: canvasValue())
        XCTAssertGreaterThan(faceBend, bend, "Face mode should draw the shake exactly (\(faceBend)° vs \(bend)° smoothed)")
        app.buttons["Undo"].tap()
        waitForValue(canvas, contains: "strokes 2,", "Undo the Face mode wave")
        faceMode.tap()
        waitForValue(faceMode, contains: "off", "Tapping Face mode again should turn it off")
        waitForValue(smoothing, notContaining: ["Face", "Off"], "Turning Face mode off should bring the slider setting back")

        // 6. Lasso: tap on the line to pick it, then the selection buttons show.
        element("tool-select").tap()
        waitForValue(element("tool-select"), contains: "selected", "Select tool should turn on")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4)).tap()
        waitFor(app.buttons["Delete"], "Tapping a line with the lasso should pick it and show Delete")
        shot("04 Lasso picked a line")
        app.buttons["Done"].tap()

        // 7. Brush size: opens the brush settings.
        element("tool-brush").tap()
        element("brushSize").tap()
        waitFor(app.staticTexts["Smoothing"], "Brush size should open brush settings")
        shot("05 Brush settings")

        // 7b. Stabilizer panel: keep-corners switch, then the hand test measures a few traced shapes.
        waitFor(element("sharpCorners"), "Brush settings should have the Keep corners sharp switch")
        let test = waitFor(element("stabilizerTest"), "Brush settings should have the stabilizer test button")
        test.tap()
        waitFor(element("calibrationStep"), "The stabilizer test should open")
        shot("05b Stabilizer test")
        let pad = waitFor(element("calibrationPad"), "The stabilizer test should have a tracing pad")
        // Trace across the pad slowly, like a hand would, until Gale has enough to measure.
        for _ in 0..<4 where !element("useCalibration").exists && !element("calibrationFinishEarly").exists {
            pad.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7)).press(
                forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)),
                withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            Thread.sleep(forTimeInterval: 0.8)
        }
        if !element("useCalibration").exists {
            waitFor(element("calibrationFinishEarly"), "After two traced shapes Gale should offer the result").tap()
        }
        let use = waitFor(element("useCalibration"), "The stabilizer test should show a result")
        waitFor(element("calibrationLevel"), "The result should say how steady the hand is")
        shot("05c Stabilizer result")
        use.tap()
        XCTAssertTrue(element("useCalibration").waitForNonExistence(timeout: 5), "Using the result should close the test")
        element("brushSize").tap()
        waitFor(element("tunedBadge"), "Using the result should mark smoothing as tuned to your hand")
        tapAway()
        XCTAssertTrue(app.staticTexts["Smoothing"].waitForNonExistence(timeout: 5), "Brush settings should close")

        // 8. Color: opens the color picker.
        element("color").tap()
        waitForValue(element("color"), contains: "picker open", "The color button should open the color picker")
        waitFor(app.otherElements["PopoverDismissRegion"], "The color picker should show as a popup")
        Thread.sleep(forTimeInterval: 1)
        shot("06 Color picker")
        tapAway()
        waitForValue(element("color"), contains: "picker closed", "Tapping outside should close the color picker")

        // 9. Fill: tap an empty spot and it fills.
        element("tool-fill").tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)).tap()
        waitForValue(canvas, contains: "fills 1,", timeout: 15, "Fill should fill the empty area")
        shot("07 Fill")
        app.buttons["Undo"].tap()
        waitForValue(canvas, contains: "fills 0,", "Undo removes the fill")

        // 10. Eraser: rubbing over the line takes paint away.
        element("tool-eraser").tap()
        waitForValue(element("tool-eraser"), contains: "selected", "Eraser should turn on")
        let before = number("ink", in: canvasValue())
        drawLine(from: CGVector(dx: 0.2, dy: 0.3), to: CGVector(dx: 0.8, dy: 0.7))
        waitForValue(canvas, contains: "strokes 3,", "The eraser should add an eraser stroke")
        waitForNumber("ink", "Erasing should remove paint") { $0 >= 0 && $0 < before }
        shot("08 Eraser")
        app.buttons["Undo"].tap()
        waitForValue(canvas, contains: "strokes 2,", "Undo the eraser")
        element("tool-brush").tap()

        // 11. Play: shows the animation, tap to stop.
        element("play").tap()
        waitFor(element("player"), "Play should show the animation")
        waitForValue(element("player"), contains: "frame", "The player should show a frame")
        shot("09 Playing")
        element("player").tap()
        XCTAssertTrue(element("player").waitForNonExistence(timeout: 5), "Tapping should stop playing")

        // 12. New frame, and onion skin shows the frame before.
        app.buttons["New frame"].tap()
        waitFor(element("frame-2"), "New frame should add frame 2")
        waitForValue(canvas, contains: "strokes 0,", "Frame 2 starts empty")
        waitForValue(canvas, contains: "onion on", timeout: 10, "Onion skin should show frame 1 behind frame 2")
        shot("10 Frame 2 with onion skin")
        element("onion").tap()
        let onionToggle = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Onion skin'")).firstMatch
        waitFor(onionToggle, "The onion skin menu should open").tap()
        waitForValue(element("onion"), contains: "off", "Onion skin should turn off")
        waitForValue(canvas, contains: "onion off", "The ghost should go away")
        closeMenu(onionToggle)
        element("onion").tap()
        waitFor(onionToggle, "The onion skin menu should open again").tap()
        waitForValue(element("onion"), contains: "on", "Onion skin should turn back on")
        closeMenu(onionToggle)

        // 13. Panels (layers).
        element("panels").tap()
        waitForValue(element("panels"), contains: "open", "Panels should open")
        waitFor(app.staticTexts["Layers"], "The layers panel should show")
        shot("11 Layers panel")
        element("panels").tap()
        waitForValue(element("panels"), contains: "closed", "Panels should close")

        // 14. Hair tool opens the hair panel.
        element("tool-hair").tap()
        waitForValue(element("panels"), contains: "open", "The hair tool should open the hair panel")
        waitFor(app.staticTexts["Hair"], "The hair panel should show")
        shot("12 Hair tool")
        element("panels").tap()
        element("tool-brush").tap()

        // 15. More menu.
        element("more").tap()
        waitFor(app.buttons["Export"], "More should show Export")
        shot("13 More menu")
        app.buttons["Fit to screen"].tap()

        // 16. Frame 1 again: its drawing is still there.
        element("frame-1").tap()
        waitForValue(canvas, contains: "strokes 2,", "Frame 1 still has its lines")
        Thread.sleep(forTimeInterval: 0.5)
        checkCanvasFills("Landscape after using the panels")

        // 17. Portrait too.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        checkCanvasFills("Portrait")
        shot("14 Portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        checkCanvasFills("Back to landscape")
        shot("15 Done")
    }
}
