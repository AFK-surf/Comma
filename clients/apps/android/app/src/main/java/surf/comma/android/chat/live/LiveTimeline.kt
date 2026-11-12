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
import org.json.JSONObject
import surf.comma.android.chat.render.MarkdownText
import surf.comma.android.chat.render.MarkdownTree
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.conversation.AgentRequest
import surf.comma.android.conversation.AgentRequestStatus
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ChatMessage as LiveMessage
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.PendingMessage
import surf.comma.android.conversation.PendingStatus
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.tasks.ui.KnownTasks

/** Row kinds the live chat adds to the timeline. Payloads are plain delimited fields. */
object LiveRowKinds {
    const val TASK_REF = "task.ref"
    const val ATTACHMENT = "attachment"
    /** A message's generated UI: its summary, opened by a tap. The payload is its [surf.comma.android.dynamicui.DynamicUiTarget]'s JSON, if any. */
    const val INTERACTIVE_SUMMARY = "ui.summary"

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

    /**
     * An Agent's request to the person (connect an account): an open card, or the receipt it closes into. It sits
     * after the Agent's reply to the message its turn served. The payload is the [AgentRequest]'s JSON.
     */
    const val AGENT_REQUEST = "agent.request"

    /** A Mini App Version's launch card, after the message that names it. The payload is the card's JSON. */
    const val MINI_APP = "mini.app"

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
    /** A task in running text whose title is not known yet. */
    val task: String = "任务",
    /** A task in running text that cannot be opened. */
    val taskUnavailable: String = "任务不可用",
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
 */
fun mapConversation(
    state: ConversationState,
    labels: LiveLabels = LiveLabels(),
    /** What this device knows of the question cards' images beyond the core's rows: previews and images being made ready. */
    questionImages: QuestionImagesShown = QuestionImagesShown(),
    /** The Agent's requests in this conversation (the core's `agentRequests`), for their cards. */
    requests: List<AgentRequest> = emptyList(),
    /** What the page's task directory knows: the titles of tasks in running text, and IDs that are not tasks. */
    tasks: KnownTasks = KnownTasks(),
    resolveMedia: (ChatAttachment) -> ChatAttachment = { it },
): LiveTimeline {
    val builder = RowBuilder(state.conversationId.orEmpty(), tasks, resolveMedia) { question ->
        QuestionCardPayload.of(question, state.questionAttachments[question.messageId].orEmpty(), questionImages)
    }
    val placed = placeRequests(state.timeline, requests)
    for (entry in state.timeline) {
        when (entry) {
            is TimelineEntry.Message -> {
                builder.message(entry.key, entry.message, labels)
                placed.byEntry[entry.key]?.let(builder::requests)
            }
            is TimelineEntry.Pending -> builder.pending(entry.key, entry.pending, labels)
            is TimelineEntry.Gap -> builder.gap(entry.key, labels.historyGap)
            // Never a row: the text is incomplete until its canonical message replaces it.
            is TimelineEntry.Draft -> Unit
        }
    }
    builder.requests(placed.waiting)
    val reply = state.reply
    when {
        reply.failed -> builder.replyError(labels.replyErrorTitle,
            state.participant?.issue?.let(::shortIssue) ?: labels.replyErrorDetail)
        isCutOff(state) -> Unit
        // Waiting for a reply is shown as the typing bubble alone; the status text is not used.
        reply.pending -> builder.typing()
    }
    return LiveTimeline(builder.rows, builder.retryTargets, builder.entryRows, builder.rowEntries)
}

/** Where the request cards go: after the entry of the reply that owns each, or on the newest turn. */
internal class PlacedRequests(val byEntry: Map<String, List<AgentRequest>>, val waiting: List<AgentRequest>)

/**
 * Places each request after the reply that owns its card: the Agent's first message after the person's message the
 * request's turn served. A pending request whose reply has not come (the Agent waits on it) goes on the newest turn.
 * A finished one with no reply among the messages shown (its turn is not loaded) shows nowhere: its receipt belongs
 * to that turn. Oldest request first within a reply.
 */
internal fun placeRequests(timeline: List<TimelineEntry>, requests: List<AgentRequest>): PlacedRequests {
    if (requests.isEmpty()) return PlacedRequests(emptyMap(), emptyList())
    val messages = timeline.filterIsInstance<TimelineEntry.Message>()
    val index = HashMap<String, Int>()
    messages.forEachIndexed { at, entry -> index[entry.message.messageId] = at }
    fun replyAfter(source: String?): String? {
        val start = source?.let(index::get) ?: return null
        for (at in start + 1 until messages.size) {
            val message = messages[at].message
            if (message.role != surf.comma.android.conversation.ChatRole.USER && message.actorType != SYSTEM_ACTOR)
                return messages[at].key
        }
        return null
    }
    val byEntry = LinkedHashMap<String, MutableList<AgentRequest>>()
    val waiting = ArrayList<AgentRequest>()
    for (request in requests.sortedBy { it.createdAt ?: 0L }) {
        val anchor = replyAfter(request.sourceMessageId)
        when {
            anchor != null -> byEntry.getOrPut(anchor) { ArrayList() } += request
            request.status == AgentRequestStatus.PENDING -> waiting += request
        }
    }
    return PlacedRequests(byEntry, waiting)
}

private class RowBuilder(
    private val conversationId: String,
    private val tasks: KnownTasks,
    private val resolveMedia: (ChatAttachment) -> ChatAttachment,
    private val questionPayload: (surf.comma.android.conversation.AgentQuestion) -> QuestionCardPayload,
) {
    val rows = ArrayList<ChatMessage>()
    val retryTargets = HashMap<Long, String>()
    val entryRows = HashMap<String, Long>()
    val rowEntries = HashMap<Long, String>()
    private var turn = ""

    fun message(key: String, message: LiveMessage, labels: LiveLabels) {
        val start = rows.size
        messageRows(key, message, labels)
        if (rows.size > start) entryRows[key] = rows[start].id
        for (index in start until rows.size) rowEntries[rows[index].id] = key
    }

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
            miniAppRows(key, message, role, createdAt)
            questionRows(key, message, role, createdAt)
            return
        }
        treeRows(key, message, partsTree(message.parts), role, createdAt, labels)
        mediaAndRefRows(key, message, role, createdAt, labels)
        miniAppRows(key, message, role, createdAt)
        questionRows(key, message, role, createdAt)
    }

    /** Request cards, each a row of its own in the current turn. */
    fun requests(requests: List<AgentRequest>) {
        for (request in requests)
            add("request:${request.id}", ChatRole.AGENT, request.reason, request.createdAt ?: 0L, LiveRowKinds.AGENT_REQUEST,
                request.json().toString())
    }

    /** The Mini App Versions a message names, each a launch card after its text, files and task cards. */
    private fun miniAppRows(key: String, message: LiveMessage, role: ChatRole, createdAt: Long) {
        message.parts.forEachIndexed { index, part ->
            if (part is MessagePart.MiniApp)
                add("$key#m$index", role, part.app.name, createdAt, LiveRowKinds.MINI_APP, part.app.json().toString())
        }
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
        // A part deeper in the text than a paragraph of its own (interactive content in a list item) is read as its words.
        fun words(element: String): String? = MarkdownTree.partIndex(element)?.let(parts::getOrNull)?.let { part ->
            when (part) {
                is MessagePart.InteractiveSummary -> part.summary ?: labels.interactiveUnavailable
                else -> null
            }
        }
        // Punctuation right after a task chip belongs to the chip's line, not the next row.
        var chipAwaitingText = -1
        MarkdownTree.pieces(inlineTasks(tree, parts, labels, tasks)).forEachIndexed { index, piece ->
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
                            part.summary ?: labels.interactiveUnavailable, createdAt, LiveRowKinds.INTERACTIVE_SUMMARY,
                            part.target?.json()?.toString())
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
     * replies after it never join the turn before it.
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

private fun partsTree(parts: List<MessagePart>): JSONArray {
    val tree = JSONArray()
    var paragraph = JSONArray()
    fun flushParagraph() {
        if (paragraph.length() > 0) tree.put(JSONArray().put("p").put(paragraph))
        paragraph = JSONArray()
    }
    parts.forEachIndexed { index, part ->
        when (part) {
            is MessagePart.Text -> {
                val runs = part.text.split(PARAGRAPH_BREAK)
                runs.forEachIndexed { at, run ->
                    if (at > 0) flushParagraph()
                    // Blank space at a paragraph break is the paragraph's edge.
                    var text = run
                    if (at > 0) text = text.trimStart()
                    if (at < runs.lastIndex) text = text.trimEnd()
                    if (text.isNotEmpty()) paragraph.put(text)
                }
            }
            // Cards drawn after the message; see [miniAppRows] and [questionRows].
            is MessagePart.Question, is MessagePart.MiniApp -> Unit
            else -> paragraph.put(JSONArray().put("comma-inline")
                .put(JSONObject().put("key", "element-${index.toString(36)}")))
        }
    }
    flushParagraph()
    return tree
}

/**
 * Keeps a task alone in a top-level paragraph (closing punctuation may follow it) as a card. Every other task, in a
 * sentence, a list item, a heading or a quote, becomes words in its text before pieces would split the paragraph
 * around it ([inlineTask]).
 */
private fun inlineTasks(
    tree: JSONArray, parts: List<MessagePart>, labels: LiveLabels, tasks: KnownTasks,
    words: MutableMap<Int, String>? = null,
): JSONArray {
    fun chipIndex(node: Any?): Int? {
        val array = node as? JSONArray ?: return null
        if (array.optString(0) != "comma-inline") return null
        return MarkdownTree.partIndex(array.optJSONObject(1)?.optString("key").orEmpty())
    }
    fun chip(node: Any?) = chipIndex(node)?.let(parts::getOrNull) as? MessagePart.TaskChip
    fun transform(node: Any?, root: Boolean): Any? {
        val array = node as? JSONArray ?: return node
        val kids = array.opt(1) as? JSONArray ?: return node
        val values = (0 until kids.length()).map { kids.opt(it) }
        val before = values.takeWhile { chip(it) == null }
        val card = root && array.optString(0) == "p" && values.count { chip(it) != null } == 1 &&
            before.all { it is String && it.isBlank() } &&
            values.filter { chip(it) == null }.all { it is String && it.drop(attachedPunctuationLength(it)).isBlank() }
        if (card) return node
        val out = JSONArray().put(array.opt(0)).put(JSONArray().apply {
            values.forEach { child ->
                val part = chip(child)
                if (part == null) put(transform(child, root = false)) else {
                    val replacement = inlineTask(part, labels, tasks)
                    chipIndex(child)?.let { words?.put(it, MarkdownTree.text(listOf(replacement)).text) }
                    put(replacement)
                }
            }
        })
        for (at in 2 until array.length()) out.put(array.opt(at))
        return out
    }
    return JSONArray().apply { for (at in 0 until tree.length()) put(transform(tree.opt(at), root = true)) }
}

/**
 * A task in running text: a link titled as the directory names the task, else as the chip does, else [LiveLabels.task].
 * A task that cannot be opened, by the card's own rule ([taskRefDisplay]), is plain words.
 */
private fun inlineTask(chip: MessagePart.TaskChip, labels: LiveLabels, tasks: KnownTasks): Any {
    val ref = LiveRowKinds.TaskRef(chip.conversationId, chip.title, chip.status, chip.unavailable)
    val (id, title) = when (val display = taskRefDisplay(ref, tasks)) {
        TaskRefDisplay.Unavailable -> return labels.taskUnavailable
        is TaskRefDisplay.Ready -> display.task.id to
            (display.task.title.takeIf { it.isNotBlank() } ?: chip.title?.takeIf { it.isNotBlank() })
        is TaskRefDisplay.Loading -> display.taskId to display.title
    }
    return JSONArray().put("a").put(JSONArray().put(title ?: labels.task)).put(JSONObject().put("href", "comma:task/$id"))
}

private fun taskCopyText(chip: MessagePart.TaskChip, labels: LiveLabels, tasks: KnownTasks): String =
    MarkdownTree.text(listOf(inlineTask(chip, labels, tasks))).text

/**
 * The markdown source of one timeline entry, as the user would copy it: text parts in order, a
 * task reference as its title, interactive content as its summary. Null when there is no entry
 * [key].
 */
fun entryText(
    state: ConversationState, key: String, tasks: KnownTasks = KnownTasks(), labels: LiveLabels = LiveLabels(),
): String? = state.timeline.firstOrNull { it.key == key }?.let { entryText(it, tasks, labels) }

private fun entryText(entry: TimelineEntry, tasks: KnownTasks, labels: LiveLabels): String = when (entry) {
    is TimelineEntry.Message -> buildString {
        val words = HashMap<Int, String>()
        val message = entry.message
        inlineTasks(message.markdown?.let(::JSONArray) ?: partsTree(message.parts), message.parts, labels, tasks, words)
        message.parts.forEachIndexed { index, part ->
            when (part) {
                is MessagePart.Text -> append(part.text)
                is MessagePart.TaskChip -> append(words[index] ?: taskCopyText(part, labels, tasks))
                is MessagePart.InteractiveSummary -> part.summary?.let(::append)
                is MessagePart.SetupOffer -> Unit
                // The card is not part of the message's words.
                is MessagePart.Question, is MessagePart.MiniApp -> Unit
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
fun entryBlocks(
    state: ConversationState, key: String, tasks: KnownTasks = KnownTasks(), labels: LiveLabels = LiveLabels(),
): List<MessageContent>? {
    val entry = state.timeline.firstOrNull { it.key == key } ?: return null
    val message = (entry as? TimelineEntry.Message)?.message
    val markdown = message?.markdown
        ?: return listOf(MessageContent.Paragraph(MarkdownText.plain(entryText(entry, tasks, labels))))
    return MarkdownTree.blocks(inlineTasks(JSONArray(markdown), message.parts, labels, tasks)) { element ->
        MarkdownTree.partIndex(element)?.let(message.parts::getOrNull)?.let { part ->
            when (part) {
                is MessagePart.TaskChip -> taskCopyText(part, labels, tasks)
                is MessagePart.InteractiveSummary -> part.summary
                else -> null
            }
        }
    }
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

/** A blank line between paragraphs, in text the core did not parse. */
private val PARAGRAPH_BREAK = Regex("\n{2,}")

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
        downloadable -> MediaSource.MessageAttachment(conversationId, messageId, blockIndex, ref)
        workspacePath != null && validUploadedPath(workspacePath) -> MediaSource.UploadedFile(workspacePath)
        else -> null
    }
    val dimensions = if (widthPx != null && heightPx != null && widthPx > 0 && heightPx > 0) ImageDimensions(widthPx, heightPx) else null
    return ChatAttachment(MediaAttachment(name, mimeType, size ?: blobRef?.size, source), dimensions)
}

internal fun WorkspaceFile.toChatAttachment(): ChatAttachment {
    val source = path.takeIf(::validUploadedPath)?.let(MediaSource::UploadedFile)
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
