import Foundation
import XCTest
@testable import Comma

/// Real PNG outputs from the template's local browser capture, served as the core's `miniAppImage` topic: the icon
/// for an `/icon` URL, the cover image for a cover or screenshot URL.
enum MiniAppMediaFixture {
    static func serve(_ core: FakeCore) throws {
        let bundle = Bundle(for: MiniAppsManagementTests.self)
        func image(_ file: String) throws -> String {
            let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: "png"))
            return "data:image/png;base64," + (try Data(contentsOf: url)).base64EncodedString()
        }
        let icon = try image("mini-app-icon"), cover = try image("mini-app-cover")
        core.serve("miniAppImage") { topic in
            let url = topic["url"] as? String ?? ""
            return ["status": "ready", "src": url.contains("/icon?") ? icon : cover]
        }
    }
}
