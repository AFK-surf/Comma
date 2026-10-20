package surf.comma.android.chat.live

import android.net.Uri
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import surf.comma.android.conversation.ChatView
import surf.comma.android.media.AuthorizedHttp
import surf.comma.android.media.ImagePreprocessor
import surf.comma.android.media.requireCurrent
import surf.comma.android.ui.Background

/**
 * The images people add to question cards' other answers on this page. Each is made ready on the device (compressed
 * and converted, as the composer's are) and handed to the client core as an image of that card, apart from the
 * composer's draft: the core uploads it, says how its upload goes (`questionAttachments`) and sends it with the
 * card's answer. This keeps only what the core does not: a local preview of each, and the images still being made
 * ready, for the cards to show.
 */
internal class QuestionImages(
    private val http: AuthorizedHttp,
    private val preprocessor: ImagePreprocessor,
    /** A main-thread scope that ends with the page. */
    private val scope: CoroutineScope,
    private val repository: ChatView,
    /** An image could not be made ready or handed over. */
    private val onFailed: () -> Unit = {},
) {
    private val lock = Any()
    private val mutable = MutableStateFlow(QuestionImagesShown())
    val shown: StateFlow<QuestionImagesShown> = mutable.asStateFlow()
    /** At most this many images are made ready at once; the core bounds the uploads. */
    private val preparing = Semaphore(3)
    private var session = http.session.value

    init {
        // Another account, or none: its cards' images go with it (the core drops its rows too).
        scope.launch {
            http.session.collect { latest ->
                synchronized(lock) {
                    if (latest == session) return@synchronized
                    session = latest
                    mutable.value = QuestionImagesShown()
                }
            }
        }
    }

    fun add(questionMessageId: String, uris: List<Uri>) {
        val captured = http.session.value ?: return
        if (!http.isCurrent(captured) || uris.isEmpty()) return
        if (synchronized(lock) { captured != session }) return
        uris.forEach { uri ->
            change(captured) { it.copy(preparing = it.preparing + (questionMessageId to (it.preparing[questionMessageId] ?: 0) + 1)) }
            scope.launch {
                var row: String? = null
                try {
                    row = withContext(Background.files) {
                        preparing.withPermit {
                            preprocessor.prepare(uri).use { image ->
                                http.requireCurrent(captured)
                                repository.attach(image.name, image.file.readBytes(), questionMessageId)
                            }
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    row = null
                } finally {
                    val added = row
                    change(captured) { shown ->
                        val left = (shown.preparing[questionMessageId] ?: 1) - 1
                        shown.copy(
                            preparing = if (left > 0) shown.preparing + (questionMessageId to left) else shown.preparing - questionMessageId,
                            previews = if (added != null) shown.previews + (added to uri.toString()) else shown.previews,
                        )
                    }
                }
                if (row == null && synchronized(lock) { captured == session }) onFailed()
            }
        }
    }

    fun remove(questionMessageId: String, attachmentId: String) {
        synchronized(lock) { mutable.value = mutable.value.let { it.copy(previews = it.previews - attachmentId) } }
        scope.launch { repository.removeAttachment(attachmentId, questionMessageId) }
    }

    fun retry(questionMessageId: String, attachmentId: String) {
        scope.launch { repository.retryAttachment(attachmentId, questionMessageId) }
    }

    /** Changes what is shown, unless the account it was for has gone meanwhile. */
    private fun change(captured: Any, update: (QuestionImagesShown) -> QuestionImagesShown) = synchronized(lock) {
        if (captured == session) mutable.value = update(mutable.value)
    }
}
