import XCTest
@testable import GaleSync
final class SyncSmokeTests: XCTestCase { func testVersion() { XCTAssertEqual(GaleSyncInfo.protocolVersion, 1) } }
