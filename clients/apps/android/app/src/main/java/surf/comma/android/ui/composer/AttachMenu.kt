package surf.comma.android.ui.composer

import kotlin.math.min

/** The entries of the attachment panel, top to bottom. */
enum class AttachEntry { CAMERA, PHOTOS, FILES }

/**
 * What the attachment panel shows for the free attachment slots, free of Android types.
 * With no slot left every entry is disabled and a header explains why.
 */
data class AttachMenuState(val remaining: Int, val max: Int) {
    val full: Boolean get() = remaining <= 0
    val entries: List<AttachEntry> get() = AttachEntry.entries

    fun enabled(entry: AttachEntry): Boolean = !full

    companion object {
        fun of(model: ComposerModel) = AttachMenuState(model.remainingSlots, model.maxAttachments)
    }
}

/** How the system photo picker is opened for the free slots. */
sealed interface PhotoPick {
    data object None : PhotoPick
    /** The multi-select picker needs a limit above one, so a single free slot picks one photo. */
    data object Single : PhotoPick
    data class Multiple(val limit: Int) : PhotoPick

    companion object {
        /** [systemLimit] is the picker's own cap (MediaStore.getPickImagesMaxLimit on new systems). */
        fun forRemaining(remaining: Int, systemLimit: Int): PhotoPick {
            val limit = min(remaining, systemLimit)
            return when {
                limit <= 0 -> None
                limit == 1 -> Single
                else -> Multiple(limit)
            }
        }
    }
}
