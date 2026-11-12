import Foundation
import Observation

/// One public Mini App Link. The token is sent only to the Core, never to the frame or telemetry.
struct MiniAppSharedLink: Equatable, Identifiable, Sendable {
    let token: String
    var id: String { token }

    init?(url: URL, apiOrigin: URL) {
        guard let expected = Self.webHost(apiOrigin: apiOrigin), url.host == expected,
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.split(separator: "/"),
              parts.count == 2, parts[0] == "a", Self.validToken(String(parts[1])),
              url.path == "/a/" + String(parts[1]) || url.path == "/a/" + String(parts[1]) + "/" else { return nil }
        self.token = String(parts[1])
    }

    static func webHost(apiOrigin: URL) -> String? {
        guard apiOrigin.scheme == "https", apiOrigin.port == nil else { return nil }
        switch apiOrigin.host {
        case "salix.comma.surf": return "app.comma.surf"
        case "salix-staging.comma.surf": return "app-staging.comma.surf"
        default: return nil
        }
    }

    static func validToken(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { byte in
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || byte == 45 || byte == 95
        }
    }

    /// Recognize claimed paths even when invalid, so an AASA handoff gets a bounded error instead of opening another environment.
    static func isClaimed(_ url: URL) -> Bool {
        url.scheme == "https" && ["app.comma.surf", "app-staging.comma.surf"].contains(url.host ?? "") && url.path.hasPrefix("/a/")
    }
}

enum MiniAppPresentation: Identifiable {
    case details(MiniAppTarget)
    case run(MiniAppTarget)
    case shared(MiniAppSharedLink)
    var id: String {
        switch self {
        case .details(let target): "details:" + target.id
        case .run(let target): "run:" + target.id
        case .shared(let link): "shared:" + link.id
        }
    }
}

/// One in-memory handoff. An anonymous link may continue after sign-in. A link received by an account stays with it.
@MainActor @Observable
final class IncomingAppLink {
    private(set) var url: URL?
    private var accountID: String?

    func receive(_ url: URL, accountID: String?) { self.url = url; self.accountID = accountID }
    func clear() { url = nil; accountID = nil }

    func identityChanged(from previous: String?, to current: String?) {
        if (previous != nil && previous != current) || (accountID != nil && accountID != current) { clear() }
    }

    func take(accountID current: String?, hasWorkspace: Bool) -> URL? {
        guard let url, let current, accountID == nil || accountID == current,
              hasWorkspace || MiniAppSharedLink.isClaimed(url) else { return nil }
        clear()
        return url
    }
}
