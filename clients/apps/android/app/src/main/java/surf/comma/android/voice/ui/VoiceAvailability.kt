package surf.comma.android.voice.ui

import android.content.Context
import androidx.core.content.edit

/**
 * Whether the signed-in workspace can take voice calls. Read from the backend once per process
 * when the chat first sees that workspace, and remembered on the device so the Call button is
 * there from the first frame of the next launch instead of appearing seconds later.
 */
internal object VoiceAvailability {
    /** The account and workspace read in this process; null until a read succeeds. */
    @Volatile var refreshedKey: String? = null

    /** What to show for [key], or, before the session says whose it is, for the last one seen. */
    fun cached(context: Context, key: String?): Boolean {
        val prefs = prefs(context)
        if (key != null && prefs.getString(KEY, null) != key) return false
        return prefs.getBoolean(READY, false)
    }

    fun remember(context: Context, key: String, ready: Boolean) {
        refreshedKey = key
        prefs(context).edit { putString(KEY, key).putBoolean(READY, ready) }
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("voice_availability", Context.MODE_PRIVATE)

    private const val KEY = "key"
    private const val READY = "ready"
}
