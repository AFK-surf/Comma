package surf.comma.android.media

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import surf.comma.android.ui.Background
import java.io.File

sealed interface MediaDownloadState {
    data object Idle : MediaDownloadState
    /** [total] is the blob ref's size when known, else the response's declared length. */
    data class Downloading(val received: Long = 0, val total: Long? = null) : MediaDownloadState {
        val progress: Float? get() = total?.takeIf { it > 0 }?.let { (received.toDouble() / it).coerceIn(0.0, 1.0).toFloat() }
    }
    data class Ready(val file: File) : MediaDownloadState
    data class Failed(val reason: Failure) : MediaDownloadState
    enum class Failure {
        /** Connection or timeout; worth retrying. */
        NETWORK,
        /** The server refused or no longer has it, or the bytes did not match their ref. */
        UNAVAILABLE,
    }
}

/**
 * One whole-file download, shared by everything showing the same attachment. Call on any thread.
 * Cancelling returns to [MediaDownloadState.Idle]; a failure waits for [start] again.
 */
interface MediaDownload {
    /** Stable for the attachment within one signed-in session; also the cover/size cache key. */
    val key: String
    val state: StateFlow<MediaDownloadState>
    fun start()
    fun cancel()
}

/** Suspends until the download is ready or stops; returns null unless it completed. */
suspend fun MediaDownload.awaitFile(): File? {
    start()
    return when (val end = state.first { it is MediaDownloadState.Ready || it is MediaDownloadState.Failed || it == MediaDownloadState.Idle }) {
        is MediaDownloadState.Ready -> end.file
        else -> null
    }
}

/**
 * Whole-file downloads (videos, file cards, saved originals, pictures) as the client core makes them (`downloads.start`
 * and its `download` topic): it decides what is read, keeps each account's files apart and bounded, and checks a file
 * against its blob ref before it shows as ready. This class shows the core's state of each file and names the file on
 * the device ([files] resolves the core's path). A session change cancels everything and drops late results.
 */
class MediaFileStore(
    private val http: AuthorizedHttp,
    private val core: CoreApi?,
    private val files: (String) -> File?,
    parentScope: CoroutineScope,
    dispatcher: CoroutineDispatcher = Background.files,
) : AutoCloseable {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]) + dispatcher)
    private val lock = Any()
    private var session: AuthorizedSession? = http.session.value
    private val entries = HashMap<String, Entry>()

    init {
        scope.launch { http.session.collect { synchronized(lock) { refreshSession() } } }
    }

    /** Null while signed out or when the attachment has nothing to download. */
    fun download(attachment: MediaAttachment): MediaDownload? = synchronized(lock) {
        refreshSession()
        val current = session ?: return null
        val source = attachment.source ?: return null
        val key = mediaCacheKey(current, source)
        entries.getOrPut(key) { Entry(key, attachment, source, current) }
    }

    override fun close() = synchronized(lock) {
        scope.cancel()
        entries.values.forEach { it.reset() }
        entries.clear()
    }

    private fun refreshSession() {
        val latest = http.session.value
        if (latest == session) return
        session = latest
        entries.values.forEach { it.reset() }
        entries.clear()
    }

    private inner class Entry(
        override val key: String,
        val attachment: MediaAttachment,
        source: MediaSource,
        val owner: AuthorizedSession,
    ) : MediaDownload {
        private val params = JSONObject().put("source", source.fileSource(owner.id.groupId))
            .put("name", FileKinds.safeFileName(attachment.fileName))
            .apply { source.ref?.let { put("expect", JSONObject().put("size", it.size).put("sha256", it.hash)) } }
        private val shown = MutableStateFlow<MediaDownloadState>(MediaDownloadState.Idle)
        override val state: StateFlow<MediaDownloadState> = shown.asStateFlow()
        @Volatile private var ended = false
        /** A start or cancel waits for the state that came of it: one whose `asked` count reached [asked]. */
        private val waiting = MutableStateFlow(false)
        @Volatile private var asked = Long.MAX_VALUE
        /** The latest state the core said, and its `asked` count. */
        @Volatile private var said: JSONObject? = null
        private val following: Job?

        init {
            // The core's state is followed while someone looks at this file, or while a call waits for its state.
            val running = core
            following = if (running == null) null else scope.launch {
                combine(shown.subscriptionCount, waiting) { looking, calling -> looking > 0 || calling }
                    .distinctUntilChanged()
                    .collectLatest { follow ->
                        if (!follow) return@collectLatest
                        val topic = JSONObject().put("topic", "download").put("source", params.getJSONObject("source").toString())
                        running.subscribe(topic) { it as? JSONObject }.collect { value ->
                            (value as? TopicValue.Value)?.value?.let(::heard)
                        }
                    }
            }
        }

        private fun heard(json: JSONObject) = synchronized(lock) {
            said = json
            if (json.optLong("asked") >= asked) waiting.value = false
            if (!waiting.value && !ended) shown.value = read(json)
        }

        private fun read(json: JSONObject): MediaDownloadState = when (json.optString("status")) {
            "downloading" -> MediaDownloadState.Downloading(json.optLong("received"),
                json.optLong("total").takeUnless { json.isNull("total") } ?: attachment.source?.declaredSize)
            "ready" -> json.optString("path").let(files)?.takeIf { it.isFile }?.let(MediaDownloadState::Ready)
                ?: MediaDownloadState.Failed(MediaDownloadState.Failure.UNAVAILABLE)
            "failed" -> MediaDownloadState.Failed(if (json.optString("failure") == "network")
                MediaDownloadState.Failure.NETWORK else MediaDownloadState.Failure.UNAVAILABLE)
            else -> MediaDownloadState.Idle
        }

        override fun start() {
            if (!live() || state.value is MediaDownloadState.Ready || state.value is MediaDownloadState.Downloading) return
            ask("downloads.start", params, MediaDownloadState.Downloading(0, attachment.source?.declaredSize))
        }

        override fun cancel() {
            if (state.value is MediaDownloadState.Downloading)
                ask("downloads.cancel", JSONObject().put("source", params.get("source")), MediaDownloadState.Idle)
        }

        /** Shows [now] at once, and the core's state again once it says what came of the call. */
        private fun ask(name: String, params: JSONObject, now: MediaDownloadState) {
            val running = core ?: return
            synchronized(lock) {
                asked = Long.MAX_VALUE
                waiting.value = true
                shown.value = now
            }
            scope.launch {
                val answer = runCatching { running.call(name, params) as? JSONObject }.getOrNull()
                synchronized(lock) {
                    asked = answer?.optLong("asked") ?: 0
                    // The state that answers it may have come before the answer.
                    said?.takeIf { it.optLong("asked") >= asked }?.let(::heard)
                    if (answer == null) waiting.value = false
                }
            }
        }

        /** The session ended: what the core says of this file is no longer shown. */
        fun reset() {
            ended = true
            following?.cancel()
            waiting.value = false
            shown.value = MediaDownloadState.Idle
        }

        private fun live() = synchronized(lock) { entries[key] === this && session == owner && http.isCurrent(owner) }
    }
}

/** [this] as the client core's `FileSource`, in [group]. */
internal fun MediaSource.fileSource(group: String): JSONObject = when (this) {
    is MediaSource.AgentResource -> JSONObject().put("source", "agent-blob").put("group", group).put("agent", agentId)
        .put("blobRef", ref.json())
    is MediaSource.MessageAttachment -> JSONObject().put("source", "attachment").put("group", group)
        .put("conversation", conversationId).put("message", messageId).put("index", index)
    is MediaSource.UploadedFile -> JSONObject().put("source", "group-file").put("group", group).put("path", path)
}

/** The blob ref a download is checked against, when the source names one. */
internal val MediaSource.ref: MediaBlobRef?
    get() = when (this) {
        is MediaSource.AgentResource -> ref
        is MediaSource.MessageAttachment -> ref
        is MediaSource.UploadedFile -> null
    }
