import XCTest

/// Checks the home screen after the 3D body scan was taken out: no scan button anywhere,
/// and the Learn and Computer tiles sit neatly at the top and still work.
final class HomeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
    }

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

    func testHomeHasNoBodyScanAndTheTilesWork() {
        let learn = waitFor(element("homeLearn"), timeout: 15, "The home screen should have a Learn tile")
        let computer = waitFor(element("homeComputer"), "The home screen should have a Computer tile")
        let newProject = waitFor(element("newProject"), "The New button should be on the home screen")
        shot("Home 1 Tiles")

        // The body scan is gone: no button, no label, anywhere on the home screen.
        let scan = NSPredicate(format: "label CONTAINS[c] %@", "scan")
        XCTAssertEqual(app.buttons.matching(scan).count, 0, "No button should mention a scan")
        XCTAssertFalse(app.buttons["Body scan"].exists, "The Body scan button should be gone")
        XCTAssertFalse(app.staticTexts["Body scan"].exists, "No Body scan text should be left")

        // The two tiles sit side by side on iPad, the same size, above the projects, with no overlap.
        XCTAssertEqual(learn.frame.minY, computer.frame.minY, accuracy: 2, "Learn and Computer should line up")
        XCTAssertEqual(learn.frame.height, computer.frame.height, accuracy: 2, "Learn and Computer should be the same height")
        XCTAssertLessThan(learn.frame.maxX, computer.frame.minX, "Learn should be left of Computer")
        XCTAssertLessThanOrEqual(learn.frame.maxY, newProject.frame.minY, "The tiles should sit above the projects")
        XCTAssertEqual(learn.label, "Learn")
        XCTAssertEqual(computer.label, "Computer")
        XCTAssertEqual(computer.value as? String, "Not connected", "A fresh install isn't paired to a computer")
        XCTAssertTrue(app.staticTexts["Your projects"].exists, "The projects section should have a title")

        // Computer opens the pairing sheet.
        computer.tap()
        waitFor(app.navigationBars["Your computer"], "Computer should open the pairing screen")
        shot("Home 2 Computer sheet")
        app.navigationBars["Your computer"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Your computer"].waitForNonExistence(timeout: 5), "Done should close the pairing screen")

        // Learn opens lessons.
        waitFor(element("homeLearn"), "The Learn tile should be back").tap()
        waitFor(element("learnCourse-pro"), timeout: 15, "Learn should open the lessons")
        shot("Home 3 Learn")
        app.buttons["Close"].firstMatch.tap()
        waitFor(element("newProject"), "Close should go back home")
    }

    func testNewProjectStillOpensFromTheNewCard() {
        waitFor(element("newProject"), timeout: 15, "The New card should be on the home screen").tap()
        waitFor(element("createProject"), "The new project sheet should open").tap()
        waitFor(element("canvas"), timeout: 15, "The editor should open with a canvas")
        shot("Home 4 Editor from New")
    }
}
