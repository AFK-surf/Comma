package surf.comma.android.tasks.pages

import surf.comma.android.chat.live.LiveTimeline
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.TaskInfoRow
import surf.comma.android.tasks.ui.TaskStrings

/**
 * The rows of a task's page: its status line first, then its messages as the chat maps them, with
 * the instructions the task was created with folded into a brief card.
 *
 * Which message is the brief comes from the data, never from its wording: see
 * [surf.comma.android.conversation.ChatMessage.brief]. A brief is open when its row id is
 * in [expanded].
 */
internal fun taskDetailRows(
    timeline: LiveTimeline,
    entries: List<TimelineEntry.Message>,
    task: TaskSummary?,
    labels: List<TaskLabel>,
    strings: TaskStrings,
    expanded: Set<Long>,
): List<ChatMessage> {
    val briefKeys = entries.filter { it.message.brief }.mapTo(HashSet()) { it.key }
    val messages = timeline.rows.map { row ->
        if (row.cardKind == null && row.text.isNotBlank() && timeline.rowEntries[row.id] in briefKeys) {
            // Read as the page's own text whoever posted it: a user bubble's white text on the card
            // would not show.
            row.copy(
                role = ChatRole.AGENT,
                cardKind = TimelineBlockKinds.TASK_BRIEF,
                cardPayload = TimelineBlockKinds.TASK_BRIEF_EXPANDED.takeIf { row.id in expanded },
            )
        } else {
            row
        }
    }
    return if (task == null) messages else listOf(TaskInfoRow.message(task, labels, strings)) + messages
}

/** Whether a failed read is worth trying again; a missing or forbidden task is not. */
internal fun taskDetailRetryable(problem: ConversationProblem?): Boolean =
    problem != null && problem != ConversationProblem.NOT_FOUND && problem != ConversationProblem.FORBIDDEN
