import StoreKit
import UIKit

/**
 * When Comma asks for an App Store rating. It counts the results the member accepts (Mark as done, or ending a Task
 * as Done) and asks at the third. After a request it waits 120 days, so a request never spends one of the three
 * sheets Apple shows in 365 days on a member who saw one lately. Apple decides whether the sheet shows, and a
 * TestFlight build never shows it. The count and the last request are this iPhone's, whichever account is signed in.
 */
@MainActor
final class ReviewPrompt {
    /// Accepted results a request needs.
    static let acceptedNeeded = 3
    /// The least time between two requests.
    static let interval: TimeInterval = 120 * 24 * 60 * 60

    private static let acceptedKey = "comma.review-prompt.accepted"
    private static let askedKey = "comma.review-prompt.asked-at"

    private let preferences: UserDefaults
    private let now: () -> Date
    private let settle: Duration
    private let request: @MainActor () -> Bool

    /// `settle` lets the menu or swipe that accepted the result close before the sheet. `request` asks, and answers
    /// whether a scene could take it.
    init(preferences: UserDefaults = .standard, now: @escaping () -> Date = Date.init, settle: Duration = .seconds(2),
         request: @escaping @MainActor () -> Bool = ReviewPrompt.requestInActiveScene) {
        self.preferences = preferences
        self.now = now
        self.settle = settle
        self.request = request
    }

    /// The member accepted a Task's result. A request no scene could take stays due for the next one.
    func workAccepted() async {
        preferences.set(preferences.integer(forKey: Self.acceptedKey) + 1, forKey: Self.acceptedKey)
        guard due else { return }
        try? await Task.sleep(for: settle)
        guard due, request() else { return }
        preferences.set(0, forKey: Self.acceptedKey)
        preferences.set(now(), forKey: Self.askedKey)
    }

    private var due: Bool {
        guard preferences.integer(forKey: Self.acceptedKey) >= Self.acceptedNeeded else { return false }
        guard let asked = preferences.object(forKey: Self.askedKey) as? Date else { return true }
        return now().timeIntervalSince(asked) >= Self.interval
    }

    /// Asks in the scene the member is looking at; false when the app left the foreground.
    static func requestInActiveScene() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else { return false }
        AppStore.requestReview(in: scene)
        return true
    }
}
