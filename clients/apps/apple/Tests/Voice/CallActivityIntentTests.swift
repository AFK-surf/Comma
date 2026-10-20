import AppIntents
import XCTest
@testable import Comma

@MainActor
final class CallActivityIntentTests: XCTestCase {
    func testMuteIntentWaitsForActivityUpdateBeforeCompleting() async throws {
        let previous = ToggleCallMuteIntent.toggleMute
        defer { ToggleCallMuteIntent.toggleMute = previous }
        let updateStarted = expectation(description: "Live Activity update started")
        var pendingUpdate: CheckedContinuation<Void, Never>?
        var completed = false
        ToggleCallMuteIntent.toggleMute = {
            await withCheckedContinuation {
                pendingUpdate = $0
                updateStarted.fulfill()
            }
        }

        let action = Task {
            _ = try await ToggleCallMuteIntent().perform()
            completed = true
        }
        await fulfillment(of: [updateStarted], timeout: 2)
        XCTAssertFalse(completed, "The optimistic Toggle must wait for the authoritative update before reconciling.")
        pendingUpdate?.resume()
        try await action.value
        XCTAssertTrue(completed)
    }
}
