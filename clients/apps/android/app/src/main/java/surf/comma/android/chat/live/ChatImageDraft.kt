package surf.comma.android.chat.live

import android.net.Uri
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
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
import surf.comma.android.media.InlineMediaKind
import surf.comma.android.media.InlineMediaPolicy
import surf.comma.android.media.MediaImage
import surf.comma.android.media.MediaSource
import surf.comma.android.media.PickedFile
import surf.comma.android.media.PickedFileRefs
import surf.comma.android.media.UploadedImage
import surf.comma.android.media.ViewerImage
import surf.comma.android.media.requireCurrent
import surf.comma.android.media.validUploadedImagePath
import surf.comma.android.ui.Background
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerAttachment
import surf.comma.android.ui.composer.ShownAttachment
import java.util.UUID

/**
 * The files of one composer draft. They are the client core's: the composer shows each row of the conversation's
 * draft (its `attachments`, the same on every client) with the core's word on its upload, and the core uploads it,
 * retries it, and sends it with the draft's next message. A file picked here is made ready first: an image is
 * compressed and converted on the device and handed to the core whole; any other file is handed over by a ref, and the
 * app's host uploads it from where it is as the core asks ([PickedFileRefs]). Only the files still being made ready are
 * kept here.
 *
 * A file picked on this page keeps its own picture, and its place in the composer, across Activity recreation while its local presentation is retained. Any
 * other row shows the server's copy of an uploaded image, or else a card with its name.
 */
internal class ChatImageDraft(
    private val http: AuthorizedHttp,
    private val preprocessor: ImagePreprocessor,
    private val files: PickedFileRefs,
    private val scope: CoroutineScope,
    private val repository: ChatView,
    private val previews: DraftAttachmentPreviews = DraftAttachmentPreviews(),
    private val remember: suspend (UploadedImage, ViewerImage.Local, AuthorizedSession) -> Unit = { _, _, _ -> },
) : AutoCloseable {
    /** A file picked here that is not the core's yet: being made ready, or refused by that (to try again or remove). */
    private sealed interface Entry {
        val attachment: ComposerAttachment
        data class Preparing(override val attachment: ComposerAttachment, val job: Job) : Entry
        data class Unprepared(override val attachment: ComposerAttachment) : Entry
    }

    /** A file picked here that is a row of the core's draft now, with the [image] it was made into when it is one. */
    private data class Picked(val attachment: ComposerAttachment, val image: SentImage?)

    private data class SentImage(val dimensions: ImageDimensions, val mime: String)

    private val lock = Any()
    private val entries = MutableStateFlow<Map<String, Entry>>(emptyMap())
    /** The rows of the core's draft picked on this page, by row. Guarded by [lock]. */
    private val picked = HashMap<String, Picked>()
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
                    picked.clear()
                    previews.keepSession(latest)
                    entries.value.values.forEach { (it as? Entry.Preparing)?.job?.cancel() }
                    entries.value = emptyMap()
                }
            }
        }
    }

    /** The draft's files as the composer shows them, again each time the core's draft or a file picked here changes. */
    val shown: Flow<List<ShownAttachment>> = merge(entries, repository.state).map { shownNow() }.distinctUntilChanged()

    /** Each row of the core's draft, then each file picked here that is not the core's yet. */
    private fun shownNow(): List<ShownAttachment> = synchronized(lock) {
        val view = repository.state.value
        val rows = if (session != null && repository.isCurrent(view)) view.attachments else emptyList()
        rows.map { row -> ShownAttachment(picked[row.id]?.attachment ?: session?.let { previews.get(it, row.id) } ?: row.attachment(), row.uploadState()) } +
            entries.value.values.map { entry ->
                ShownAttachment(entry.attachment,
                    if (entry is Entry.Preparing) AttachmentUploadState.Pending else AttachmentUploadState.Failed)
            }
    }

    fun add(items: List<ComposerAttachment>) {
        val current = http.session.value?.takeIf { http.isCurrent(it) && it == synchronized(lock) { session } }
        if (current == null) {
            // No account's draft takes them: the composer shows them failed, to remove.
            synchronized(lock) { entries.value = entries.value + items.map { it.id to Entry.Unprepared(it) } }
            return
        }
        items.forEach { prepare(it, current) }
    }

    /** Makes the file ready and hands it to the core's draft; a failure leaves it [Entry.Unprepared] for a retry. */
    private fun prepare(attachment: ComposerAttachment, captured: AuthorizedSession) = synchronized(lock) {
        val id = attachment.id
        val job = scope.launch(Background.files, start = CoroutineStart.LAZY) {
            val handed = try {
                preparing.withPermit {
                    if (attachment.file.isImage) preprocessor.prepare(attachment.uri).use { image ->
                        http.requireCurrent(captured)
                        repository.attach(image.name, image.file.readBytes())
                            ?.let { row -> row to SentImage(image.dimensions, image.format.mime) }
                    } else {
                        val picked = attachment.file
                        val local = files.register(attachment.uri, picked.size)
                        http.requireCurrent(captured)
                        val type = picked.mimeType ?: FileKinds.openType(picked.name, null)
                        repository.attachLocalFile(local.ref, picked.name, type, local.size)?.let { row -> row to null }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
            val self = coroutineContext[Job]
            val kept = synchronized(lock) {
                val now = entries.value[id]
                (session == captured && now is Entry.Preparing && now.job === self).also { kept ->
                    if (!kept) return@also
                    if (handed == null) {
                        entries.value = entries.value + (id to Entry.Unprepared(attachment))
                        return@also
                    }
                    // Only rows of the draft keep their picture, so this holds no more than the draft does.
                    picked.keys.retainAll(repository.state.value.attachments.mapTo(HashSet()) { it.id })
                    picked[handed.first] = Picked(attachment, handed.second)
                    previews.remember(captured, handed.first, attachment)
                    entries.value = entries.value - id
                }
            }
            // Let go of meanwhile (removed, or another account): the core's draft lets go of it too.
            if (!kept && handed != null) repository.removeAttachment(handed.first)
        }
        entries.value = entries.value + (id to Entry.Preparing(attachment, job))
        job.start()
    }

    /** The core's row that the composer's file [id] is: one picked here keeps the id it was picked with. */
    private fun rowOf(id: String): String = synchronized(lock) {
        picked.entries.firstOrNull { it.value.attachment.id == id }?.key ?: id
    }

    /** Tries a failed file again: the core uploads its row again, or it is made ready again. */
    fun retry(id: String) {
        val captured = synchronized(lock) { session } ?: return
        when (val entry = synchronized(lock) { entries.value[id] }) {
            is Entry.Unprepared -> prepare(entry.attachment, captured)
            is Entry.Preparing -> Unit
            null -> rowOf(id).let { row -> scope.launch { repository.retryAttachment(row) } }
        }
    }

    /** The composer let go of a file: the draft lets go of it too. */
    fun remove(id: String) {
        when (val entry = synchronized(lock) { entries.value[id]?.also { entries.value = entries.value - id } }) {
            is Entry.Preparing -> entry.job.cancel()
            is Entry.Unprepared -> Unit
            null -> rowOf(id).let { row ->
                synchronized(lock) { session }?.let { previews.remove(it, setOf(row)) }
                scope.launch { repository.removeAttachment(row) }
            }
        }
    }

    /**
     * Sends [text] with [attachments], the files the composer shows: the core sends the draft's rows with it, so it
     * goes only when they are exactly these, each uploaded. Retries of the send reuse its pending.
     */
    suspend fun send(text: String, attachments: List<ComposerAttachment>, skills: List<String> = emptyList()): Boolean {
        val captured = http.session.value ?: return false
        if (!http.isCurrent(captured)) return false
        val view = repository.state.value
        val conversation = view.conversationId ?: return false
        val rows = view.attachments.associateBy { it.id }
        val sending = attachments.map { it to rowOf(it.id) }
        if (sending.mapTo(HashSet()) { it.second } != rows.keys) return false
        val images = if (sending.isEmpty()) emptyList() else {
            if (captured != synchronized(lock) { session }) return false
            val known = synchronized(lock) { HashMap(picked) }
            sending.mapNotNull { (attachment, id) ->
                val row = rows.getValue(id).takeIf { it.status == DraftAttachmentStatus.UPLOADED } ?: return false
                val path = row.path ?: return false
                // An image picked here is remembered, so the message shows it at once; another file shows from the server.
                val image = known[id]?.image ?: return@mapNotNull null
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
        synchronized(lock) { picked.keys.removeAll(rows.keys) }
        previews.remove(captured, rows.keys)
        requestId = UUID.randomUUID().toString()
        return true
    }

    override fun close() = synchronized(lock) {
        entries.value.values.forEach { (it as? Entry.Preparing)?.job?.cancel() }
        entries.value = emptyMap()
        picked.clear()
    }
}

/** How the composer shows the core's word on a draft row's upload. */
private fun DraftAttachment.uploadState(): AttachmentUploadState = when (status) {
    DraftAttachmentStatus.UPLOADING -> AttachmentUploadState.Uploading()
    DraftAttachmentStatus.UPLOADED -> AttachmentUploadState.Done
    DraftAttachmentStatus.FAILED -> AttachmentUploadState.Failed
}

/** A row of the core's draft not picked on this page: an uploaded image shows the server's copy, any other a card. */
private fun DraftAttachment.attachment(): ComposerAttachment {
    val uploaded = path?.takeIf {
        status == DraftAttachmentStatus.UPLOADED && isImage && validUploadedImagePath(it) &&
            InlineMediaPolicy.classify(name, null) == InlineMediaKind.IMAGE
    }?.let { ViewerImage.Remote(MediaImage(MediaSource.UploadedFile(it), name, null)) }
    return ComposerAttachment(id, Uri.EMPTY, PickedFile(name, null, size), uploaded)
}
