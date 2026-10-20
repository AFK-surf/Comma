package surf.comma.android.chat.live

import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.media.*
import surf.comma.android.conversation.WorkspaceFile
import surf.comma.android.conversation.MessageAttachment
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import org.json.JSONArray
import surf.comma.android.chat.render.MarkdownText
import surf.comma.android.chat.render.MarkdownTree
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.MessageCopy
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ChatMessage as LiveMessage
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.PendingMessage
import surf.comma.android.conversation.PendingStatus
import surf.comma.android.conversation.TimelineEntry

/** Row kinds the live chat adds to the timeline. Payloads are plain delimited fields. */
object LiveRowKinds {
    const val TASK_REF = "task.ref"
    const val ATTACHMENT = "attachment"
    const val INTERACTIVE_SUMMARY = "ui.summary"

    /**
     * The buttons under a finished reply. The payload is the reply's turn key, which
     * [replyText] turns back into the reply's text.
     */
    const val REPLY_ACTIONS = "reply.actions"

    /**
     * The same measured space, blank, while the reply is on its way. The timeline compensates
     * this hidden tail in its bottom inset, then releases the compensation with the size spring
     * as the buttons appear. It has its own row id so the buttons retain their reveal fade.
     */
    const val REPLY_ACTIONS_RESERVED = "reply.actions.reserved"

    /**
     * A finished voice call, on the user's side: the row's text is what it says ("2:13 · Call
     * ended"). Kept on this device only; see [surf.comma.android.voice.ui.CallLogStore].
     */
    const val CALL_LOG = "call.log"

    /**
     * An Agent's question, after the message that asks it: an open card, or the receipt it closes into. The payload
     * is a [QuestionCardPayload]: the question and the images its other answer holds.
     */
    const val QUESTION = "question"

    private const val SEPARATOR = '\u001F'

    /** [suffix] is punctuation that followed the reference in the text and stays on its line. */
    class TaskRef(val conversationId: String?, val title: String?, val status: String?, val unavailable: Boolean,
                  val suffix: String = "")
    class Attachment(val image: Boolean, val name: String, val widthPx: Int?, val heightPx: Int?)

    fun encode(task: TaskRef) = listOf(task.conversationId.orEmpty(), task.title.orEmpty(), task.status.orEmpty(),
        if (task.unavailable) "1" else "0", task.suffix).joinToString(SEPARATOR.toString())

    fun decodeTask(payload: String?): TaskRef {
        val fields = payload.orEmpty().split(SEPARATOR)
        return TaskRef(fields.getOrNull(0)?.ifEmpty { null }, fields.getOrNull(1)?.ifEmpty { null },
            fields.getOrNull(2)?.ifEmpty { null }, fields.getOrNull(3) == "1", fields.getOrNull(4).orEmpty())
    }

    fun encode(attachment: Attachment) = listOf(if (attachment.image) "image" else "file", attachment.name,
        attachment.widthPx?.toString().orEmpty(), attachment.heightPx?.toString().orEmpty()).joinToString(SEPARATOR.toString())

    fun decodeAttachment(payload: String?): Attachment {
        val fields = payload.orEmpty().split(SEPARATOR)
        return Attachment(fields.getOrNull(0) == "image", fields.getOrNull(1).orEmpty(),
            fields.getOrNull(2)?.toIntOrNull()?.takeIf { it > 0 }, fields.getOrNull(3)?.toIntOrNull()?.takeIf { it > 0 })
    }
}

/** Display strings the mapping needs; the defaults are only for tests. */
data class LiveLabels(
    val replyErrorTitle: String = "回复出错了",
    val replyErrorDetail: String = "请稍后再试。",
    val interactiveUnavailable: String = "交互内容暂不可用",
    val file: String = "文件",
    val historyGap: String = "正在加载错过的消息…",
)

/**
 * The list rows for one conversation state. [retryTargets] maps a failed send's row id to the
 * client request id the data layer retries with; [entryRows] maps a timeline entry's key to the
 * id of its first row.
 */
class LiveTimeline(
    val rows: List<ChatMessage>,
    val retryTargets: Map<Long, String>,
    val entryRows: Map<String, Long> = emptyMap(),
    /** The timeline entry each message row came from; see [entryText]. */
    val rowEntries: Map<Long, String> = emptyMap(),
)

/**
 * Maps the data layer's timeline to list rows, off the main thread.
 *
 * Row ids hash stable keys: a user message and the pending send it came from share the
 * `r:<client request id>` key, so the row keeps its id (and its view) when the send is confirmed.
 * A message whose content mixes text with task references or attachments becomes several
 * consecutive rows, each keyed by the message key and the part it shows.
 *
 * A reply is shown one whole message at a time: each canonical message appears complete as soon
 * as it arrives. The streamed draft is still received, reconnected and deduplicated by the data
 * layer, but its text is never shown or copied; while it streams, the typing bubble stands in for
 * it. A draft the server ended (cancelled) waits for its canonical message, if any, and on its
 * own shows nothing. Messages from the system are status lines, never agent bubbles.
 *
 * The typing bubble shows while the agent works on a message, a send waits for its reply or a
 * draft streams; not while the conversation is cut off (the connection notice says so instead),
 * and never next to a reply error.
 *
 * With [replyActions], each reply that has text ends with a [LiveRowKinds.REPLY_ACTIONS] row;
 * while the latest reply is on its way, a [LiveRowKinds.REPLY_ACTIONS_RESERVED] row holds its
 * place.
 */
fun mapConversation(
    state: ConversationState,
    labels: LiveLabels = LiveLabels(),
    replyActions: Boolean = false,
    /** What this device knows of the question cards' images beyond the core's rows: previews and images being made ready. */
    questionImages: QuestionImagesShown = QuestionImagesShown(),
    resolveMedia: (ChatAttachment) -> ChatAttachment = { it },
): LiveTimeline {
    val builder = RowBuilder(state.conversationId.orEmpty(), resolveMedia) { question ->
        QuestionCardPayload.of(question, state.questionAttachments[question.messageId].orEmpty(), questionImages)
    }
    for (entry in state.timeline) {
        when (entry) {
            is TimelineEntry.Message -> builder.message(entry.key, entry.message, labels)
            is TimelineEntry.Pending -> builder.pending(entry.key, entry.pending, labels)
            is TimelineEntry.Gap -> builder.gap(entry.key, labels.historyGap)
            // Never a row: the text is incomplete until its canonical message replaces it.
            is TimelineEntry.Draft -> Unit
        }
    }
    val reply = state.reply
    when {
        reply.failed -> builder.replyError(labels.replyErrorTitle,
            state.participant?.issue?.let(::shortIssue) ?: labels.replyErrorDetail)
        isCutOff(state) -> Unit
        // Waiting for a reply is shown as the typing bubble alone; the status text is not used.
        reply.pending -> builder.typing()
    }
    // A failed reply is over, whatever its draft says: no room is kept for its buttons.
    val rows = if (replyActions) builder.rowsWithReplyActions(reply.pending) else builder.rows
    return LiveTimeline(rows, builder.retryTargets, builder.entryRows, builder.rowEntries)
}

private class RowBuilder(
    private val conversationId: String,
    private val resolveMedia: (ChatAttachment) -> ChatAttachment,
    private val questionPayload: (surf.comma.android.conversation.AgentQuestion) -> QuestionCardPayload,
) {
    val rows = ArrayList<ChatMessage>()
    val retryTargets = HashMap<Long, String>()
    val entryRows = HashMap<String, Long>()
    val rowEntries = HashMap<Long, String>()
    /** Turns whose reply has text to copy. */
    private val repliedTurns = HashSet<String>()
    private var turn = ""

    fun message(key: String, message: LiveMessage, labels: LiveLabels) {
        val start = rows.size
        messageRows(key, message, labels)
        if (rows.size > start) entryRows[key] = rows[start].id
        for (index in start until rows.size) rowEntries[rows[index].id] = key
        if (message.role != surf.comma.android.conversation.ChatRole.USER && message.actorType != SYSTEM_ACTOR &&
            message.parts.any { it is MessagePart.Text && it.text.isNotBlank() }) repliedTurns += turn
    }

    fun rowsWithReplyActions(generating: Boolean): List<ChatMessage> =
        withReplyActions(rows, generating) { it in repliedTurns }

    private fun messageRows(key: String, message: LiveMessage, labels: LiveLabels) {
        val user = message.role == surf.comma.android.conversation.ChatRole.USER
        if (user) turn = key
        val role = when {
            user -> ChatRole.USER
            message.actorType == SYSTEM_ACTOR -> ChatRole.SYSTEM
            else -> ChatRole.AGENT
        }
        val createdAt = message.createdAt ?: 0L
        // An agent's message as the core parsed it: its runs of text, and the parts between them.
        message.markdown?.let { markdown ->
            treeRows(key, message, JSONArray(markdown), role, createdAt, labels)
            mediaAndRefRows(key, message, role, createdAt, labels)
            questionRows(key, message, role, createdAt)
            return
        }
        val text = StringBuilder()
        var textStart = -1
        var afterSplit = false
        // Punctuation right after a task chip belongs to the chip's line, not the next row.
        var chipAwaitingText = -1
        // A run cut off by a card becomes its own row, so whitespace at the cut is row edge.
        fun flush(split: Boolean) {
            var run = text.toString()
            if (afterSplit) run = run.trimStart()
            if (split) run = run.trimEnd()
            if (textStart >= 0 && run.isNotBlank()) add("$key#p$textStart", role, run, createdAt)
            text.clear()
            textStart = -1
            afterSplit = split
        }
        message.parts.forEachIndexed { index, part ->
            when (part) {
                is MessagePart.SetupOffer -> {
                    chipAwaitingText = -1
                    flush(split = true)
                    add("$key#p$index", role, "", createdAt,
                        surf.comma.android.settings.devices.DeviceSetupOffer.TYPE, part.offer.json().toString())
                }
                is MessagePart.Text -> {
                    var body = part.text
                    if (chipAwaitingText >= 0) {
                        val stop = attachedPunctuationLength(body)
                        if (stop > 0) attachSuffix(chipAwaitingText, body.substring(0, stop))
                        body = body.substring(stop)
                        chipAwaitingText = -1
                    }
                    if (textStart < 0) textStart = index
                    text.append(body)
                }
                is MessagePart.TaskChip -> {
                    flush(split = true)
                    add("$key#p$index", role, "", createdAt, LiveRowKinds.TASK_REF, LiveRowKinds.encode(
                        LiveRowKinds.TaskRef(part.conversationId, part.title, part.status, part.unavailable)))
                    chipAwaitingText = rows.lastIndex
                }
                is MessagePart.InteractiveSummary -> {
                    chipAwaitingText = -1
                    flush(split = true)
                    add("$key#p$index", role, part.summary ?: labels.interactiveUnavailable, createdAt,
                        LiveRowKinds.INTERACTIVE_SUMMARY, part.uiRef)
                }
                // Drawn after everything the message says; see [questionRows].
                is MessagePart.Question -> Unit
            }
        }
        flush(split = false)
        mediaAndRefRows(key, message, role, createdAt, labels)
        questionRows(key, message, role, createdAt)
    }

    /** The questions a message asks, each a card of its own after its text, files and task cards. */
    private fun questionRows(key: String, message: LiveMessage, role: ChatRole, createdAt: Long) {
        message.parts.forEach { part ->
            if (part is MessagePart.Question)
                add("$key#q${part.question.messageId}", role, part.question.prompt, createdAt, LiveRowKinds.QUESTION,
                    questionPayload(part.question).encode())
        }
    }

    private fun treeRows(
        key: String, message: LiveMessage, tree: JSONArray, role: ChatRole, createdAt: Long, labels: LiveLabels,
    ) {
        val parts = message.parts
        // A part deeper in the text than a paragraph of its own (a chip in a list item) is read as its words.
        fun words(element: String): String? = MarkdownTree.partIndex(element)?.let(parts::getOrNull)?.let { part ->
            when (part) {
                is MessagePart.TaskChip -> part.title
                is MessagePart.InteractiveSummary -> part.summary ?: labels.interactiveUnavailable
                else -> null
            }
        }
        // Punctuation right after a task chip belongs to the chip's line, not the next row.
        var chipAwaitingText = -1
        MarkdownTree.pieces(tree).forEachIndexed { index, piece ->
            when (piece) {
                is MarkdownTree.Piece.Tree -> {
                    var nodes = MarkdownTree.withElements(piece.nodes, ::words)
                    if (chipAwaitingText >= 0) {
                        val (suffix, rest) = MarkdownTree.leadingPunctuation(nodes, ::attachedPunctuationLength)
                        if (suffix.isNotEmpty()) attachSuffix(chipAwaitingText, suffix)
                        nodes = rest
                        chipAwaitingText = -1
                    }
                    val shown = MarkdownTree.blocks(nodes)
                    if (shown.isNotEmpty())
                        add("$key#${if (index == 0) "p0" else "t$index"}", role, MarkdownTree.plainText(shown),
                            createdAt, markdown = nodes.toString())
                }
                is MarkdownTree.Piece.Element -> {
                    chipAwaitingText = -1
                    val at = MarkdownTree.partIndex(piece.key) ?: return@forEachIndexed
                    when (val part = parts.getOrNull(at)) {
                        is MessagePart.TaskChip -> {
                            add("$key#p$at", role, "", createdAt, LiveRowKinds.TASK_REF, LiveRowKinds.encode(
                                LiveRowKinds.TaskRef(part.conversationId, part.title, part.status, part.unavailable)))
                            chipAwaitingText = rows.lastIndex
                        }
                        is MessagePart.InteractiveSummary -> add("$key#p$at", role,
                            part.summary ?: labels.interactiveUnavailable, createdAt, LiveRowKinds.INTERACTIVE_SUMMARY, part.uiRef)
                        is MessagePart.SetupOffer -> add("$key#p$at", role, "", createdAt,
                            surf.comma.android.settings.devices.DeviceSetupOffer.TYPE, part.offer.json().toString())
                        else -> Unit
                    }
                }
            }
        }
    }

    private fun mediaAndRefRows(key: String, message: LiveMessage, role: ChatRole, createdAt: Long, labels: LiveLabels) {
        val attachments = message.attachments.mapIndexed { index, attachment ->
            "$key#a${attachment.blockIndex.takeIf { it >= 0 } ?: "n$index"}" to attachment.toChatAttachment(conversationId, message.messageId, labels.file)
        } + message.workspaceFiles.mapIndexed { index, file -> "$key#f$index" to file.toChatAttachment() }
        mediaRows(attachments, role, createdAt)
        message.refs.forEachIndexed { index, ref ->
            add("$key#r$index", role, "", createdAt, LiveRowKinds.TASK_REF, LiveRowKinds.encode(
                LiveRowKinds.TaskRef(ref.conversationId, ref.title, ref.status, unavailable = false)))
        }
    }

    private fun attachSuffix(rowIndex: Int, suffix: String) {
        val row = rows[rowIndex]
        val task = LiveRowKinds.decodeTask(row.cardPayload)
        rows[rowIndex] = row.copy(cardPayload = LiveRowKinds.encode(LiveRowKinds.TaskRef(task.conversationId, task.title,
            task.status, task.unavailable, task.suffix + suffix)))
    }

    fun pending(key: String, pending: PendingMessage, labels: LiveLabels) {
        turn = key
        val failed = pending.status == PendingStatus.FAILED
        // Same key as the confirmed message's first text part, so the row survives confirmation.
        if (pending.text.isNotBlank() || (failed && pending.workspaceFiles.isEmpty())) {
            val id = add("$key#p0", ChatRole.USER, pending.text, pending.createdAt, status = when (pending.status) {
                PendingStatus.SENDING -> MessageStatus.PENDING
                PendingStatus.FAILED -> MessageStatus.FAILED
            }, requestId = pending.clientRequestId, retryable = failed)
            rowEntries[id] = key
            if (failed) retryTargets[id] = pending.clientRequestId
        }
        mediaRows(pending.workspaceFiles.mapIndexed { index, file -> "$key#f$index" to file.toChatAttachment() },
            ChatRole.USER, pending.createdAt, pending)
    }

    /**
     * Unread messages between two shown ranges: a status line that starts a turn of its own, so
     * replies after it never join the turn before it (their buttons, their copied text).
     */
    fun gap(key: String, text: String) {
        turn = key
        add(key, ChatRole.SYSTEM, text, 0L)
    }

    /** The typing bubble: a status row without text. */
    fun typing() {
        add(STATUS_KEY, ChatRole.AGENT, "", 0L, TimelineBlockKinds.LIVE_STATUS)
    }

    /** Replying failed. There is no way to ask for the reply again yet, so no retry control. */
    fun replyError(title: String, detail: String) {
        add(ERROR_KEY, ChatRole.AGENT, title, 0L, TimelineBlockKinds.REPLY_ERROR, detail, retryable = false)
    }

    private fun mediaRows(
        files: List<Pair<String, ChatAttachment>>, role: ChatRole, createdAt: Long, pending: PendingMessage? = null,
    ) {
        val resolved = files.map { (key, file) -> key to resolveMedia(file) }
        // View the whole message in original attachment order, using the authenticated originals.
        val gallery = resolved.mapNotNull { (_, file) -> file.copy(preview = null).image() }
        var imageIndex = 0
        resolved.forEach { (key, file) ->
            val attachment = file.copy(gallery = gallery, galleryIndex = if (file.display == AttachmentDisplay.IMAGE) imageIndex++ else 0)
            val failed = pending?.status == PendingStatus.FAILED
            val id = add(key, role, "", createdAt, LiveRowKinds.ATTACHMENT,
                LiveRowKinds.encode(LiveRowKinds.Attachment(file.display == AttachmentDisplay.IMAGE,
                    file.file.displayName, file.dimensions?.width, file.dimensions?.height)),
                status = when (pending?.status) {
                    PendingStatus.SENDING -> MessageStatus.PENDING
                    PendingStatus.FAILED -> MessageStatus.FAILED
                    else -> MessageStatus.COMPLETED
                }, requestId = pending?.clientRequestId, retryable = failed, attachment = attachment)
            if (failed) retryTargets[id] = pending!!.clientRequestId
        }
    }

    private fun add(
        key: String,
        role: ChatRole,
        text: String,
        createdAt: Long,
        cardKind: String? = null,
        payload: String? = null,
        status: MessageStatus = MessageStatus.COMPLETED,
        requestId: String? = null,
        retryable: Boolean = false,
        attachment: ChatAttachment? = null,
        markdown: String? = null,
    ): Long {
        val id = rowId(key)
        rows += ChatMessage(id = id, conversationId = conversationId, turnId = turn, role = role, text = text,
            createdAt = createdAt, status = status, requestId = requestId, retryable = retryable,
            cardKind = cardKind, cardPayload = payload, attachment = attachment, markdown = markdown)
        return id
    }

    private companion object {
        const val STATUS_KEY = "live-status"
        const val ERROR_KEY = "live-error"
    }
}

private const val SYSTEM_ACTOR = "system"

/**
 * Nothing new can arrive: the stream is down with a problem (offline, or stopped by the server).
 * A typing bubble would spin until the connection is back, so it waits for the next snapshot.
 */
private fun isCutOff(state: ConversationState): Boolean =
    state.problem != null && state.problem != surf.comma.android.conversation.ConversationProblem.STORAGE &&
        state.connection != Connection.LIVE

/**
 * [rows] with the buttons after the last agent row of each reply whose turn is [replied]. The
 * latest reply gets reserved space instead while [generating].
 *
 * A reply is every agent row of one turn. A system notice inside it (a status line) does not end
 * it: the agent rows on both sides are one reply, with one set of buttons after its last row,
 * copying all of it. A gap or a user message does start a new turn, and with it a new reply.
 */
internal fun withReplyActions(rows: List<ChatMessage>, generating: Boolean, replied: (String) -> Boolean): List<ChatMessage> {
    // Turns are contiguous: only user messages, pending sends and gaps start one.
    val lastAgent = HashMap<String, Int>()
    rows.forEachIndexed { index, row -> if (row.role == ChatRole.AGENT) lastAgent[row.turnId] = index }
    val latestTurn = rows.lastOrNull()?.turnId
    val out = ArrayList<ChatMessage>(rows.size + rows.size / 2)
    rows.forEachIndexed { index, row ->
        out += row
        if (row.role != ChatRole.AGENT || lastAgent[row.turnId] != index) return@forEachIndexed
        val reserved = generating && row.turnId == latestTurn
        if (!reserved && !replied(row.turnId)) return@forEachIndexed
        val kind = if (reserved) LiveRowKinds.REPLY_ACTIONS_RESERVED else LiveRowKinds.REPLY_ACTIONS
        // Rows without a turn (agent messages before the first user message) key off the row.
        val key = row.turnId.ifEmpty { "row:${row.id}" }
        out += ChatMessage(id = rowId("$key#$kind"), conversationId = row.conversationId, turnId = row.turnId,
            role = ChatRole.AGENT, text = "", createdAt = row.createdAt, cardKind = kind,
            cardPayload = if (reserved) null else row.turnId)
    }
    return out
}

/**
 * Reply buttons for rows that did not come from [mapConversation] (the local fixtures): a turn
 * counts as replied when one of its agent message rows has text.
 */
fun withReplyActions(rows: List<ChatMessage>): List<ChatMessage> {
    val replied = rows.filter { it.role == ChatRole.AGENT && it.cardKind == null && it.text.isNotBlank() }
        .mapTo(HashSet()) { it.turnId }
    return withReplyActions(rows, generating = rows.lastOrNull()?.status?.isActive == true) { it in replied }
}

/**
 * The markdown source of one timeline entry, as the user would copy it: text parts in order, a
 * task reference as its title, interactive content as its summary. Null when there is no entry
 * [key].
 */
fun entryText(state: ConversationState, key: String): String? =
    state.timeline.firstOrNull { it.key == key }?.let(::entryText)

private fun entryText(entry: TimelineEntry): String = when (entry) {
    is TimelineEntry.Message -> buildString {
        entry.message.parts.forEach { part ->
            when (part) {
                is MessagePart.Text -> append(part.text)
                is MessagePart.TaskChip -> append(part.title.orEmpty())
                is MessagePart.InteractiveSummary -> part.summary?.let(::append)
                is MessagePart.SetupOffer -> Unit
                // The card is not part of the message's words.
                is MessagePart.Question -> Unit
            }
        }
    }.trim()
    is TimelineEntry.Pending -> entry.pending.text.trim()
    is TimelineEntry.Draft -> entry.draft.text.trim()
    is TimelineEntry.Gap -> ""
}

/**
 * The blocks of one timeline entry for text selection: an agent's message as the core parsed it,
 * a task reference as its title; anything else as written. Null when there is no entry [key].
 */
fun entryBlocks(state: ConversationState, key: String): List<MessageContent>? {
    val entry = state.timeline.firstOrNull { it.key == key } ?: return null
    val message = (entry as? TimelineEntry.Message)?.message
    val markdown = message?.markdown
        ?: return listOf(MessageContent.Paragraph(MarkdownText.plain(entryText(entry))))
    return MarkdownTree.blocks(JSONArray(markdown)) { element ->
        MarkdownTree.partIndex(element)?.let(message.parts::getOrNull)?.let { part ->
            when (part) {
                is MessagePart.TaskChip -> part.title
                is MessagePart.InteractiveSummary -> part.summary
                else -> null
            }
        }
    }
}

/**
 * The whole reply of turn [turnKey] (the key a [LiveRowKinds.REPLY_ACTIONS] row carries): every
 * agent message after that turn's user message (or its gap), up to the next user message or gap,
 * each as [entryText]. A streamed draft is not shown, so it is not copied either.
 */
fun replyText(state: ConversationState, turnKey: String): String {
    var turn = ""
    val parts = ArrayList<String>()
    for (entry in state.timeline) {
        when (entry) {
            is TimelineEntry.Message ->
                if (entry.message.role == surf.comma.android.conversation.ChatRole.USER) turn = entry.key
                else if (turn == turnKey && entry.message.actorType != SYSTEM_ACTOR) parts += entryText(entry)
            is TimelineEntry.Pending -> turn = entry.key
            is TimelineEntry.Draft -> Unit
            // Messages past an unread gap are not known to answer the turn before it.
            is TimelineEntry.Gap -> turn = entry.key
        }
    }
    return MessageCopy.reply(parts)
}

/**
 * How many leading characters of [text] are closing punctuation that must stay on the line of
 * whatever precedes it: full stops, commas, closing brackets and quotes, in Latin and CJK forms.
 */
internal fun attachedPunctuationLength(text: String): Int {
    var end = 0
    while (end < text.length && text[end] in ATTACHED_PUNCTUATION) end++
    return end
}

private const val ATTACHED_PUNCTUATION = ".,;:!?…)]}’”»›%。，、；：！？）】」』》〉〕］｝"

/** The first line of the server's issue text, kept short enough for a card. */
private fun shortIssue(issue: String): String? {
    val line = issue.lineSequence().map(String::trim).firstOrNull(String::isNotEmpty) ?: return null
    return if (line.length <= ISSUE_LIMIT) line else line.take(ISSUE_LIMIT - 1).trimEnd() + "…"
}

private const val ISSUE_LIMIT = 140

internal fun MessageAttachment.toChatAttachment(conversationId: String, messageId: String, fallback: String): ChatAttachment {
    val name = fileName ?: title ?: workspacePath?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: fallback
    val ref = blobRef?.let { runCatching { MediaBlobRef(it.uuid, it.hash, it.size) }.getOrNull() }
    val source = when {
        ref != null && !agentId.isNullOrBlank() -> MediaSource.AgentResource(agentId, ref)
        ref != null && downloadable -> MediaSource.MessageAttachment(conversationId, messageId, blockIndex, ref)
        workspacePath != null && validUploadedImagePath(workspacePath) -> MediaSource.UploadedFile(workspacePath)
        else -> null
    }
    val dimensions = if (widthPx != null && heightPx != null && widthPx > 0 && heightPx > 0) ImageDimensions(widthPx, heightPx) else null
    return ChatAttachment(MediaAttachment(name, mimeType, size ?: blobRef?.size, source), dimensions)
}

internal fun WorkspaceFile.toChatAttachment(): ChatAttachment {
    val source = path.takeIf(::validUploadedImagePath)?.let(MediaSource::UploadedFile)
    val dimensions = if (width != null && height != null && width > 0 && height > 0) ImageDimensions(width, height) else null
    return ChatAttachment(MediaAttachment(name, mimeType, size, source), dimensions)
}

/** 64-bit FNV-1a of a row key: the list's stable id. */
fun rowId(key: String): Long {
    var hash = -0x340d631b7bdddcdbL
    for (char in key) {
        hash = hash xor char.code.toLong()
        hash *= 0x100000001b3L
    }
    return hash
}

/** A reply is being produced: it streams in, or the agent works on it. */
fun isGenerating(state: ConversationState): Boolean = state.reply.streaming || state.reply.working
