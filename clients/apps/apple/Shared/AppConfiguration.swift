import Foundation
import CommaCore

struct AppConfiguration {
    let baseURL: URL
    let credentialService: String
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

    static func current() throws -> AppConfiguration {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "COMMA_API_BASE_URL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else {
            throw ConfigurationError.invalidBackend
        }
        #if os(iOS)
        _ = try pushEnvironment(value: Bundle.main.object(forInfoDictionaryKey: "COMMA_PUSH_ENVIRONMENT") as? String)
        #endif
        let identifier = Bundle.main.bundleIdentifier ?? "surf.comma.ios"
        return AppConfiguration(baseURL: url, credentialService: identifier + ".session")
    }

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
