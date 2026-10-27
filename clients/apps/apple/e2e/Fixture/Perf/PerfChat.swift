import Foundation

/// `--perf-long-chat`: a router transcript shaped like a long real one. 150 messages, oldest first: every seventh
/// is the member's (about 15%, each with its client_request_id), the rest are replies in Markdown (paragraphs with
/// inline styles, bullet and numbered lists, fenced code). The newest reply references running Tasks 0 and 1 and
/// the one two before it Tasks 2 and 3, so the transcript's tail shows four live Task cards. Every message starts
/// with "Note <index>." so a test can find it.
enum PerfChat {
    static let count = 150
    /// The member's newest message, which the `--perf-stream` reply answers.
    static let replySource = "message143"

    static func messages() -> [String] {
        (0..<count).map { index in
            let user = isUser(index)
            var object: [String: Any] = [
                "message_id": "message\(index)", "kind": "message", "actor_type": user ? "user" : "agent",
                "created_at": 1_700_000_000 + index * 90,
                "content": [["type": "text", "text": user ? question(index) : reply(index)]] + references(index),
            ]
            // The client core pages history by seq: with it, the messages before a read are left to read later.
            if PerfOptions().holdEarlier { object["seq"] = index + 1 }
            if user {
                object["client_request_id"] = "request-\(index)"
                object["user_id"] = "u"
            } else if index > 0, isUser(index - 1) {
                object["reply_to_message_id"] = "message\(index - 1)"
            }
            return json(object)
        }
    }

    /// The reply `--perf-stream` drafts: about 4 KB of Markdown ending in "The streamed reply ends here."
    static let streamedReply: String = {
        var text = "Note 150. Here is the rollout plan for the **launch checklist**, step by step.\n\n"
        var section = 1
        while text.utf8.count < 3_900 {
            text += """
            ## Stage \(section)

            Freeze the branch for stage \(section) and tag `v2.\(section).0-rc1` once the *regression suite* is green.

            1. Run the iOS, macOS and web suites against the release candidate.
            2. Post the build to the beta group and collect crash reports for a day.
            3. Compare startup time and memory with the previous release.

            ```swift
            func promote(stage: Int) async throws {
                try await pipeline.verify(stage: \(section))
                try await pipeline.publish(channel: .beta)
            }
            ```


            """
            section += 1
        }
        return text + "The streamed reply ends here."
    }()

    /// The committed form of `streamedReply`, which the router chat holds once the draft completes.
    static func streamedMessage() -> String {
        var object: [String: Any] = [
            "message_id": "message150", "kind": "message", "actor_type": "agent",
            "created_at": 1_700_000_000 + count * 90, "reply_to_message_id": replySource,
            "content": [["type": "text", "text": streamedReply]],
        ]
        if PerfOptions().holdEarlier { object["seq"] = count + 1 }
        return json(object)
    }

    /// `--perf-varied-chat`: 600 messages, oldest first, each with its seq (its index + 1), which the client core orders
    /// by. They come in runs of twelve that are all one line, all short paragraphs or all long reports, so the
    /// transcript's rows range from one line to several screens, as a long real Home conversation's do. The newest
    /// reply answers the member's message248, far above the newest rows, and references Task 0.
    static let variedCount = 600
    static let variedTarget = "message248"

    static func varied() -> [String] {
        (0..<variedCount).map { index in
            let user = isUser(index)
            let newest = index == variedCount - 1
            var object: [String: Any] = [
                "message_id": "message\(index)", "kind": "message", "actor_type": user ? "user" : "agent",
                "seq": index + 1, "created_at": 1_700_000_000 + index * 90,
                "content": [["type": "text", "text": user ? question(index) : variedReply(index)]]
                    + (newest ? [["type": "conversation_ref", "conversation_id": "task0", "title": "Task 0"]] : []),
            ]
            if user {
                object["client_request_id"] = "request-\(index)"
                object["user_id"] = "u"
            } else if newest {
                object["reply_to_message_id"] = variedTarget
                object["thread_root_message_id"] = variedTarget
            } else if index == 400 {
                // Another thread between the newest reply and the message it answers: the reply quotes it.
                object["thread_root_message_id"] = "message395"
            } else if isUser(index - 1) {
                object["reply_to_message_id"] = "message\(index - 1)"
            }
            return json(object)
        }
    }

    private static func variedReply(_ index: Int) -> String {
        let lead = "Note \(index). "
        switch index / 12 % 5 {
        case 0, 4:
            return lead + "Done."
        case 2:
            return lead + reply(index)
        default:
            // A long report: a dozen sections of a heading, a paragraph and a list, about two screens tall.
            return lead + "Here is the full report.\n\n" + (1...(6 + index % 7)).map { section in
                """
                ## Section \(section)

                The **\(section)** part of the review covers the open items, the owners and the dates agreed in the thread.

                - The beta build passed every check.
                - Two crash reports mention the photo picker.
                - The web client still needs the new copy.
                """
            }.joined(separator: "\n\n")
        }
    }

    private static func isUser(_ index: Int) -> Bool { index % 7 == 3 }

    private static func question(_ index: Int) -> String {
        let asks = ["Can you check where the launch checklist stands?", "What changed in the onboarding emails since Friday?",
                    "Summarize the support tickets about sign-in.", "Which vendor quote is cheapest over three years?"]
        return "Note \(index). " + asks[index % asks.count]
    }

    private static func reply(_ index: Int) -> String {
        let lead = "Note \(index). "
        switch index % 4 {
        case 0:
            return lead + "I went through the **latest updates** and the *open questions* from the thread. The `release` branch is ready, and the [tracking doc](https://example.com/plan/\(index)) has the details.\n\nTwo items still need an owner before Thursday; I flagged both in the planning channel."
        case 1:
            return lead + "Here is what I found:\n\n- The beta build passed every check on iOS and macOS.\n- Two crash reports mention the photo picker on iOS 18.\n- Sign-in latency is down **18%** since the last release.\n- The web client still needs the new **empty state** copy."
        case 2:
            return lead + "Follow these steps to reproduce it:\n\n1. Open a Task with more than **50** messages.\n2. Scroll to the top and pull to load earlier history.\n3. Send a reply while the history loads.\n\n```swift\nlet page = try await client.messageHistory(target: target, before: oldest)\nstate.prependHistory(page)\nprint(page.data.count)\n```"
        default:
            return lead + "Done. I moved the review to *tomorrow morning* and let the team know."
        }
    }

    private static func references(_ index: Int) -> [[String: Any]] {
        let tasks = index == count - 1 ? [0, 1] : index == count - 3 ? [2, 3] : []
        return tasks.map { ["type": "conversation_ref", "conversation_id": "task\($0)", "title": "Task \($0)"] }
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
