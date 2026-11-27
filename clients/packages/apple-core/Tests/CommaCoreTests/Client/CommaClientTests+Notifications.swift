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

    @Test func liveStatusEndpointsUseV1SchemaAndDecodeSnakeCaseItems() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let regStartID = "11111111-1111-1111-1111-111111111111"
        let regTokenID = "22222222-2222-2222-2222-222222222222"
        let listJSON = """
        {
          "data": [
            {
              "key": "flight:CA1501",
              "workspace_id": "w1",
              "group_id": "g1",
              "conversation_id": "c1",
              "category": "flight",
              "status": "attention",
              "accent": "blue",
              "title": "CA1501 首都 → 虹桥",
              "subtitle": "正在登机 · T3 登机口 B12",
              "compact_label": "B12",
              "eta_epoch_seconds": 1800001680,
              "progress": 0.4,
              "step_current": 2,
              "step_total": 4,
              "step_label": "登机中",
              "detail_left": "预计 14:30 起飞",
              "detail_right": "登机口 B12",
              "stale_epoch_seconds": 1800003000,
              "expires_epoch_seconds": 1800010000,
              "started_at_epoch_seconds": 1799999000,
              "dismiss_at_epoch_seconds": 1800004000,
              "updated_at_epoch_seconds": 1800000000
            },
            {
              "key": "timer:pomodoro",
              "workspace_id": "w1",
              "group_id": "g1",
              "category": "timer",
              "status": "active",
              "accent": "auto",
              "title": "Focus",
              "started_at_epoch_seconds": null,
              "updated_at_epoch_seconds": 1800000050
            }
          ]
        }
        """
        let transport = FixtureTransport([
            response(sessionJSON),
            response("{\"id\":\"\(regStartID)\",\"status\":\"active\"}"),
            response("{\"id\":\"\(regTokenID)\",\"status\":\"active\"}"),
            response(listJSON),
            response("", status: 204),
        ])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        let channel = try await client.liveStatusNotificationChannel(workspace: workspace, environment: .production,
                                                                     bundleID: "surf.comma.ios", locale: "zh-Hans")
        let start = try await channel.register(token: "pts-token", activityID: nil, liveKey: nil, registrationID: regStartID)
        #expect(start.id == regStartID)
        let perKey = try await channel.register(token: "key-token", activityID: "act-1", liveKey: "flight:CA1501", registrationID: regTokenID)
        #expect(perKey.id == regTokenID)
        let snapshot = try await client.liveStatuses(workspace: workspace)
        #expect(snapshot.data.count == 2)
        #expect(snapshot.data[0].key == "flight:CA1501")
        #expect(snapshot.data[0].compactLabel == "B12")
        #expect(snapshot.data[0].stepCurrent == 2)
        #expect(snapshot.data[0].stepTotal == 4)
        #expect(snapshot.data[0].startedAtEpochSeconds == 1_799_999_000)
        #expect(snapshot.data[0].dismissAtEpochSeconds == 1_800_004_000)
        #expect(snapshot.data[1].key == "timer:pomodoro")
        #expect(snapshot.data[1].startedAtEpochSeconds == nil)
        #expect(snapshot.data[1].dismissAtEpochSeconds == nil)
        try await channel.retire(id: regTokenID, reason: .dismissed)

        let requests = Array(await transport.requests().dropFirst())
        #expect(requests.count == 4)
        #expect(requests[0].url?.path == "/v1/comma/notifications/live-statuses/push-to-start")
        #expect(requests[1].url?.path == "/v1/comma/notifications/live-statuses/tokens")
        #expect(requests[2].url?.path == "/v1/comma/groups/g1/live-activities")
        #expect(requests[3].httpMethod == "DELETE")
        #expect(requests[3].url?.path == "/v1/comma/notifications/live-statuses/registrations/\(regTokenID)")
        #expect(requests[3].url?.query == "reason=dismissed")
        let tokenBody = try JSONDecoder().decode([String: JSONValue].self, from: requests[1].httpBody!)
        #expect(tokenBody["activity_schema"] == .string("live_status_v1"))
        #expect(tokenBody["live_key"] == .string("flight:CA1501"))
        #expect(tokenBody["activity_id"] == .string("act-1"))
    }
}
