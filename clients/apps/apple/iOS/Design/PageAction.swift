import SwiftUI

/// One change at a time on a page or sheet: `busy` while it runs, so the page can hold still, and its failure
/// as the message an `InlineError` shows. Starting another change while one runs does nothing.
@MainActor @Observable
final class PageAction {
    private(set) var busy = false
    var error: String?

    /// Runs `operation`, then hands its result to `done`; a failure in either becomes `error`.
    func run<Value>(_ operation: @escaping () async throws -> Value,
                    then done: @escaping (Value) async throws -> Void = { _ in }) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await done(try await operation())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
