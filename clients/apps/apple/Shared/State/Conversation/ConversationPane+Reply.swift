import Foundation
import CommaCore

/// The thread a member chose to reply in. `targetID` is the message they picked; once their first reply is sent
/// it clears, and later replies answer the thread's newest message.
struct ReplyThreadSelection: Equatable {
    let rootID: String
    var targetID: String?
}

/// Replying to a message: the thread it belongs to gathers above the composer, and sends go into that thread.
extension ConversationPane {
    /// The committed message the next send answers.
    var replyTargetID: String? {
        guard let replyThread else { return nil }
        if let target = replyThread.targetID { return target }
        return messages.last { ($0.threadRootMessageID ?? $0.id) == replyThread.rootID }?.id ?? replyThread.rootID
    }

    func openReplyThread(on message: Message) {
        guard target != nil, !closed else { return }
        replyThread = ReplyThreadSelection(rootID: message.threadRootMessageID ?? message.id, targetID: message.id)
    }

    func closeReplyThread() { replyThread = nil }
}
