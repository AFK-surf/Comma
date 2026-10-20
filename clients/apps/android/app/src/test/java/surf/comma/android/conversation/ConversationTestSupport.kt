package surf.comma.android.conversation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import java.util.concurrent.CopyOnWriteArrayList

// All identifiers and text below are invented test data.
const val GROUP = "grp_test_1"
const val CHAT = "cnv_test_main"

/** The signed-in session's scopes, as the session owner publishes them. */
internal class FakeSessions : ConversationSessions {
    override val scopes = MutableStateFlow<ConversationScope?>(null)
    override fun isCurrent(scope: ConversationScope) = scopes.value === scope
}

internal fun scope(generation: Long, account: String = "usr_test_a", group: String = GROUP, chat: String = CHAT) =
    ConversationScope(generation, account, group, chat)

internal fun message(
    seq: Long,
    actor: String = if (seq % 2 == 1L) "user" else "agent",
    text: String = "message $seq",
    clientRequestId: String? = if (actor == "user") "req-$seq" else null,
    id: String = "msg_test_$seq",
    configure: JSONObject.() -> Unit = {},
): JSONObject = JSONObject()
    .put("message_id", id).put("seq", seq).put("actor_type", actor).put("kind", "message")
    .put("participant_id", if (actor == "user") "ptp_test_user" else "ptp_test_agent")
    .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text)))
    .put("created_at", 1_700_000_000_000L + seq)
    .apply {
        clientRequestId?.let { put("client_request_id", it) }
        if (actor == "agent") put("agent_id", "agt_test_1")
        configure()
    }

internal fun messages(range: LongRange) = range.map { message(it) }

/**
 * The message the client core's chat makes of a server message, for the content these tests use: text, inline and
 * referred tasks, interactive content, images and files, a device setup offer, an Agent's question and a person's
 * answer to one. The projection itself is the core's and is tested there.
 */
internal fun viewMessage(server: JSONObject): JSONObject {
    val actor = server.getString("actor_type")
    val agent = server.optString("agent_id").takeIf { actor == "agent" && it.isNotEmpty() }
    val parts = JSONArray()
    val attachments = JSONArray()
    val refs = JSONArray()
    val content = server.optJSONArray("content") ?: JSONArray()
    val text = StringBuilder()
    for (index in 0 until content.length()) {
        val block = content.getJSONObject(index)
        fun copy(to: JSONObject, vararg names: Pair<String, String>) = to.apply {
            for ((from, name) in names) if (block.has(from)) put(name, block.get(from))
        }
        when (block.getString("type")) {
            "text" -> {
                parts.put(JSONObject().put("kind", "markdown").put("text", block.getString("text")))
                text.append(block.getString("text"))
            }
            "conversation_ref" -> if (block.optString("presentation") == "inline") {
                val available = block.opt("unavailable") != true && block.optString("kind") == "agent_task" && block.has("conversation_id")
                parts.put(JSONObject().put("kind", "inline-task").put("task", copy(JSONObject().put("unavailable", !available),
                    "title" to "title", "status" to "status", "activity_status" to "activityStatus").apply {
                    if (available) put("conversationId", block.getString("conversation_id"))
                }))
            } else refs.put(copy(JSONObject(), "conversation_id" to "conversationId", "kind" to "kind", "title" to "title",
                "status" to "status", "activity_status" to "activityStatus"))
            "dynamic_ui" -> parts.put(copy(JSONObject().put("kind", "dynamic-ui").put("attachmentIndex", index)
                .put("summary", block.optString("summary")), "ui_ref" to "uiRef", "version" to "version", "origin_task_id" to "originTaskId"))
            "image", "file" -> attachments.put(copy(JSONObject().put("blockType", block.getString("type")), "file_name" to "fileName",
                "title" to "title", "mime_type" to "mimeType", "size" to "size", "width" to "width", "height" to "height",
                "path" to "workspacePath").apply {
                block.optJSONObject("blob_ref")?.let { ref ->
                    put("blobRef", JSONObject(ref.toString()).put("kind", "blob"))
                    if (agent != null) put("agentId", agent).put("attachmentIndex", index)
                }
            })
            "device_setup_offer" -> parts.put(JSONObject().put("kind", "device-setup-offer").put("offer", copy(JSONObject(),
                "offer_id" to "offerId", "name" to "name", "model" to "model", "short_id" to "shortId",
                "reporter_device_id" to "reporterDeviceId", "status" to "status", "expires_at" to "expiresAt", "revision" to "revision")))
            // The core reads the question block into a card and drops its plain-text fallback; `state` stands in for
            // what the core read of the transcript after it.
            "question" -> parts.put(copy(JSONObject().put("kind", "question").put("messageId", server.getString("message_id"))
                .put("state", block.optJSONObject("state") ?: JSONObject().put("status", "open")),
                "prompt" to "prompt", "choices" to "choices", "multi_select" to "multiSelect", "allow_other" to "allowOther"))
            "question_answer" -> parts.put(copy(JSONObject().put("kind", "question-answer"), "question_message_id" to "questionMessageId",
                "choice_ids" to "choiceIds", "other" to "other", "skipped" to "skipped"))
        }
    }
    return JSONObject().put("messageId", server.getString("message_id")).put("seq", server.getLong("seq"))
        .put("role", if (actor == "user") "user" else "assistant").put("actorType", actor).put("delivery", "sent")
        .put("source", "server").put("text", text.toString()).put("parts", parts).put("attachments", attachments).put("refs", refs)
        .apply {
            agent?.let { put("actorId", it) }
            if (server.has("client_request_id")) put("clientRequestId", server.get("client_request_id"))
            if (server.has("created_at")) put("createdAt", server.get("created_at"))
            val type = server.optJSONObject("metadata")?.optString("message_type")?.takeIf { it.isNotEmpty() }
            type?.let { put("messageType", it) }
            if (type == "task_command" || type == "meeting_recording") put("brief", true)
            // A person's words as the core reads them: these tests write no quotes or file lists into the text.
            if (actor == "user") put("display", shown(text.toString()))
            else {
                // Its parts as the core parsed them; a question card is drawn apart from the Markdown.
                val written = JSONArray((0 until parts.length()).map { parts.getJSONObject(it) }.filter { it.optString("kind") != "question" })
                if (written.length() > 0) put("markdown", JSONArray(surf.comma.android.chat.render.Md.ofParts(written)))
                // The agent speaking, worth a notification (these tests write plain words).
                if (actor == "agent" && text.isNotBlank()) put("notice", JSONObject().put("preview", text.toString().trim()))
                // The tasks it announces: its inline chips that open, then its task references, each once.
                val chips = (0 until parts.length()).mapNotNull { parts.getJSONObject(it).optJSONObject("task") }
                    .filter { !it.optBoolean("unavailable") }.mapNotNull { it.optString("conversationId").takeIf(String::isNotEmpty) }
                val listed = (0 until refs.length()).map { refs.getJSONObject(it) }.filter { it.optString("kind") == "agent_task" }
                    .map { it.getString("conversationId") }
                val ids = (chips + listed).distinct()
                if (ids.isNotEmpty()) put("createdTasks", JSONArray(ids.map { JSONObject().put("conversationId", it) }))
            }
        }
}

/** The core's reading of a person's message ([ChatMessage.workspaceFiles] and the words beside them). */
internal fun shown(body: String, files: List<WorkspaceFile> = emptyList()): JSONObject =
    JSONObject().put("body", body).put("quotes", JSONArray())
        .put("files", JSONArray(files.map { JSONObject().put("name", it.name).put("path", it.path) }))

/** A `chatView` value: [state] as the core's conversation state. */
internal fun viewValue(state: JSONObject?, revision: Long = 1): JSONObject =
    JSONObject().put("revision", revision).put("state", state ?: JSONObject.NULL)

/** The conversation state of [messages] (server messages), read in [ranges] (one over all of them unless given). */
internal fun viewState(messages: List<JSONObject>, ranges: List<LongRange>? = null): JSONObject {
    val read = ranges ?: listOfNotNull(messages.takeIf { it.isNotEmpty() }
        ?.let { it.minOf { m -> m.getLong("seq") }..it.maxOf { m -> m.getLong("seq") } })
    return JSONObject().put("status", "ready").put("connection", "live").put("awaitingReply", false)
        .put("serverMessages", JSONArray(messages.sortedBy { it.getLong("seq") }.map(::viewMessage)))
        .put("pending", JSONArray()).put("draftAttachments", JSONArray())
        .put("history", JSONObject().put("hasOlder", false).put("loadingOlder", false)
            .put("ranges", JSONArray(read.map { JSONArray().put(it.first).put(it.last) })))
}

/** What the chat shows of a server message; null when it shows nothing of it. */
internal fun display(server: JSONObject, shown: JSONObject? = null): ChatMessage? {
    val state = viewState(listOf(server))
    shown?.let { state.getJSONArray("serverMessages").getJSONObject(0).put("display", it) }
    return (ChatViewReader(scope(1), CHAT).read(viewValue(state)).timeline.firstOrNull() as? TimelineEntry.Message)?.message
}

internal suspend fun ChatView.awaitState(predicate: (ConversationState) -> Boolean) = state.first(predicate)

internal fun ConversationState.messageSeqs() = timeline.filterIsInstance<TimelineEntry.Message>().map { it.message.seq }
internal fun ConversationState.texts() = timeline.map { entry ->
    when (entry) {
        is TimelineEntry.Message -> (entry.message.parts.firstOrNull() as? MessagePart.Text)?.text
        is TimelineEntry.Pending -> entry.pending.text
        is TimelineEntry.Draft -> entry.draft.text
        is TimelineEntry.Gap -> null
    }
}

/**
 * The client core's `chatView` topic for one conversation, as far as the app's own code reads it: what is sent goes
 * into `pending`, and becomes a canonical message when [accept] is set (at once, or on a retry); otherwise it fails.
 * A file attached (or retried) uploads at once unless [uploads] is false. The conversation itself (the stream, paging, gaps, what
 * is kept) is the core's and is tested there.
 */
internal class FakeChatViewCore : surf.comma.android.core.CoreApi {
    /** Every send and retry handed to the core: the `chatView.send` params of that message. */
    val sends = CopyOnWriteArrayList<JSONObject>()
    val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
    val subscribed = CopyOnWriteArrayList<JSONObject>()
    /** How many times the conversation was asked to read again. */
    val refreshes = MutableStateFlow(0)
    @Volatile var accept = false
    @Volatile var uploads = true
    private val lock = Any()
    private val messages = ArrayList<JSONObject>()
    private val pending = LinkedHashMap<String, JSONObject>()
    private val attached = LinkedHashMap<String, JSONObject>()
    /** Images of question cards' other answers, by question. */
    private val questionAttached = LinkedHashMap<String, LinkedHashMap<String, JSONObject>>()
    /** Whether the core takes a question card's answer. */
    @Volatile var answers = true
    private val displays = HashMap<String, JSONObject>()
    private var ranges: List<LongRange>? = null
    private var extra = JSONObject()
    private var revision = 0L
    private val value = MutableStateFlow(JSONObject())

    init { publish() }

    /** Shows [list] (server messages) in [shown] seq ranges; [fields] replace fields of the conversation's state. */
    fun show(list: List<JSONObject>, shown: List<LongRange>? = null, fields: JSONObject = JSONObject()) = synchronized(lock) {
        messages.clear()
        messages += list
        ranges = shown
        extra = fields
        publish()
    }

    private fun publish() {
        val state = viewState(messages, ranges).put("pending", JSONArray(pending.values.toList()))
            // The core closes its `messages` with the sends still pending, as it reads them.
            .put("messages", JSONArray(pending.keys.map { id ->
                JSONObject().put("source", "pending").put("clientRequestId", id).apply { displays[id]?.let { put("display", it) } }
            }))
            .put("draftAttachments", JSONArray(attached.values.toList())).put("awaitingReply", pending.isNotEmpty())
            .put("questionAttachments", JSONObject().apply {
                for ((question, files) in questionAttached) put(question, JSONArray(files.values.toList()))
            })
            .put("conversation", JSONObject().put("id", CHAT).put("title", "Test chat").put("status", "active"))
        for (key in extra.keys()) state.put(key, extra.get(key))
        // A send the server took keeps the core's reading of it.
        val server = state.getJSONArray("serverMessages")
        for (index in 0 until server.length()) server.getJSONObject(index).let { message ->
            displays[message.optString("clientRequestId")]?.let { message.put("display", it) }
        }
        value.value = viewValue(state, ++revision)
    }

    private fun settle(id: String) {
        val item = pending[id] ?: return
        if (accept) {
            pending.remove(id)
            messages += message((messages.maxOfOrNull { it.getLong("seq") } ?: 0) + 1, "user", item.getString("text"), id)
            ranges = null
        } else pending[id] = JSONObject(item.toString()).put("status", "failed").put("error", "No connection")
    }

    override suspend fun call(name: String, params: JSONObject): Any? = synchronized(lock) {
        calls += name to params
        val id = params.optString("clientRequestId")
        when (name) {
            "chatView.send" -> {
                val files = attached.values.filter { it.getString("status") == "uploaded" }
                if (attached.size > files.size) throw surf.comma.android.core.CoreError("internal", "an attachment is not ready")
                val text = params.getString("text")
                if (text.isBlank() && files.isEmpty()) return@synchronized receipt()
                sends += params
                val body = if (files.isEmpty()) text else text.trim().ifEmpty { "I've attached some files:" } + "\n\n" +
                    "Attached files in your workspace:\n" + files.joinToString("\n") { "- ${it.getString("name")} (workspace file: ${it.getString("path")})" }
                displays[id] = shown(text.trim(), files.map { WorkspaceFile(it.getString("name"), it.getString("path")) })
                attached.clear()
                pending[id] = JSONObject().put("clientRequestId", id).put("text", body).put("createdAt", sends.size.toLong())
                    .put("status", "sending").apply { params.opt("replyToMessageId")?.let { put("replyToMessageId", it) } }
                settle(id)
                publish()
            }
            "chatView.retry" -> {
                sends.lastOrNull { it.optString("clientRequestId") == id }?.let { sends += it }
                pending[id]?.let { pending[id] = JSONObject(it.toString()).put("status", "sending") }
                settle(id)
                publish()
            }
            "chatView.discard" -> {
                pending.remove(id)
                publish()
            }
            "chatView.attach" -> if (params.has("questionMessageId")) attachToCard(params) else {
                val files = params.getJSONArray("files")
                for (index in 0 until files.length()) {
                    val file = files.getJSONObject(index)
                    val row = "att-${revision + index}"
                    attached[row] = JSONObject().put("id", row).put("name", file.getString("name")).put("size", file.getLong("size"))
                        .put("isImage", true).put("status", if (uploads) "uploaded" else "failed")
                        .apply { if (uploads) put("path", "/uploads/abcdefghijklmnopqrstuv-${file.getString("name")}") else put("error", "The upload failed") }
                }
                publish()
            }
            "chatView.removeAttachment" -> {
                if (params.has("questionMessageId")) questionAttached[params.getString("questionMessageId")]?.remove(params.getString("attachmentId"))
                else attached.remove(params.getString("attachmentId"))
                publish()
            }
            "chatView.retryAttachment" -> {
                val row = params.getString("attachmentId")
                attached[row]?.let { file ->
                    attached[row] = JSONObject(file.toString()).put("status", if (uploads) "uploaded" else "failed").apply {
                        if (uploads) { put("path", "/uploads/abcdefghijklmnopqrstuv-${file.getString("name")}"); remove("error") }
                    }
                }
                publish()
            }
            "chatView.refresh" -> refreshes.value++
            "chatView.answerQuestion" -> if (!answers) throw surf.comma.android.core.CoreError("internal", "an answer is on its way")
        }
        receipt()
    }

    private fun attachToCard(params: JSONObject) {
        val files = params.getJSONArray("files")
        val rows = questionAttached.getOrPut(params.getString("questionMessageId")) { LinkedHashMap() }
        for (index in 0 until files.length()) {
            val file = files.getJSONObject(index)
            val row = "qatt-${revision + index}"
            rows[row] = JSONObject().put("id", row).put("name", file.getString("name")).put("size", file.getLong("size"))
                .put("isImage", true).put("status", if (uploads) "uploaded" else "uploading")
                .apply { if (uploads) put("path", "/uploads/abcdefghijklmnopqrstuv-${file.getString("name")}") }
        }
        publish()
    }

    private fun receipt() = JSONObject().put("revision", revision)

    override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): kotlinx.coroutines.flow.Flow<surf.comma.android.core.TopicValue<T>> {
        subscribed += topic
        return if (topic.optString("topic") != "chatView") kotlinx.coroutines.flow.emptyFlow()
        else value.map { surf.comma.android.core.TopicValue.Value(read(it)) }
    }
}

/**
 * The core's reading of the next reply (`replyState`) for a state these tests build by hand: [awaiting] is the core's
 * `awaitingReply`, a draft not ended streams, a send not failed is on its way.
 */
internal fun replyOf(participant: ParticipantStatus?, awaiting: Boolean, timeline: List<TimelineEntry>): ReplyState {
    val draft = timeline.filterIsInstance<TimelineEntry.Draft>().lastOrNull()
    val streaming = draft != null && !draft.draft.ended
    val sending = timeline.any { it is TimelineEntry.Pending && it.pending.status == PendingStatus.SENDING }
    return ReplyState(coming = sending || (awaiting && draft == null) || streaming, streaming = streaming,
        working = participant?.state == "active" && !participant.loopWake, failed = participant?.state == "error")
}
