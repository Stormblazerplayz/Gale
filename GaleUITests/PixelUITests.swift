import XCTest

/// Makes a pixel story the way a person would: draw, fill, undo, add a frame, add a scene with words
/// and a bubble, play the story, and export a GIF. Screenshots of each step are kept with the results.
final class PixelUITests: XCTestCase {
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
    func waitFor(_ e: XCUIElement, timeout: TimeInterval = 15, _ message: String) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), message)
        return e
    }

    /// A number from the pixel canvas description, like "ink 12, frames 2, scenes 1, frame 2".
    func number(_ key: String) -> Int {
        let text = element("pixelCanvas").value as? String ?? ""
        for part in text.components(separatedBy: ", ") {
            let bits = part.split(separator: " ")
            if bits.count == 2, bits[0] == key, let n = Int(bits[1]) { return n }
        }
        return -1
    }

    @discardableResult
    func waitForNumber(_ key: String, timeout: TimeInterval = 10, _ message: String, _ ok: (Int) -> Bool) -> Int {
        let end = Date().addingTimeInterval(timeout)
        var last = -1
        repeat {
            last = number(key)
            if ok(last) { return last }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        XCTFail("\(message) (\(key) was \(last), canvas: \(element("pixelCanvas").value as? String ?? "nil"))")
        return last
    }

    func testPixelStoryFromStartToExport() {
        waitFor(element("newPixelStory"), "The home screen shows the Pixel Storytime card").tap()
        let start = waitFor(element("createPixelStory"), "The retro start screen opens")
        shot("1 start screen")
        start.tap()

        let canvas = waitFor(element("pixelCanvas"), timeout: 20, "The pixel editor opens")
        shot("2 empty editor")
        XCTAssertEqual(number("ink"), 0, "A new story starts empty")
        XCTAssertEqual(number("frames"), 1)
        XCTAssertEqual(number("scenes"), 1)

        // Pencil: drag a line across the grid.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        let line = waitForNumber("ink", "The pencil drew pixels") { $0 > 5 }
        shot("3 pencil line")

        // Fill: tap the empty corner, which fills around the line.
        element("pixelTool-fill").tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.05)).tap()
        waitForNumber("ink", "Fill colored the empty space") { $0 > line + 100 }
        shot("4 filled")

        // Undo takes the fill back and leaves the line.
        element("pixelUndo").tap()
        waitForNumber("ink", "Undo took the fill back") { $0 == line }

        // A new frame is blank and selected.
        element("addPixelFrame").tap()
        waitForNumber("frames", "A frame was added") { $0 == 2 }
        waitForNumber("ink", "The new frame is blank") { $0 == 0 }
        XCTAssertEqual(number("frame"), 2, "The new frame is the one being drawn")
        shot("5 second frame")

        // Storyboard: add a scene with words and a speech bubble.
        element("openStoryboard").tap()
        waitFor(element("sceneCard-1"), "The storyboard shows the first scene")
        element("addScene").tap()
        waitFor(element("sceneCard-2"), "A second scene was added")
        let caption = waitFor(element("sceneCaption"), "The scene's words can be typed")
        caption.tap()
        caption.typeText("The end.")
        element("addBubble").tap()
        shot("6 storyboard")
        element("closeStoryboard").tap()
        waitForNumber("scenes", "The story has two scenes") { $0 == 2 }

        // Play the whole story on the TV.
        element("playStory").tap()
        waitFor(element("storyPlayer"), "The story player opens")
        Thread.sleep(forTimeInterval: 1.5)
        shot("7 playing")
        element("closePlayer").tap()
        waitFor(element("pixelCanvas"), "Back in the editor")

        // Export the story as a GIF.
        element("pixelExport").tap()
        waitFor(element("runPixelExport"), "The export sheet opens").tap()
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", ".gif")).firstMatch
        waitFor(done, timeout: 240, "The GIF was made")
        shot("8 exported")
    }
}
