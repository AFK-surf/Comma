import Foundation
import Testing
@testable import CommaCore

/// The desktop menu ranking (`filterAiInputMenuItems` and `itemRank`).
@Suite("Composer menu ranking")
struct ComposerMenuFilterTests {
    private let rows = [
        ComposerMenuCandidate(id: "task:t1", label: "Release notes"),
        ComposerMenuCandidate(id: "pdf", label: "PDF reader", searchText: "pdf", description: "Read and fill PDF forms"),
        ComposerMenuCandidate(id: "salix-status", label: "/status", searchText: "salix-command status",
                              description: "Show model and context usage"),
        ComposerMenuCandidate(id: "frontend-design", label: "Frontend design", searchText: "frontend-design",
                              description: "Build polished interfaces", keywords: ["ui", "notes"]),
    ]

    private func filtered(_ query: String) -> [String] {
        ComposerMenuFilter.filter(rows, query: query, by: { $0 }).map(\.id)
    }

    @Test func emptyQueryKeepsOrder() {
        #expect(filtered("") == rows.map(\.id))
        #expect(filtered("   ") == rows.map(\.id))
    }

    @Test func prefixBeatsContainsBeatsDescription() {
        let candidates = [
            ComposerMenuCandidate(id: "a", label: "Weekly notes", description: "notes"),
            ComposerMenuCandidate(id: "b", label: "Other", description: "Has notes inside"),
            ComposerMenuCandidate(id: "c", label: "Notes digest"),
        ]
        #expect(ComposerMenuFilter.filter(candidates, query: "notes", by: { $0 }).map(\.id) == ["c", "a", "b"])
        #expect(ComposerMenuFilter.rank(candidates[2], query: "notes") == 0)
        #expect(ComposerMenuFilter.rank(candidates[0], query: "notes") == 1)
        #expect(ComposerMenuFilter.rank(candidates[1], query: "notes") == 2)
        #expect(filtered("notes") == ["task:t1", "frontend-design"], "A keyword ranks with descriptions")
    }

    @Test func idAndSearchTextCount() {
        #expect(ComposerMenuFilter.rank(ComposerMenuCandidate(id: "task:abc", label: "Fix login"), query: "task") == 0)
        #expect(filtered("salix") == ["salix-status"])
        #expect(filtered("command") == ["salix-status"])
        #expect(filtered("design") == ["frontend-design"])
    }

    @Test func tiesKeepSourceOrder() {
        let candidates = (0..<12).map { ComposerMenuCandidate(id: "task:\($0)", label: "Task \($0)") }
        #expect(ComposerMenuFilter.filter(candidates, query: "task", by: { $0 }) == candidates)
        #expect(ComposerMenuFilter.filter(candidates, query: "1", by: { $0 }).map(\.id) == ["task:1", "task:10", "task:11"])
    }

    @Test func trimmedCaseInsensitive() {
        #expect(filtered("  PDF ") == ["pdf"])
        #expect(filtered("RELEASE") == ["task:t1"])
    }

    @Test func nonMatchesDropped() {
        #expect(filtered("zzz").isEmpty)
        #expect(ComposerMenuFilter.rank(rows[0], query: "zzz") == nil)
    }
}
