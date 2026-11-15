import XCTest
@testable import GaleCore
@testable import GaleFormat
final class PlaceholderCoreTests: XCTestCase { func testOnion() { XCTAssertEqual(OnionSkin.ghosts(current: 0, frameCount: 1, settings: OnionSettings()).count, 0) } }
