package surf.comma.android.conversation

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.settings.devices.DeviceSetupOffer
import surf.comma.android.core.CoreBytes
import surf.comma.android.ui.Background
import java.util.IdentityHashMap
import java.util.UUID

/**
 * One conversation as the client core shows it to a window: its `chatView` topic and the `chatView.*` calls, the
 * same ones the desktop's windows use. The core keeps the conversation (the event stream, history and its gaps, the
 * streaming reply, what is being sent, the composer's files); this class shows the topic while the chat is on screen
 * (or a reply is waited for in the background) and passes on what the person does.
 *
 * The main chat's view follows the session's scope. A view made with [main] false shows the conversation given to
 * [open] instead (a task's), in the same Group.
 *
 * Every value is tied to the scope it was read for, so one that arrives after a sign-out or an account switch is
 * discarded instead of reaching the new account's state.
 */
class ChatView internal constructor(
    private val sessions: ConversationSessions,
    private val core: CoreApi?,
    private val main: Boolean = true,
    private val io: CoroutineDispatcher = Background.files,
    private val newRequestId: () -> String = { UUID.randomUUID().toString() },
) {
    private val root = CoroutineScope(SupervisorJob() + io)
    private val lock = Any()
    private val mutableState = MutableStateFlow(ConversationState())
    val state: StateFlow<ConversationState> = mutableState.asStateFlow()

    /** A UI preparation can outlive the account that produced its snapshot. */
    fun isCurrent(state: ConversationState): Boolean = state.scope?.let(sessions::isCurrent) ?: (state.groupId == null)

    private class Target(val scope: ConversationScope, val conversationId: String) {
        fun json(): JSONObject = JSONObject().put("workspace", scope.workspaceId).put("group", scope.groupId)
            .put("conversation", conversationId).put("surface", SURFACE)
    }

    // Guarded by [lock].
    private var scope: ConversationScope? = null
    private var opened: String? = null
    private var target: Target? = null
    private var foreground = false
    /** Keeps the conversation shown to the core while the chat is hidden, for a reply the user is waiting on. */
    private var backgroundHold = false
    private var showing: Job? = null
    private var started = false
    /** One file is attached at a time, so the row the core makes for it is known. */
    private val attaching = Mutex()

    /** Follows [ConversationSessions.scopes] until [close]. Call once. */
    fun start() {
        synchronized(lock) {
            if (started) return
            started = true
        }
        // The scope there is now applies before this returns: what is asked right after finds it.
        switchTo(sessions.scopes.value)
        root.launch { sessions.scopes.collect(::switchTo) }
    }

    private fun switchTo(next: ConversationScope?) = synchronized(lock) {
        val wanted = next?.takeIf(sessions::isCurrent)
        if (scope === wanted) return@synchronized
        scope = wanted
        if (!main) opened = null
        retarget()
    }

    /** Shows [conversationId] of the scope's Group, or nothing; for a view that is not the main chat's. */
    fun open(conversationId: String?) = synchronized(lock) {
        check(!main)
        if (opened == conversationId) return@synchronized
        opened = conversationId
        retarget()
    }

    /** Call under [lock]. */
    private fun retarget() {
        val current = scope
        val conversation = if (main) current?.conversationId else opened
        target = if (current != null && conversation != null) Target(current, conversation) else null
        showing?.cancel()
        showing = null
        mutableState.value = target?.let { ConversationState(groupId = it.scope.groupId, conversationId = it.conversationId, scope = it.scope) }
            ?: ConversationState()
        show()
    }

    /** The core keeps the event stream only while the chat is visible; returning resumes and fills any gap. */
    fun setForeground(visible: Boolean) = synchronized(lock) {
        foreground = visible
        show()
    }

    /**
     * Keeps the event stream open while the chat is hidden, so a reply that is on its way still arrives. Releasing
     * it while the chat is hidden lets the stream go exactly as leaving does.
     */
    fun setBackgroundHold(hold: Boolean) = synchronized(lock) {
        backgroundHold = hold
        show()
    }

    /** Shows the conversation to the core while it is wanted, and lets it go when it is not. Call under [lock]. */
    private fun show() {
        val current = target
        val wanted = current != null && (foreground || backgroundHold) && core != null
        if (!wanted) {
            showing?.cancel()
            showing = null
            val shown = mutableState.value
            if (shown.scope != null && shown.connection != Connection.PAUSED && shown.connection != Connection.IDLE)
                mutableState.value = shown.copy(connection = Connection.BACKGROUND)
            return
        }
        if (showing?.isActive == true) return
        val reader = ChatViewReader(current!!.scope, current.conversationId)
        showing = root.launch {
            core!!.subscribe(current.json().put("topic", "chatView"), reader::read).collect { value ->
                if (value !is TopicValue.Value) return@collect
                synchronized(lock) {
                    if (target === current && sessions.isCurrent(current.scope)) mutableState.value = value.value
                }
            }
        }
    }

    private fun current(): Target? = synchronized(lock) { target?.takeIf { sessions.isCurrent(it.scope) } }

    /** One of the core's calls for the conversation shown; null when there is none or the core refused. */
    private suspend fun call(name: String, fill: JSONObject.() -> Unit = {}): Any? {
        val current = current() ?: return null
        return try {
            core?.call("chatView.$name", current.json().apply(fill))
        } catch (e: CancellationException) {
            throw e
        } catch (_: CoreError) {
            null
        }
    }

    /**
     * Ends the Task this view shows by hand: `completed` or `cancelled`, at the version the member saw. Throws the
     * core's [CoreError] when the server refused it.
     */
    suspend fun setTaskStatus(status: String, expectedUpdatedAt: Long) {
        val current = current() ?: throw CoreError("unavailable", "No conversation")
        val running = core ?: throw CoreError("unavailable", "No client core")
        running.call("chatView.setTaskStatus", current.json().put("status", status).put("expectedUpdatedAt", expectedUpdatedAt))
    }

    /** Retries a paused stream or interrupts network backoff after an explicit recovery action. */
    fun reconnect() {
        root.launch { call("refresh") }
    }

    /** The device's network came back or went away: the core tries its stream again at once. */
    fun networkChanged(@Suppress("UNUSED_PARAMETER") available: Boolean) = reconnect()

    /** Loads the page before the oldest visible message. */
    suspend fun loadOlder() {
        call("older")
    }

    /**
     * Sends [text] with the files of the draft. Returns the client request id once the message is in the
     * conversation as being sent, or null when the core took nothing (nothing to send, no conversation, a file not
     * uploaded). The message goes on to its server outside this call.
     */
    suspend fun send(
        text: String,
        replyToMessageId: String? = null,
        clientRequestId: String = newRequestId(),
        /** The locations of the skills the message names, which activates them. */
        skills: List<String> = emptyList(),
        /** Rechecked just before the message is handed over, so a draft cannot cross sessions. */
        canSend: () -> Boolean = { true },
    ): String? {
        require(clientRequestId.isNotBlank())
        if (!canSend()) return null
        val sent = root.async {
            call("send") {
                put("text", text)
                put("clientRequestId", clientRequestId)
                replyToMessageId?.let { put("replyToMessageId", it) }
                if (skills.isNotEmpty()) put("skills", JSONArray(skills.map { JSONObject().put("location", it) }))
            }
        }
        val shown = root.async { state.first { it.has(clientRequestId) } }
        // The call answers once the server has the message; the message shows as soon as the core took it.
        val admitted = try {
            select {
                shown.onAwait { true }
                sent.onAwait { receipt ->
                    // Answered already: the state that has the receipt's revision says whether the core took it.
                    val settled = (receipt as? JSONObject)?.optLong("revision")
                        ?.let { revision -> state.first { it.revision >= revision || it.scope == null } }
                    (settled ?: state.value).has(clientRequestId)
                }
            }
        } finally {
            shown.cancel()
        }
        return clientRequestId.takeIf { admitted }
    }

    /** Resends a failed message with its original id and text. */
    suspend fun retry(clientRequestId: String) {
        call("retry") { put("clientRequestId", clientRequestId) }
    }

    /** Drops a failed message. A message that may still be in flight cannot be discarded. */
    suspend fun discard(clientRequestId: String) {
        call("discard") { put("clientRequestId", clientRequestId) }
    }

    /**
     * Adds a file to the draft, or with [questionMessageId] to that question card's other answer (apart from the
     * draft), which the core uploads. Returns its row ([ConversationState.attachments], or the card's
     * [ConversationState.questionAttachments], says how its upload goes), or null when the core took none.
     */
    suspend fun attach(name: String, bytes: ByteArray, questionMessageId: String? = null): String? = attaching.withLock {
        fun rows(state: ConversationState) =
            if (questionMessageId == null) state.attachments else state.questionAttachments[questionMessageId].orEmpty()
        val before = rows(state.value).mapTo(HashSet()) { it.id }
        val receipt = call("attach") {
            questionMessageId?.let { put("questionMessageId", it) }
            put("files", JSONArray().put(JSONObject().put("name", name).put("size", bytes.size)
                .put("bytes", CoreBytes.json(bytes))))
        } as? JSONObject ?: return null
        val revision = receipt.optLong("revision")
        rows(state.first { it.revision >= revision || it.scope == null }).firstOrNull { it.id !in before }?.id
    }

    /** Removes a file from the draft, or from question card [questionMessageId]. */
    suspend fun removeAttachment(id: String, questionMessageId: String? = null) {
        call("removeAttachment") {
            put("attachmentId", id)
            questionMessageId?.let { put("questionMessageId", it) }
        }
    }

    /** Uploads a failed file of the draft, or of question card [questionMessageId], again. */
    suspend fun retryAttachment(id: String, questionMessageId: String? = null) {
        call("retryAttachment") {
            put("attachmentId", id)
            questionMessageId?.let { put("questionMessageId", it) }
        }
    }

    /**
     * Answers question card [questionMessageId]: the core words the answer and sends it as one message replying to
     * the question, with the images the card holds; the card's state then says how it goes. [skipped] answers
     * nothing and leaves the choice to the Agent. False when the core took no answer (one is on its way, an image
     * is not uploaded yet, or it says nothing).
     */
    suspend fun answerQuestion(questionMessageId: String, choiceIds: List<String>, other: String? = null, skipped: Boolean = false): Boolean =
        call("answerQuestion") {
            put("questionMessageId", questionMessageId).put("choiceIds", JSONArray(choiceIds))
            other?.let { put("other", it) }
            if (skipped) put("skipped", true)
        } != null

    fun close() {
        root.cancel()
    }

    private companion object {
        /** The window this app is to the core: it has one. */
        const val SURFACE = "android"
    }
}

private fun ConversationState.has(clientRequestId: String): Boolean = timeline.any { entry ->
    when (entry) {
        is TimelineEntry.Pending -> entry.pending.clientRequestId == clientRequestId
        is TimelineEntry.Message -> entry.message.clientRequestId == clientRequestId
        else -> false
    }
}

/**
 * Reads the core's `chatView` value into the chat's state. It runs on the core client's thread, one value at a
 * time, and keeps what it read: a part of the value the topic did not change is the same object as before, so a
 * message is read again only when it changed, and the rows are made again only when the messages or the history's
 * ranges did. A streaming reply costs nothing but its own text.
 */
internal class ChatViewReader(private val scope: ConversationScope, private val conversationId: String) {
    private var read = IdentityHashMap<JSONObject, ChatMessage?>()
    private var messagesRead: JSONArray? = null
    private var rangesRead: JSONArray? = null
    private var canonical: List<TimelineEntry> = emptyList()

    fun read(value: Any?): ConversationState {
        val empty = ConversationState(groupId = scope.groupId, conversationId = conversationId, scope = scope)
        val view = value as? JSONObject ?: return empty
        val revision = view.optLong("revision")
        val json = view.optJSONObject("state") ?: return empty.copy(revision = revision)
        val history = json.optJSONObject("history")
        val rows = visible(json.optJSONArray("serverMessages") ?: JSONArray(), history?.optJSONArray("ranges"))
        val keys = rows.mapTo(HashSet()) { it.key }
        val timeline = ArrayList<TimelineEntry>(rows.size + 2)
        timeline += rows
        val pending = json.optJSONArray("pending") ?: JSONArray()
        val shown = pendingDisplays(json.optJSONArray("messages"))
        for (index in 0 until pending.length()) {
            val item = pending.optJSONObject(index)?.let { pending(it, shown) } ?: continue
            val key = requestKey(item.clientRequestId)
            if (key !in keys) timeline += TimelineEntry.Pending(key, item)
        }
        json.optJSONObject("assistantDraft")?.let { draft ->
            val reply = ReplyDraft(draft.optString("responseKey"), strings(draft.optJSONArray("sourceMessageIds")),
                draft.optString("draftId"), draft.optLongOrNull("revision"), draft.optString("text"),
                ended = draft.optString("status") == "completed")
            timeline += TimelineEntry.Draft(reply.key, reply)
        }
        val conversation = json.optJSONObject("conversation")
        val status = json.optString("status")
        val problem = when (json.string("errorKind")) {
            "network" -> ConversationProblem.NETWORK
            "unauthorized" -> ConversationProblem.UNAUTHORIZED
            "forbidden" -> ConversationProblem.FORBIDDEN
            "not-found" -> ConversationProblem.NOT_FOUND
            else -> ConversationProblem.SERVER.takeIf { status == "error" }
        }
        return ConversationState(
            groupId = scope.groupId,
            conversationId = conversationId,
            title = conversation?.string("title"),
            status = conversation?.string("status"),
            timeline = timeline,
            participant = json.optJSONObject("participantStatus")?.let { said ->
                ParticipantStatus(said.optString("participantId"), said.optString("state"), said.string("status"),
                    said.string("issue"), said.string("workingProvider"), said.optLongOrNull("updatedAt"),
                    loopWake = said.optBoolean("loopWake"))
            },
            activity = json.optJSONObject("activity")?.let { activity ->
                ReplyActivity(activity.optString("responseKey"), strings(activity.optJSONArray("sourceMessageIds")),
                    activity.optString("phase"), activity.optString("status"), activity.optString("summaryClass"),
                    activity.string("summary"), activity.string("toolName"))
            },
            connection = when (json.optString("connection")) {
                "connecting" -> Connection.CONNECTING
                "live" -> Connection.LIVE
                "reconnecting" -> Connection.RECONNECTING
                "paused" -> Connection.PAUSED
                else -> Connection.IDLE
            },
            problem = problem,
            // What the device kept shows before the server answered; an empty conversation is known once it did.
            cacheLoaded = rows.isNotEmpty() || status == "ready" || status == "error",
            hasOlder = history?.optBoolean("hasOlder") == true,
            loadingOlder = history?.optBoolean("loadingOlder") == true,
            reply = json.optJSONObject("reply")?.let { said ->
                ReplyState(said.optBoolean("coming"), said.optBoolean("thinking"), said.optBoolean("streaming"),
                    said.optBoolean("working"), said.optBoolean("failed"), said.optBoolean("timedOut"))
            } ?: ReplyState(),
            attachments = attachments(json.optJSONArray("draftAttachments")),
            questionAttachments = json.optJSONObject("questionAttachments")?.let { byQuestion ->
                byQuestion.keys().asSequence().associateWith { attachments(byQuestion.optJSONArray(it)) }.filterValues { it.isNotEmpty() }
            }.orEmpty(),
            revision = revision,
            scope = scope,
        )
    }

    /**
     * The messages in the order the core gives them (by seq). Between two ranges of the history read sits one
     * [TimelineEntry.Gap], keyed by the newer range's start, which the core keeps fixed until the ranges meet.
     */
    private fun visible(messages: JSONArray, ranges: JSONArray?): List<TimelineEntry> {
        if (messages === messagesRead && ranges === rangesRead) return canonical
        messagesRead = messages
        rangesRead = ranges
        val next = IdentityHashMap<JSONObject, ChatMessage?>(messages.length())
        val gaps = (1 until (ranges?.length() ?: 0)).mapNotNull { ranges!!.optJSONArray(it)?.optLong(0) }.sorted().toMutableList()
        val keys = HashSet<String>()
        val out = ArrayList<TimelineEntry>(messages.length() + gaps.size)
        for (index in 0 until messages.length()) {
            val json = messages.optJSONObject(index) ?: continue
            val message = if (read.containsKey(json)) read[json] else message(json)
            next[json] = message
            message ?: continue
            // A gap sits before the first message of each range but the oldest.
            while (message.seq > 0 && gaps.isNotEmpty() && message.seq >= gaps.first()) out += TimelineEntry.Gap("gap:${gaps.removeAt(0)}")
            val preferred = message.clientRequestId?.let(::requestKey)
            val key = if (preferred != null && keys.add(preferred)) preferred else "m:${message.messageId}".also { keys += it }
            out += TimelineEntry.Message(key, message)
        }
        read = next
        canonical = out
        return out
    }

    /** Null for a message with nothing to show. */
    private fun message(json: JSONObject): ChatMessage? {
        val id = json.string("messageId") ?: return null
        val user = json.optString("role") == "user"
        val listed = json.optJSONArray("parts")
        val parts = ArrayList<MessagePart>()
        // A person's message as the core read it: its parts are their words, the quotes and files beside them.
        val display = json.optJSONObject("display")
        quoted(display)?.let { parts += MessagePart.Text(it) }
        if (listed == null) parts += MessagePart.Text(display?.optString("body")?.let(ModelMentionLinks::asWords) ?: json.optString("text"))
        else for (index in 0 until listed.length()) part(listed.optJSONObject(index) ?: continue)?.let(parts::add)
        trimEdges(parts)
        val files = files(display)
        parts.removeAll { it is MessagePart.Text && it.text.isEmpty() }
        val attachments = objects(json.optJSONArray("attachments")).mapIndexed(::attachment)
        val refs = objects(json.optJSONArray("refs")).mapNotNull { ref ->
            ConversationRef(ref.string("conversationId") ?: return@mapNotNull null, ref.string("kind"), ref.string("title"),
                ref.string("status"), ref.string("activityStatus"))
        }
        if (parts.isEmpty() && attachments.isEmpty() && refs.isEmpty() && files.isEmpty()) return null
        return ChatMessage(
            messageId = id, seq = json.optLongOrNull("seq") ?: 0, role = if (user) ChatRole.USER else ChatRole.ASSISTANT,
            actorType = json.string("actorType") ?: if (user) "user" else "agent", agentId = json.string("actorId"),
            clientRequestId = json.string("clientRequestId"), replyToMessageId = json.string("replyToMessageId"),
            threadRootMessageId = json.string("threadRootMessageId"), createdAt = json.optLongOrNull("createdAt"),
            parts = parts, attachments = attachments, refs = refs, workspaceFiles = files,
            brief = json.optBoolean("brief"),
            createdTaskIds = objects(json.optJSONArray("createdTasks")).mapNotNull { it.string("conversationId") },
            markdown = json.optJSONArray("markdown")?.toString(),
        )
    }

    private fun part(json: JSONObject): MessagePart? = when (json.optString("kind")) {
        "markdown" -> MessagePart.Text(json.optString("text"))
        "inline-task" -> json.optJSONObject("task")?.let { task ->
            val unavailable = task.optBoolean("unavailable")
            MessagePart.TaskChip(task.string("conversationId").takeIf { !unavailable }, task.string("title"),
                task.string("status"), task.string("activityStatus"), unavailable || task.string("conversationId") == null)
        }
        "dynamic-ui" -> MessagePart.InteractiveSummary(json.string("summary"), json.string("uiRef"),
            json.optLongOrNull("version"), json.string("originTaskId"), json.optInt("attachmentIndex"))
        "device-setup-offer" -> json.optJSONObject("offer")?.let(DeviceSetupOffer::parse)?.let(MessagePart::SetupOffer)
        "question" -> AgentQuestion.parse(json)?.let(MessagePart::Question)
        // A person's answer to a question card shows as their words alone.
        "question-answer" -> null
        else -> null
    }

    /**
     * Whitespace between inline elements is content; only the message's outer edges are trimmed. A question card is
     * drawn after the text, so the text before it ends the message.
     */
    private fun trimEdges(parts: MutableList<MessagePart>) {
        (parts.firstOrNull() as? MessagePart.Text)?.let { parts[0] = MessagePart.Text(it.text.trimStart()) }
        val last = parts.indexOfLast { it !is MessagePart.Question }
        if (last >= 0 && parts[last] is MessagePart.Text) parts[last] = MessagePart.Text((parts[last] as MessagePart.Text).text.trimEnd())
    }

    private fun attachment(index: Int, json: JSONObject): MessageAttachment {
        val blob = json.optJSONObject("blobRef")?.let { ref ->
            BlobRef(ref.string("uuid") ?: return@let null, ref.string("hash") ?: return@let null, ref.optLongOrNull("size") ?: return@let null)
        }
        val served = json.optLongOrNull("attachmentIndex")?.toInt()
        return MessageAttachment(
            blockType = json.optString("blockType"), blockIndex = served ?: -(index + 1), fileName = json.string("fileName"),
            title = json.string("title"), mimeType = json.string("mimeType"), size = json.optLongOrNull("size"),
            workspacePath = json.string("workspacePath"), widthPx = json.optLongOrNull("width")?.toInt(),
            heightPx = json.optLongOrNull("height")?.toInt(), blobRef = blob, agentId = json.string("agentId")?.takeIf { blob != null },
            downloadable = served != null && blob != null,
        )
    }

    /** The core's reading of each message still being sent, by its request id: they close the `messages` list. */
    private fun pendingDisplays(messages: JSONArray?): Map<String, JSONObject> {
        val out = HashMap<String, JSONObject>()
        if (messages == null) return out
        for (index in messages.length() - 1 downTo 0) {
            val message = messages.optJSONObject(index) ?: continue
            if (message.optString("source") != "pending") break
            val id = message.string("clientRequestId") ?: continue
            message.optJSONObject("display")?.let { out[id] = it }
        }
        return out
    }

    /**
     * The passages a message quotes, then the texts it attaches (a Routine item, headed by its app's name), as Markdown
     * quotes ahead of its words.
     */
    private fun quoted(display: JSONObject?): String? {
        val attached = objects(display?.optJSONArray("texts")).mapNotNull { text ->
            val body = text.opt("text") as? String ?: return@mapNotNull null
            text.string("source")?.let { "**$it**\n\n$body" } ?: body
        }
        return (strings(display?.optJSONArray("quotes")) + attached).takeIf { it.isNotEmpty() }?.joinToString("\n\n") { quote ->
            quote.lines().joinToString("\n") { if (it.isEmpty()) ">" else "> $it" }
        }
    }

    private fun files(display: JSONObject?): List<WorkspaceFile> = objects(display?.optJSONArray("files")).mapNotNull {
        WorkspaceFile(it.string("name") ?: return@mapNotNull null, it.string("path") ?: return@mapNotNull null)
    }

    private fun pending(json: JSONObject, shown: Map<String, JSONObject>): PendingMessage? {
        val id = json.string("clientRequestId") ?: return null
        val display = shown[id]
        // A model the person named shows as `@name`, as it will once sent.
        val words = ModelMentionLinks.asWords(display?.let { d -> d.string("command")?.let { "/$it" } ?: d.optString("body") } ?: json.optString("text"))
        val text = listOfNotNull(quoted(display), words.trimEnd().takeIf { it.isNotEmpty() }).joinToString("\n\n")
        return PendingMessage(
            clientRequestId = id, text = text, workspaceFiles = files(display),
            replyToMessageId = json.string("replyToMessageId"), createdAt = json.optLong("createdAt"),
            status = if (json.optString("status") == "failed") PendingStatus.FAILED else PendingStatus.SENDING,
            error = json.string("error"), billing = json.string("failureAction") == "billing",
        )
    }

    private fun attachments(array: JSONArray?): List<DraftAttachment> = objects(array).mapNotNull { json ->
        DraftAttachment(json.string("id") ?: return@mapNotNull null, json.optString("name"), json.optLong("size"),
            when (json.optString("status")) {
                "uploaded" -> DraftAttachmentStatus.UPLOADED
                "failed" -> DraftAttachmentStatus.FAILED
                else -> DraftAttachmentStatus.UPLOADING
            }, json.string("path"), json.string("error"))
    }

    private fun objects(array: JSONArray?): List<JSONObject> =
        if (array == null) emptyList() else (0 until array.length()).mapNotNull(array::optJSONObject)

    private fun strings(array: JSONArray?): List<String> =
        if (array == null) emptyList() else (0 until array.length()).mapNotNull { array.opt(it) as? String }
}

/** The timeline key of the turn a request opens, pending or confirmed. */
internal fun requestKey(clientRequestId: String) = "r:$clientRequestId"

/** A non-blank string value; JSON null, numbers and blanks are absent. */
internal fun JSONObject.string(key: String): String? = (opt(key) as? String)?.takeIf { it.isNotBlank() }
internal fun JSONObject.optLongOrNull(key: String): Long? = when (val value = opt(key)) {
    is Int -> value.toLong()
    is Long -> value
    is Number -> value.toDouble().takeIf { it % 1.0 == 0.0 && it in -9.0e15..9.0e15 }?.toLong()
    else -> null
}
