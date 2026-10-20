package surf.comma.android.chat.live

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.ui.composer.AttachmentUploadState

/** Pass ComposerView::setAttachmentState. Collection and callbacks run on the main thread. */
internal fun ChatImageDraft.bindComposer(
    scope: CoroutineScope,
    setAttachmentState: (String, AttachmentUploadState) -> Unit,
): Job = scope.launch(Dispatchers.Main.immediate) {
    var previous = emptySet<String>()
    states.collect { current ->
        // Invalidate removed/session-expired results so a retained draft cannot remain sendable.
        (previous - current.keys).forEach { setAttachmentState(it, AttachmentUploadState.Failed) }
        current.forEach { (id, state) -> setAttachmentState(id, state) }
        previous = current.keys
    }
}
