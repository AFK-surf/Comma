package surf.comma.android.chat.live

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.DraftAttachment
import surf.comma.android.conversation.DraftAttachmentStatus
import surf.comma.android.media.AuthorizedHttp
import surf.comma.android.media.AuthorizedSession
import surf.comma.android.media.FileKinds
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.ImagePreprocessor
import surf.comma.android.media.PickedFileRefs
import surf.comma.android.media.UploadedImage
import surf.comma.android.media.ViewerImage
import surf.comma.android.media.requireCurrent
import surf.comma.android.media.validUploadedImagePath
import surf.comma.android.ui.Background
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerAttachment
import java.util.UUID

/**
 * The files of one composer draft. An image is made ready to send here (compressed and converted on the device) and
 * handed to the client core whole; any other file is handed over by a ref, and the app's host uploads it from where it
 * is as the core asks ([PickedFileRefs]). Either way it is then a file of the conversation's draft: the core uploads
 * it, says how its upload goes (the draft's `attachments`, the same on every client), retries it, and sends it with
 * the draft's next message.
 */
internal class ChatImageDraft(
    private val http: AuthorizedHttp,
    private val preprocessor: ImagePreprocessor,
    private val files: PickedFileRefs,
    private val scope: CoroutineScope,
    private val repository: ChatView,
    private val remember: suspend (UploadedImage, ViewerImage.Local, AuthorizedSession) -> Unit = { _, _, _ -> },
) : AutoCloseable {
    /**
     * A file of the composer: being made ready, refused by that, or the core's draft row [row] once handed over, with
     * the [image] it was made into when it is one.
     */
    private sealed interface Entry {
        val attachment: ComposerAttachment
        data class Preparing(override val attachment: ComposerAttachment, val job: Job) : Entry
        data class Unprepared(override val attachment: ComposerAttachment) : Entry
        data class InCore(override val attachment: ComposerAttachment, val row: String, val image: SentImage?) : Entry
    }

    private data class SentImage(val dimensions: ImageDimensions, val mime: String)

    private val lock = Any()
    private val entries = MutableStateFlow<Map<String, Entry>>(emptyMap())
    /** At most this many files are made ready at once; the core bounds the uploads. */
    private val preparing = Semaphore(3)
    private var session = http.session.value
    var requestId: String = UUID.randomUUID().toString()
        private set

    init {
        // Another account, or none: the files of this one's draft go (its draft in the core goes with it).
        scope.launch {
            http.session.collect { latest ->
                synchronized(lock) {
                    if (latest == session) return@synchronized
                    session = latest
                    requestId = UUID.randomUUID().toString()
                    entries.value.values.forEach { (it as? Entry.Preparing)?.job?.cancel() }
                    entries.value = emptyMap()
                }
            }
        }
    }

    /** What each of the composer's files shows: the core's word on its upload once it has it. */
    val states: Flow<Map<String, AttachmentUploadState>> = combine(entries, repository.state) { current, view ->
        val rows = view.attachments.associateBy { it.id }
        current.mapValues { (_, entry) ->
            when (entry) {
                is Entry.Preparing -> AttachmentUploadState.Pending
                is Entry.Unprepared -> AttachmentUploadState.Failed
                is Entry.InCore -> rows[entry.row].uploadState()
            }
        }
    }.distinctUntilChanged()

    fun add(items: List<ComposerAttachment>) {
        val current = http.session.value ?: return
        if (!http.isCurrent(current)) return
        if (current != synchronized(lock) { session }) return
        items.forEach { prepare(it, current) }
    }

    /** Makes the file ready and hands it to the core's draft; a failure leaves it [Entry.Unprepared] for a retry. */
    private fun prepare(attachment: ComposerAttachment, captured: AuthorizedSession) = synchronized(lock) {
        val id = attachment.id
        val job = scope.launch(Background.files, start = CoroutineStart.LAZY) {
            val next = try {
                preparing.withPermit {
                    if (attachment.file.isImage) preprocessor.prepare(attachment.uri).use { image ->
                        http.requireCurrent(captured)
                        repository.attach(image.name, image.file.readBytes())
                            ?.let { row -> Entry.InCore(attachment, row, SentImage(image.dimensions, image.format.mime)) }
                    } else {
                        val picked = attachment.file
                        val local = files.register(attachment.uri, picked.size)
                        http.requireCurrent(captured)
                        val type = picked.mimeType ?: FileKinds.openType(picked.name, null)
                        repository.attachLocalFile(local.ref, picked.name, type, local.size)
                            ?.let { row -> Entry.InCore(attachment, row, null) }
                    }
                } ?: Entry.Unprepared(attachment)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                Entry.Unprepared(attachment)
            }
            val self = coroutineContext[Job]
            val kept = synchronized(lock) {
                val now = entries.value[id]
                (session == captured && now is Entry.Preparing && now.job === self)
                    .also { if (it) entries.value = entries.value + (id to next) }
            }
            // Let go of meanwhile (removed, or another account): the core's draft lets go of it too.
            if (!kept && next is Entry.InCore) repository.removeAttachment(next.row)
        }
        entries.value = entries.value + (id to Entry.Preparing(attachment, job))
        job.start()
    }

    /** Tries a failed file again: the core uploads its row again, or it is made ready again. */
    fun retry(id: String) {
        val entry = synchronized(lock) { entries.value[id] } ?: return
        val captured = synchronized(lock) { session } ?: return
        when (entry) {
            is Entry.Unprepared -> prepare(entry.attachment, captured)
            is Entry.InCore -> scope.launch { repository.retryAttachment(entry.row) }
            is Entry.Preparing -> Unit
        }
    }

    /** The composer let go of a file: the draft lets go of it too. */
    fun remove(id: String) {
        val entry = synchronized(lock) {
            entries.value[id].also { entries.value = entries.value - id }
        } ?: return
        when (entry) {
            is Entry.Preparing -> entry.job.cancel()
            is Entry.InCore -> scope.launch { repository.removeAttachment(entry.row) }
            is Entry.Unprepared -> Unit
        }
    }

    /** Sends [text] with [attachments], once the core has uploaded every one. Retries of the send reuse its pending. */
    suspend fun send(text: String, attachments: List<ComposerAttachment>, skills: List<String> = emptyList()): Boolean {
        val captured = http.session.value ?: return false
        if (!http.isCurrent(captured)) return false
        val conversation = repository.state.value.conversationId ?: return false
        val images = if (attachments.isEmpty()) emptyList() else {
            if (captured != synchronized(lock) { session }) return false
            val rows = repository.state.value.attachments.associateBy { it.id }
            val current = synchronized(lock) { entries.value }
            attachments.mapNotNull { attachment ->
                val entry = current[attachment.id] as? Entry.InCore ?: return false
                val row = rows[entry.row]?.takeIf { it.status == DraftAttachmentStatus.UPLOADED } ?: return false
                val path = row.path ?: return false
                // An image is remembered, so the message shows it at once; another file shows from the server.
                val image = entry.image ?: return@mapNotNull null
                if (!validUploadedImagePath(path)) return false
                attachment to UploadedImage(path, row.name, row.size, image.dimensions, image.mime)
            }
        }
        images.forEach { (attachment, image) ->
            http.requireCurrent(captured)
            remember(image, ViewerImage.Local(attachment.uri, image.mimeType, image.name, image.dimensions), captured)
        }
        // The core sends the draft's uploaded files with the message.
        val sent = repository.send(text, clientRequestId = requestId, skills = skills, canSend = {
            http.isCurrent(captured) && repository.state.value.groupId == captured.id.groupId &&
                repository.state.value.conversationId == conversation
        }) ?: return false
        check(sent == requestId)
        synchronized(lock) { entries.value = entries.value - attachments.map { it.id }.toSet() }
        requestId = UUID.randomUUID().toString()
        return true
    }

    override fun close() = synchronized(lock) {
        entries.value.values.forEach { (it as? Entry.Preparing)?.job?.cancel() }
        entries.value = emptyMap()
    }
}

/** How the composer shows the core's word on a draft row's upload; a row the core no longer has failed. */
private fun DraftAttachment?.uploadState(): AttachmentUploadState = when (this?.status) {
    DraftAttachmentStatus.UPLOADING -> AttachmentUploadState.Uploading()
    DraftAttachmentStatus.UPLOADED -> AttachmentUploadState.Done
    else -> AttachmentUploadState.Failed
}
