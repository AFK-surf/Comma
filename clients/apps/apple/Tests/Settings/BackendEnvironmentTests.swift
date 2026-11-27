@testable import Comma
import XCTest

final class BackendEnvironmentTests: XCTestCase {
    private let production = URL(string: "https://salix.comma.surf")!
    private let staging = URL(string: "https://salix-staging.comma.surf")!

    func testTheBuiltBackendIsUsedUntilAnotherIsChosen() {
        let configuration = AppConfiguration.resolve(built: production, chosen: nil, credentialService: "test")
        XCTAssertEqual(configuration.baseURL, production)
        XCTAssertEqual(configuration.storageSuffix, "")
    }

    func testTheOtherBackendKeepsItsLocalStoresApart() {
        let configuration = AppConfiguration.resolve(built: production, chosen: .staging, credentialService: "test")
        XCTAssertEqual(configuration.baseURL, staging)
        XCTAssertEqual(configuration.storageSuffix, "-staging")
        XCTAssertEqual(configuration.environment, .staging)
    }

    func testChoosingTheBuiltBackendUsesItsOriginalStores() {
        let configuration = AppConfiguration.resolve(built: staging, chosen: .staging, credentialService: "test")
        XCTAssertEqual(configuration.baseURL, staging)
        XCTAssertEqual(configuration.storageSuffix, "")
    }

    func testOnlyTheTwoKnownBackendsCanBeChosen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BackendEnvironmentTests"))
        defer { defaults.removePersistentDomain(forName: "BackendEnvironmentTests") }
        defaults.set("https://example.com", forKey: BackendEnvironment.key)
        XCTAssertNil(BackendEnvironment.chosen(defaults))
        XCTAssertNil(BackendEnvironment(url: URL(string: "https://example.com")!))
        XCTAssertNil(BackendEnvironment(url: URL(string: "http://salix-staging.comma.surf")!))
        BackendEnvironment.choose(.staging, defaults: defaults)
        XCTAssertEqual(BackendEnvironment.chosen(defaults), .staging)
    }

    @MainActor
    func testChoosingAnotherBackendRetiresBeforeSwitchingAndUnregistersDevice() async throws {
        defer { UserDefaults.standard.removeObject(forKey: BackendEnvironment.key) }
        let harness = try StoreHarness()
        await harness.start()
        var ranBeforeSwitch = false
        harness.store.beforeBackendSwitch = {
            XCTAssertTrue(harness.core.calls("notifications.unregisterDevice").isEmpty)
            ranBeforeSwitch = true
        }
        harness.core.on("notifications.unregisterDevice") { _ in NSNull() }
        await harness.store.chooseBackend(.staging)
        XCTAssertTrue(ranBeforeSwitch)
        XCTAssertEqual(harness.core.calls("notifications.unregisterDevice").count, 1)
        XCTAssertEqual(BackendEnvironment.chosen(.standard), .staging)
    }
}
