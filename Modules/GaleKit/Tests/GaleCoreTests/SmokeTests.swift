import XCTest
@testable import GaleCore
final class CoreSmokeTests: XCTestCase { func testVersion() { XCTAssertEqual(GaleCoreInfo.version, 1) } }
