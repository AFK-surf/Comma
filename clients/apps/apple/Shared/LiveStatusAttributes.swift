#if os(iOS)
import ActivityKit
import CommaCore
import Foundation

/// Generalized Dynamic Island & Lock Screen Live Activity attributes (`live_status_v1`).
/// Matches APNs `attributes-type: "LiveStatusAttributes"`.
struct LiveStatusAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var category: String
        var status: String
        var accent: String
        var title: String
        var subtitle: String?
        var compactLabel: String?
        var etaEpochSeconds: Int?
        var progress: Double?
        var stepCurrent: Int?
        var stepTotal: Int?
        var stepLabel: String?
        var detailLeft: String?
        var detailRight: String?
        var updatedAtEpochSeconds: Int

        init(category: String, status: String, accent: String = "auto", title: String,
             subtitle: String? = nil, compactLabel: String? = nil, etaEpochSeconds: Int? = nil,
             progress: Double? = nil, stepCurrent: Int? = nil, stepTotal: Int? = nil,
             stepLabel: String? = nil, detailLeft: String? = nil, detailRight: String? = nil,
             updatedAtEpochSeconds: Int) {
            self.category = category
            self.status = status
            self.accent = accent
            self.title = title
            self.subtitle = subtitle
            self.compactLabel = compactLabel
            self.etaEpochSeconds = etaEpochSeconds
            self.progress = progress
            self.stepCurrent = stepCurrent
            self.stepTotal = stepTotal
            self.stepLabel = stepLabel
            self.detailLeft = detailLeft
            self.detailRight = detailRight
            self.updatedAtEpochSeconds = updatedAtEpochSeconds
        }

        init(item: LiveStatusItem) {
            self.init(
                category: item.category,
                status: item.status,
                accent: item.accent,
                title: item.title,
                subtitle: item.subtitle,
                compactLabel: item.compactLabel,
                etaEpochSeconds: item.etaEpochSeconds,
                progress: item.progress,
                stepCurrent: item.stepCurrent,
                stepTotal: item.stepTotal,
                stepLabel: item.stepLabel,
                detailLeft: item.detailLeft,
                detailRight: item.detailRight,
                updatedAtEpochSeconds: item.updatedAtEpochSeconds
            )
        }

        enum CodingKeys: String, CodingKey {
            case category, status, accent, title, subtitle, compactLabel
            case etaEpochSeconds, progress, stepCurrent, stepTotal, stepLabel
            case detailLeft, detailRight, updatedAtEpochSeconds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? "progress"
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
            accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "auto"
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            compactLabel = try c.decodeIfPresent(String.self, forKey: .compactLabel)
            etaEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .etaEpochSeconds)
            progress = try c.decodeIfPresent(Double.self, forKey: .progress)
            stepCurrent = try c.decodeIfPresent(Int.self, forKey: .stepCurrent)
            stepTotal = try c.decodeIfPresent(Int.self, forKey: .stepTotal)
            stepLabel = try c.decodeIfPresent(String.self, forKey: .stepLabel)
            detailLeft = try c.decodeIfPresent(String.self, forKey: .detailLeft)
            detailRight = try c.decodeIfPresent(String.self, forKey: .detailRight)
            updatedAtEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .updatedAtEpochSeconds) ?? 0
        }

        var isTerminal: Bool {
            status == "done" || status == "cancelled" || status == "failed"
        }

        var needsAttention: Bool {
            status == "attention"
        }

        var etaDate: Date? {
            etaEpochSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        var clampedProgress: Double? {
            progress.map { min(max($0, 0), 1) }
        }

        var hasSegmentedSteps: Bool {
            guard let total = stepTotal, (2...8).contains(total), stepCurrent != nil else { return false }
            return true
        }

        var hasProgressIndicator: Bool {
            hasSegmentedSteps || clampedProgress != nil
        }

        var hasFooterDetails: Bool {
            !(detailLeft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(detailRight?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        /// Priority score (`0...95`, strictly below live voice call's `100.0`) matching backend APNs `relevance-score`.
        func relevanceScore(now: Date = Date()) -> Double {
            if isTerminal { return 10.0 }
            let remaining = etaDate.map { $0.timeIntervalSince(now) }
            if needsAttention {
                if let remaining, remaining > 0 {
                    let bonus = 5.0 * max(0.0, 1.0 - min(remaining, 3600.0) / 3600.0)
                    return ((90.0 + bonus) * 10.0).rounded() / 10.0
                }
                return 90.0
            }
            if let remaining, remaining > 0 {
                let score = 45.0 + 40.0 * max(0.0, 1.0 - min(remaining, 7200.0) / 7200.0)
                return (score * 10.0).rounded() / 10.0
            }
            return 40.0
        }
    }

    let accountID: String
    let workspaceID: String
    let groupID: String
    let liveKey: String
    let conversationID: String?
    let startedAtEpochSeconds: Int?

    init(accountID: String, workspaceID: String, groupID: String, liveKey: String,
         conversationID: String? = nil, startedAtEpochSeconds: Int? = nil) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.groupID = groupID
        self.liveKey = liveKey
        self.conversationID = conversationID
        self.startedAtEpochSeconds = startedAtEpochSeconds
    }

    var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "comma"
        components.host = "live-activity"
        var items = [
            URLQueryItem(name: "workspace", value: workspaceID),
            URLQueryItem(name: "group", value: groupID),
            URLQueryItem(name: "key", value: liveKey),
        ]
        if let conversationID, !conversationID.isEmpty {
            items.append(URLQueryItem(name: "conversation", value: conversationID))
        }
        components.queryItems = items
        return components.url
    }
}

struct LiveStatusDeepLink: Equatable, Sendable {
    let workspaceID: String
    let groupID: String
    let liveKey: String
    let conversationID: String?

    static func parse(url: URL) -> LiveStatusDeepLink? {
        guard let scheme = url.scheme, ["comma", "comma-ios-dev"].contains(scheme),
              url.host == "live-activity",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        func value(_ name: String) -> String? {
            guard let raw = queryItems.first(where: { $0.name == name })?.value,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return raw
        }
        guard let workspaceID = value("workspace"),
              let groupID = value("group"),
              let liveKey = value("key") else {
            return nil
        }
        return LiveStatusDeepLink(
            workspaceID: workspaceID,
            groupID: groupID,
            liveKey: liveKey,
            conversationID: value("conversation")
        )
    }
}

/// Tracks user-dismissed Live Status instances by `(liveKey -> startedAtEpochSeconds)`.
/// A restarted server instance with `startedAt > dismissedAt` automatically clears suppression.
struct LiveStatusDismissalTracker: Equatable, Sendable {
    private(set) var instances: [String: Int]

    init(instances: [String: Int] = [:]) {
        self.instances = instances
    }

    mutating func recordDismissal(liveKey: String, startedAt: Int?, nowEpochSeconds: Int) {
        instances[liveKey] = startedAt ?? nowEpochSeconds
    }

    /// Returns `true` when `(liveKey, startedAt)` should be suppressed.
    /// If `startedAt > dismissedAt`, clears the stale suppression entry and returns `false`.
    mutating func shouldSuppress(liveKey: String, startedAt: Int?) -> Bool {
        guard let dismissedAt = instances[liveKey] else { return false }
        if let startedAt, startedAt > dismissedAt {
            instances.removeValue(forKey: liveKey)
            return false
        }
        return true
    }

    /// Removes suppression entries that are no longer active on the server or have been superseded
    /// by a newer instance (`startedAt > dismissedAt`).
    mutating func prune(activeStartedAtByKey: [String: Int?]) {
        instances = instances.filter { key, dismissedAt in
            guard let activeStartedAt = activeStartedAtByKey[key] else { return false }
            if let startedAt = activeStartedAt, startedAt > dismissedAt {
                return false
            }
            return true
        }
    }

    mutating func removeAll() {
        instances.removeAll()
    }
}
#endif
