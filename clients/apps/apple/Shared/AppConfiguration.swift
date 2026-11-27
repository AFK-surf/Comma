import Foundation
import CommaCore

struct AppConfiguration {
    let baseURL: URL
    let credentialService: String
    /// Added to the names of the app's local stores (core databases, downloads, notification preferences) while the
    /// app uses a backend other than the one it was built for, so the two backends never share cached data.
    var storageSuffix = ""
    var pushEnvironment: PushEnvironment {
        get throws {
            try Self.pushEnvironment(value: Bundle.main.object(forInfoDictionaryKey: "COMMA_PUSH_ENVIRONMENT") as? String)
        }
    }

    static func pushEnvironment(value: String?) throws -> PushEnvironment {
        switch value {
        case "development", "sandbox": .sandbox
        case "production": .production
        default: throw ConfigurationError.invalidPushEnvironment
        }
    }

    static func current(defaults: UserDefaults = .standard) throws -> AppConfiguration {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "COMMA_API_BASE_URL") as? String,
              let built = URL(string: value), built.scheme == "https", built.host != nil else {
            throw ConfigurationError.invalidBackend
        }
        #if os(iOS)
        _ = try pushEnvironment(value: Bundle.main.object(forInfoDictionaryKey: "COMMA_PUSH_ENVIRONMENT") as? String)
        #endif
        let identifier = Bundle.main.bundleIdentifier ?? "surf.comma.ios"
        #if os(iOS)
        // A choice kept from a TestFlight build does not carry over to an App Store install of the same app.
        let chosen = BackendEnvironment.switchAvailable ? BackendEnvironment.chosen(defaults) : nil
        #else
        // The watch follows the iPhone it pairs with (WatchPairingBridge).
        let chosen = BackendEnvironment.chosen(defaults)
        #endif
        return resolve(built: built, chosen: chosen, credentialService: identifier + ".session")
    }

    /// The backend the app uses: the one chosen in the hidden backend switch, else the one it was built for.
    static func resolve(built: URL, chosen: BackendEnvironment?, credentialService: String) -> AppConfiguration {
        guard let chosen, chosen.url.absoluteString != built.absoluteString else {
            return AppConfiguration(baseURL: built, credentialService: credentialService)
        }
        return AppConfiguration(baseURL: chosen.url, credentialService: credentialService,
                                storageSuffix: "-" + chosen.rawValue)
    }

    /// The known backend this configuration uses, if it is one.
    var environment: BackendEnvironment? { BackendEnvironment(url: baseURL) }

    func makeClient() throws -> CommaClient {
        #if os(watchOS)
        let platform: ApplePlatform = .watchos
        #else
        let platform: ApplePlatform = .ios
        #endif
        return try CommaClient(baseURL: baseURL, platform: platform, keychainService: credentialService)
    }

    enum ConfigurationError: LocalizedError {
        case invalidBackend, invalidPushEnvironment
        var errorDescription: String? { "The app could not connect to its configured service." }
    }
}

/**
 * The backends a TestFlight or development build can switch between in Settings (tap Version seven times). Only
 * these two are allowed, so the switch cannot send a session to any other server. Each backend keeps its own
 * session: the credential store is keyed by the API origin.
 */
enum BackendEnvironment: String, CaseIterable, Sendable {
    case production, staging

    static let key = "comma.backend-environment"

    var url: URL {
        switch self {
        case .production: URL(string: "https://salix.comma.surf")!
        case .staging: URL(string: "https://salix-staging.comma.surf")!
        }
    }

    var name: String {
        switch self {
        case .production: "Production"
        case .staging: "Staging"
        }
    }

    init?(url: URL) {
        guard let match = Self.allCases.first(where: { $0.url.host == url.host && url.scheme == "https" }) else { return nil }
        self = match
    }

    static func chosen(_ defaults: UserDefaults) -> BackendEnvironment? {
        defaults.string(forKey: key).flatMap(BackendEnvironment.init(rawValue:))
    }

    static func choose(_ value: BackendEnvironment, defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// Development builds and TestFlight builds offer the switch. An App Store build does not.
    static var switchAvailable: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}
