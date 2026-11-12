import Foundation
import XCTest
@testable import Comma

final class CommaDeviceRowTests: XCTestCase {
    private func row(_ fields: [String: Any]) throws -> CommaDeviceRow {
        try XCTUnwrap(CommaDeviceRow(NSDictionary(dictionary: ["device_id": "dev", "name": "PC"].merging(fields) { $1 })))
    }

    func testViewScreenForAnOnlineComputerWhoseStationServesItOverTheMesh() throws {
        XCTAssertTrue(try row(["status": "connected", "screen_view": true]).showsScreen)
        XCTAssertFalse(try row(["status": "disconnected", "screen_view": true]).showsScreen)
        // A station from before the mesh's screens, or one that says nothing.
        XCTAssertFalse(try row(["status": "connected"]).showsScreen)
    }
}
