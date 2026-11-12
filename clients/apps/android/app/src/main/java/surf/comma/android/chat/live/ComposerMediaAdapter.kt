package surf.comma.android.chat.live

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.ui.composer.ShownAttachment

/** Pass ComposerView::showAttachments. Collection and callbacks run on the main thread. */
internal fun ChatImageDraft.bindComposer(
    scope: CoroutineScope,
    showAttachments: (List<ShownAttachment>) -> Unit,
): Job = scope.launch(Dispatchers.Main.immediate) { shown.collect(showAttachments) }
