import Foundation
import Testing
@testable import CommaCore

extension CommaClientTests {
    @Test func unavailablePushCannotAppearSuccessfullyRegistered() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"push_unavailable\"}", status: 503)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do {
            _ = try await client.registerLiveActivityToken("update-token", environment: .sandbox, workspace: workspace, activityID: "activity1")
            Issue.record("Unconfigured push appeared active")
        } catch { #expect(error as? CommaError == .http(status: 503, code: "push_unavailable", retryAfter: nil)) }
        #expect(await client.session?.id == "s1")
    }

    @Test func ordinaryDeviceDeleteIsAuthenticatedIdempotentAndRequires204() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let transport = FixtureTransport([response(sessionJSON), response("", status: 204), response("", status: 204), response("{}", status: 200)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        try await client.unregisterDeviceNotifications()
        try await client.unregisterDeviceNotifications()
        do { try await client.unregisterDeviceNotifications(); Issue.record("200 is not deletion confirmation") }
        catch { #expect(error as? CommaError == .invalidResponse) }
        let requests = await transport.requests().dropFirst()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy {
            $0.httpMethod == "DELETE" && $0.url?.path == "/v1/comma/notifications/devices" &&
            $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer"
        })
    }

    @Test func pushKindsCarryMainIdentityAndAggregateActivitySchema() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let registration = response("{\"id\":\"r1\",\"status\":\"active\"}")
        let transport = FixtureTransport([response(sessionJSON), registration, registration, registration])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        _ = try await client.registerDeviceToken("test-only-device", environment: .production, workspace: workspace, bundleID: "test.main.phone", locale: "zh-Hans")
        _ = try await client.registerPushToStartToken("test-only-start", environment: .production, workspace: workspace, bundleID: "test.main.phone", locale: "zh-Hans")
        _ = try await client.registerLiveActivityToken("test-only-activity", environment: .production, workspace: workspace, activityID: "activity", bundleID: "test.main.phone", locale: "zh-Hans")
        let requests = await transport.requests().dropFirst()
        for request in requests {
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            #expect(body["bundle_id"] == .string("test.main.phone"))
            #expect(body["locale"] == .string("zh-Hans"))
            #expect(body["environment"] == .string("production"))
            #expect(body["group_id"] == .string("g1"))
        }
        let activity = try JSONDecoder().decode([String: JSONValue].self, from: requests.last!.httpBody!)
        #expect(activity["activity_schema"] == .string("tasks_v1"))
        let start = try JSONDecoder().decode([String: JSONValue].self, from: requests[requests.startIndex + 1].httpBody!)
        #expect(start["activity_schema"] == .string("tasks_v1"))
        #expect(activity["activity_id"] == .string("activity"))
    }

    @Test func delayedOrdinaryMutationCanBeRetiredWithItsCapturedSessionAfterLocalAuthorityChanges() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let transport = FixtureTransport([response(sessionJSON), response("", status: 204)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        let channel = try await client.deviceNotificationChannel()
        await transport.delay(path: "/v1/comma/notifications/devices")
        let pending = Task { try await channel.register(token: "test-only-device", environment: .sandbox, workspace: workspace, bundleID: "test.main.phone", locale: "en-US") }
        await transport.waitForRequests(2)
        try await client.clearLocalSession()
        await transport.resume(response("{\"id\":\"old-slot\",\"status\":\"active\"}"))
        _ = try await pending.value
        await transport.delay(path: "/unused")
        try await channel.retire()
        #expect(await client.session == nil)
        let deletion = await transport.requests().last!
        #expect(deletion.httpMethod == "DELETE")
        #expect(deletion.url?.path == "/v1/comma/notifications/devices")
        #expect(deletion.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer")
        do {
            _ = try await channel.register(token: "test-only-device", environment: .sandbox, workspace: workspace, bundleID: "test.main.phone", locale: "en-US")
            Issue.record("An old channel initiated a new registration")
        } catch { #expect(error as? CommaError == .staleSession) }
        #expect(await transport.requests().count == 3)
    }
}
