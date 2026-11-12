import Foundation
import XCTest
@testable import Comma

final class AbuseProofTests: XCTestCase {
    func testSharedDigestVector() {
        XCTAssertEqual(AbuseProof.digest("comma-abuse:abuse_test_abc:def-123_").map { String(format: "%02x", $0) }.joined(),
                       "00d5c5a1c3e4510fcb5fb2b243148245a8a87986242d57fddf2cea0ad0d47d05")
    }

    func testReusableKeyIsScopedToBackendTargetAndEnvironmentAndSurvivesFailure() async throws {
        let provider = FixtureAppAttest()
        let records = FixtureAttestRecords()
        let proof = AbuseProof(service: provider, records: records)
        var challenge: [String: Any] = ["id": "abuse_test_abc", "secret": "def-123_", "email": "a@example.test", "apple_environment": "production"]
        provider.fail = true
        do { _ = try await proof.request(challenge, audience: "https://api.test"); XCTFail("Expected attestation failure") } catch {}
        provider.fail = false
        let first = try await proof.request(challenge, audience: "https://api.test")
        XCTAssertNotNil((first["apple"] as? [String: Any])?["attestation"])
        let second = try await proof.request(challenge, audience: "https://api.test")
        XCTAssertNotNil((second["apple"] as? [String: Any])?["assertion"])
        XCTAssertEqual(provider.generated, 1)
        provider.fail = true
        do { _ = try await proof.request(challenge, audience: "https://api.test"); XCTFail("Expected provider failure") } catch {}
        provider.fail = false
        _ = try await proof.request(challenge, audience: "https://api.test")
        XCTAssertEqual(provider.generated, 1)
        challenge["email"] = "b@example.test"
        _ = try await proof.request(challenge, audience: "https://api.test")
        challenge["apple_environment"] = "development"
        _ = try await proof.request(challenge, audience: "https://api.test")
        _ = try await proof.request(challenge, audience: "https://other.test")
        XCTAssertEqual(provider.generated, 4)
        XCTAssertEqual(provider.hash, AbuseProof.digest("comma-abuse:abuse_test_abc:def-123_"))
    }
}

private final class FixtureAppAttest: AppAttestProvider, @unchecked Sendable {
    let supported = true
    var generated = 0
    var fail = false
    var hash: Data?
    func generateKey() async throws -> String { generated += 1; return "fixture-key-\(generated)" }
    func attest(_ key: String, hash: Data) async throws -> Data {
        self.hash = hash
        if fail { throw HostFailure(message: "scripted failure") }
        return Data("fixture-attestation".utf8)
    }
    func assert(_ key: String, hash: Data) async throws -> Data {
        self.hash = hash
        if fail { throw HostFailure(message: "scripted failure") }
        return Data("fixture-assertion".utf8)
    }
}

private final class FixtureAttestRecords: AppAttestRecords, @unchecked Sendable {
    private var values: [String: [String: Any]] = [:]
    func read(_ account: String) -> [String: Any]? { values[account] }
    func write(_ account: String, _ record: [String: Any]) { values[account] = record }
}
