package surf.comma.android.chat.live

import androidx.lifecycle.ViewModel
import surf.comma.android.media.AuthorizedSession
import surf.comma.android.ui.composer.ComposerAttachment

/** Local presentation only; the core still owns the draft and upload lifecycle. */
internal class DraftAttachmentPreviews : ViewModel() {
    private data class Key(val session: AuthorizedSession, val row: String)
    private val items = object : LinkedHashMap<Key, ComposerAttachment>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, ComposerAttachment>?) = size > 256
    }

    @Synchronized fun remember(session: AuthorizedSession, row: String, attachment: ComposerAttachment) {
        items[Key(session, row)] = attachment.copy(id = row)
    }

    @Synchronized fun get(session: AuthorizedSession, row: String): ComposerAttachment? = items[Key(session, row)]

    @Synchronized fun remove(session: AuthorizedSession, rows: Set<String>) {
        rows.forEach { items.remove(Key(session, it)) }
    }

    @Synchronized fun keepSession(session: AuthorizedSession?) {
        items.keys.removeAll { it.session != session }
    }
}
