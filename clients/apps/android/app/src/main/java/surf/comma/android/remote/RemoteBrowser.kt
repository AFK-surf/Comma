package surf.comma.android.remote

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import surf.comma.android.core.TopicValue
import surf.comma.android.workspace.WorkspaceCalls
import java.util.Base64
import java.util.UUID

/**
 * One viewer of the browser an Agent runs for a conversation, as the iOS app's: the `sessionBrowser` topic says which
 * browser the participant has, the `browserView` topic streams its frames and tabs to this [viewer], and the
 * `browserView.*` calls switch tabs, hand control over, and send taps, text and navigation keys while the member has
 * control. The core bounds its input queue (32 events); this sends at most two events per action and never polls.
 *
 * [viewer] names this viewer to the core; the dock passes it back after the activity is recreated (a rotation), so the
 * same viewer goes on. [onChange] runs on the main thread after every change the page shows.
 */
class RemoteBrowser(
    private val calls: WorkspaceCalls,
    val conversation: String,
    initialParticipant: String,
    val viewer: String = UUID.randomUUID().toString(),
) {
    var onChange: () -> Unit = {}
    var participant: String = initialParticipant
        private set
    var binding: JSONObject? = null; private set
    var value: JSONObject? = null; private set
    var loaded = false; private set
    var image: Bitmap? = null; private set
    var error: String? = null; private set
    var busy = false; private set
    private var seq = -1L
    private var inputBusy = false
    private var scope: CoroutineScope? = null
    private var owner: Any? = null
    private var following: Job? = null
    private var frames: Job? = null
    private var framesFor: String? = null

    val current: Boolean get() = calls.current
    val workspaceId: String get() = calls.workspaceId
    val browserId: String get() = (binding?.optString("agent_id").orEmpty()) + "/" + (binding?.optString("session_id").orEmpty())
    val controlling: Boolean get() = value?.optBoolean("controlling") == true

    /** The browser's address for the view calls; null while the participant runs none. */
    val ref: JSONObject?
        get() {
            val binding = binding ?: return null
            val agent = binding.optString("agent_id").takeIf(String::isNotEmpty) ?: return null
            val session = binding.optString("session_id").takeIf(String::isNotEmpty) ?: return null
            return JSONObject().put("workspace", calls.workspaceId).put("agent", agent).put("session", session).put("viewer", viewer)
        }

    /** The browser's tabs: id and title (the address when untitled). */
    val tabs: List<Pair<String, String>>
        get() {
            val array = value?.optJSONArray("tabs") ?: return emptyList()
            return (0 until array.length()).mapNotNull { index ->
                val tab = array.optJSONObject(index) ?: return@mapNotNull null
                val id = tab.optString("tab_id")
                id to (tab.optString("title").takeIf(String::isNotEmpty) ?: tab.optString("url"))
            }
        }
    val tab: String get() = value?.optString("tab").orEmpty()
    val connectionFailed: Boolean get() = value?.let { it.has("error") && !it.isNull("error") } == true

    /**
     * Starts following while [owner] (a page) shows this viewer. The viewer moves between a sheet and the column
     * beside the conversation: the page it left stopping later does not stop the one now showing it.
     */
    fun start(owner: Any, scope: CoroutineScope) {
        if (this.owner === owner) return
        stop()
        this.owner = owner
        this.scope = scope
        follow()
    }

    /** Lets the topics go; with [owner], only while that page is the one showing the viewer. */
    fun stop(owner: Any? = null) {
        if (owner != null && owner !== this.owner) return
        following?.cancel(); following = null
        frames?.cancel(); frames = null; framesFor = null
        scope = null
        this.owner = null
    }

    /** The Task's bound participant changed: the viewer starts over on the new one's browser. */
    fun setParticipant(next: String) {
        if (next == participant) return
        participant = next
        binding = null; value = null; image = null; seq = -1; loaded = false; error = null
        frames?.cancel(); frames = null; framesFor = null
        onChange()
        follow()
    }

    private fun follow() {
        val scope = scope ?: return
        following?.cancel()
        if (participant.isEmpty()) { loaded = true; onChange(); return }
        val mine = participant
        val topic = JSONObject().put("topic", "sessionBrowser").put("workspace", calls.workspaceId)
            .put("conversation", conversation).put("participant", mine)
        following = scope.launch {
            calls.subscribe(topic) { it as? JSONObject }.collect { update ->
                if (!calls.current || participant != mine) return@collect
                when (update) {
                    is TopicValue.Value -> {
                        loaded = update.value != null
                        binding = update.value?.optJSONObject("browser")
                    }
                    is TopicValue.Failed -> { loaded = true; error = WorkspaceCalls.message(update.error) }
                }
                watchFrames()
                onChange()
            }
        }
    }

    private fun watchFrames() {
        val scope = scope ?: return
        val id = browserId
        if (id == framesFor && frames?.isActive == true) return
        frames?.cancel()
        framesFor = id
        value = null; image = null; seq = -1
        val topic = ref?.put("topic", "browserView") ?: return
        frames = scope.launch {
            calls.subscribe(topic) { it as? JSONObject }.collect { update ->
                if (!calls.current || browserId != id) return@collect
                when (update) {
                    is TopicValue.Value -> {
                        val next = update.value
                        value = next
                        val frame = next?.optJSONObject("frame")
                        if (frame == null) { image = null; seq = -1 }
                        else if (frame.has("seq") && frame.optLong("seq") != seq) {
                            seq = frame.optLong("seq")
                            val data = frame.optString("data")
                            if (data.isNotEmpty() && data.length <= MAX_FRAME_CHARS) {
                                image = withContext(Dispatchers.Default) { decode(data) } ?: image
                            }
                        }
                    }
                    is TopicValue.Failed -> error = WorkspaceCalls.message(update.error)
                }
                onChange()
            }
        }
    }

    suspend fun command(operation: String) {
        val params = ref?.put("operation", operation) ?: return
        perform("browserView.command", params)
    }

    suspend fun select(tab: String) {
        val params = ref?.put("tab", tab) ?: return
        perform("browserView.selectTab", params)
    }

    suspend fun reconnect() {
        perform("browserView.reconnect", ref ?: return)
    }

    private suspend fun perform(name: String, params: JSONObject) {
        if (!calls.current || busy) return
        busy = true
        error = null
        onChange()
        try {
            calls.call(name, params)
        } catch (cancel: CancellationException) {
            return
        } catch (failure: Exception) {
            if (calls.current) error = WorkspaceCalls.message(failure)
        } finally {
            busy = false
            onChange()
        }
    }

    /**
     * Sends input only while the member has control, at most two events, one action at a time. True once all of it
     * was sent; false when it was not sent (no control, another action still sending) or a call failed.
     */
    suspend fun input(events: List<JSONObject>): Boolean {
        val ref = ref ?: return false
        if (!controlling || inputBusy) return false
        inputBusy = true
        try {
            for (event in events.take(2)) calls.call("browserView.input", JSONObject(ref.toString()).put("input", event))
            return true
        } catch (cancel: CancellationException) {
            return false
        } catch (failure: Exception) {
            if (calls.current) { error = WorkspaceCalls.message(failure); onChange() }
            return false
        } finally {
            inputBusy = false
        }
    }

    /** A tap at ([x], [y]) as fractions of the frame shown. */
    suspend fun tap(x: Double, y: Double) {
        val frame = value?.optJSONObject("frame") ?: return
        input(tapEvents(x, y, frame.optDouble("width"), frame.optDouble("height")) ?: return)
    }

    /** Types [text] into the page; true once it was sent, so the page can let it go. */
    suspend fun type(text: String): Boolean = text.isNotEmpty() && input(listOf(JSONObject().put("type", "text").put("text", text)))

    suspend fun key(key: NavigationKey) { input(key.events()) }

    /** The keys the page offers, as the browser names them. */
    enum class NavigationKey(val key: String, val keyCode: Int) {
        TAB("Tab", 9), ENTER("Enter", 13), ESCAPE("Escape", 27), PAGE_UP("PageUp", 33), PAGE_DOWN("PageDown", 34);

        fun events(): List<JSONObject> = listOf("keyDown", "keyUp").map { type ->
            JSONObject().put("type", type).put("key", key).put("code", key).put("keyCode", keyCode).put("modifiers", 0)
        }
    }

    companion object {
        /** The longest frame read: 12 MiB of base64. */
        const val MAX_FRAME_CHARS = 12 * 1024 * 1024

        /** A left click at a point given as fractions of a frame [width] by [height], clamped into it. */
        fun tapEvents(x: Double, y: Double, width: Double, height: Double): List<JSONObject>? {
            if (width.isNaN() || height.isNaN() || width <= 0 || height <= 0) return null
            val px = x.coerceIn(0.0, 1.0) * width
            val py = y.coerceIn(0.0, 1.0) * height
            return listOf("mousePressed", "mouseReleased").map { type ->
                JSONObject().put("type", type).put("x", px).put("y", py).put("button", "left").put("clickCount", 1).put("modifiers", 0)
            }
        }

        private fun decode(data: String): Bitmap? = runCatching {
            val bytes = Base64.getMimeDecoder().decode(data)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull()
    }
}
