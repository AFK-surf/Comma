package surf.comma.android.chat.live

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ImageView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.children
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import org.robolectric.shadows.ShadowToast
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.TestSessionCore
import surf.comma.android.auth.awaitState
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.FakeChatViewCore
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.media.MediaComponents
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.ui.composer.DictationCapture
import surf.comma.android.ui.composer.DictationMicrophone
import java.io.File
import java.time.Duration
import kotlin.concurrent.thread

/**
 * The composer's draft is the client core's: its text and files come back when the activity is made again or the
 * process starts again, and stay with the account and conversation they were made for.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class ChatDraftTest {
    @get:Rule val folder = TemporaryFolder()
    private val sessions = MemorySessions()
    private val session = TestSessionCore(sessions)
    private var core = FakeChatViewCore()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var auth: AuthRepository
    private lateinit var media: MediaComponents
    private lateinit var chat: ChatView

    @Before fun start() {
        AuthGraph.install(TestAuthRepository(sessions, core = session), CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
        auth = AuthGraph.get(RuntimeEnvironment.getApplication())
        media = MediaComponents(RuntimeEnvironment.getApplication(), auth, null, "https://api.test/", scope) { null }
        runBlocking { auth.start(); auth.awaitState<AuthState.Login>() }
        signIn("alice")
        chat = mainChat()
    }

    @After fun stop() {
        chat.close()
        scope.cancel()
    }

    @Test fun `typed text stays when the activity is made again, and opens no menu`() {
        val first = Chat()
        first.type("Summarise this /")
        assertTrue("typed, the trigger opens its menu", first.menuShown())

        // Made again at once, before the typing has rested.
        val second = Chat(first.end())
        assertEquals("Summarise this /", second.field.text.toString())
        assertEquals(second.field.length(), second.field.selectionEnd)
        assertFalse("put back, the draft opens nothing", second.menuShown())
        assertEquals("Summarise this /", core.draft("chat-alice"))
        second.end()
    }

    @Test fun `typed text comes back after the process is stopped`() {
        val first = Chat()
        first.type("Remember the milk")
        rest()
        assertEquals("the core keeps it once typing rests", "Remember the milk", core.draft("chat-alice"))

        // The process ends without closing anything; the core starts again from what the device kept.
        chat = mainChat(FakeChatViewCore(core.kept).also { core = it })
        val second = Chat()
        assertEquals("Remember the milk", second.field.text.toString())
        second.end()
    }

    @Test fun `a kept draft's mentions come back as mentions and go as their links`() {
        chat.close()
        core = FakeChatViewCore(mapOf("chat-alice" to "Ask [Release notes](comma:task/tsk_1) about [GPT 5.5 · high](comma:model/gpt-5.5?effort=high)"))
        chat = mainChat()
        val screen = Chat()
        assertEquals("Ask @Release notes about @GPT 5.5 · high", screen.field.text.toString())

        screen.type(" now")
        screen.send()
        assertEquals("Ask [Release notes](comma:task/tsk_1) about [GPT 5.5 · high](comma:model/gpt-5.5?effort=high) now",
            core.sends.last().getString("text"))
        assertEquals("the send took the draft", "", core.draft("chat-alice"))
        assertEquals("", screen.field.text.toString())
        screen.end()
    }

    @Test fun `another account signed in under the same activity finds its own empty draft`() {
        val screen = Chat()
        screen.type("alice's words")
        runBlocking { auth.logout() }
        ShadowLooper.idleMainLooper()
        assertEquals("", screen.field.text.toString())
        signIn("bob")
        assertEquals("", screen.field.text.toString())
        rest()
        assertEquals("", core.draft("chat-bob"))
        screen.end()
    }

    @Test fun `a dictation under way is dropped when the field stops being its conversation's`() {
        val screen = Chat()
        screen.type("alice's words")
        val recording = screen.dictate()
        assertFalse(recording.discarded)
        runBlocking { auth.logout() }
        ShadowLooper.idleMainLooper()
        assertTrue(recording.discarded)
        screen.end()
    }

    @Test fun `a key pressed as the main chat moves to another workspace stays out of that chat's draft`() {
        runBlocking { core.call("chatView.setDraft", JSONObject().put("conversation", "chat-alice-2").put("draft", "the other chat's notes")) }
        val screen = Chat()
        screen.type("alice's words")
        rest()

        // The main chat moves on a thread of its own, as on the device; the composer shows it once the main looper runs.
        session.workspaceChat = { JSONObject().put("status", "ready").put("kept", false).put("chat", JSONObject()
            .put("workspaceId", "w-alice-2").put("groupId", "g-alice-2").put("conversationId", "chat-alice-2")) }
        thread { session.changed() }.join()
        // A key pressed before then is typed into the chat the composer still shows.
        screen.field.text.append("!")
        ShadowLooper.idleMainLooper()

        assertEquals("the other chat's notes", screen.field.text.toString())
        screen.end()
        assertEquals("the other chat's notes", core.draft("chat-alice-2"))
        assertEquals("alice's words", core.draft("chat-alice"))
    }

    @Test fun `a Task's draft stays when its dock closes and the Task opens again`() {
        val first = Chat(task = "tsk_1")
        first.type("Ship it")
        // The dock lets the Task go: its chat ends, then its conversation, with the activity still on screen.
        first.close()

        val second = Chat(task = "tsk_1")
        assertEquals("Ship it", second.field.text.toString())
        assertEquals("Ship it", core.draft("tsk_1"))
        assertEquals("the router chat's draft is its own", "", core.draft("chat-alice"))
        second.close()
    }

    @Test fun `a file shows again when the activity is made again, and the message takes exactly what is shown`() {
        val first = Chat()
        first.attach("notes.txt")
        assertEquals(listOf("notes.txt"), first.shown())

        val second = Chat(first.end())
        assertEquals(listOf("notes.txt"), second.shown())
        second.type("see attached")
        second.send()
        assertEquals(listOf("notes.txt"), sentFiles())
        assertEquals(emptyList<String>(), second.shown())
        second.end()
    }

    @Test fun `a file removed after the activity is made again does not go with the message`() {
        val first = Chat()
        first.attach("notes.txt")

        val second = Chat(first.end())
        assertEquals(listOf("notes.txt"), second.shown())
        second.remove()
        assertEquals(emptyList<String>(), second.shown())
        second.type("no files")
        second.send()
        assertEquals(emptyList<String>(), sentFiles())
        second.end()
    }

    @Test fun `a file that failed to upload shows as a card, holds the message back, and can be tried again`() {
        core.uploads = false
        runBlocking {
            core.call("chatView.attachLocalFiles", JSONObject().put("files", JSONArray().put(JSONObject()
                .put("localFileRef", "lfi1_not_at_hand").put("name", "photo.jpg").put("mediaType", "image/jpeg").put("size", 10))))
        }
        val screen = Chat()
        assertEquals(listOf("photo.jpg"), screen.shown())
        assertTrue("its name on a card, no picture", screen.card("photo.jpg"))

        screen.type("the photo")
        screen.tapSend()
        assertEquals(RuntimeEnvironment.getApplication().getString(R.string.composer_uploads_failed), ShadowToast.getTextOfLatestToast())
        assertTrue(core.sends.isEmpty())

        core.uploads = true
        screen.retry()
        screen.send()
        assertEquals(listOf("photo.jpg"), sentFiles())
        screen.end()
    }

    @Test fun `the conversation stays while a picker opened from the composer is over the app, and goes once it answered`() {
        for (task in listOf(null, "tsk_1")) {
            val screen = Chat(task = task)
            val picker = screen.pickFiles()
            screen.leave()
            assertEquals("${task ?: "the router chat"} is still shown to the core", 1, core.reading.value)
            screen.comeBack()
            screen.answer(picker, "notes.txt")
            screen.leave()
            assertEquals("left with no picker over it, ${task ?: "the router chat"} goes", 0, core.reading.value)
            screen.comeBack()
            if (task == null) screen.end() else screen.close()
        }
    }

    @Test fun `a picker still open when the activity ends holds the conversation no longer`() {
        val first = Chat()
        first.pickFiles()
        first.leave()
        assertEquals(1, core.reading.value)
        first.destroy()
        assertEquals("the process keeps the router chat's view, and nothing holds it", 0, core.reading.value)
    }

    private fun signIn(user: String) {
        session.user = user
        runBlocking {
            auth.awaitState<AuthState.Login>()
            auth.sendCode("$user@example.test")
            auth.awaitState<AuthState.Login> { it.challengeId != null }
            auth.verify("123456")
            auth.awaitState<AuthState.Connected>()
        }
        ShadowLooper.idleMainLooper()
    }

    /** Lets the typing rest, by the main looper's clock. */
    private fun rest() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(400))

    /** The router chat's view, as the process keeps it across its activities. */
    private fun mainChat(core: FakeChatViewCore = this.core) =
        ChatView(AuthConversationSessions(auth), core, io = Dispatchers.Unconfined).also { it.start() }

    /** The files of the message last sent, as the core read them out of its text. */
    private fun sentFiles(): List<String> =
        chat.state.value.timeline.filterIsInstance<TimelineEntry.Pending>().last().pending.workspaceFiles.map { it.name }

    /**
     * The router chat as MainActivity makes it in onCreate, in an activity started from [saved]; with [task], that
     * Task's chat in its dock instead, which has a view of its own.
     */
    private class HeldRecording : DictationCapture {
        override val level = 0f
        var discarded = false
        override suspend fun stop() = null
        override fun discard() { discarded = true }
    }

    private inner class Chat(saved: Bundle? = null, task: String? = null) {
        private val controller = Robolectric.buildActivity(ComponentActivity::class.java)
        private val activity: ComponentActivity = controller.get()
        private val view = task?.let {
            ChatView(AuthConversationSessions(auth), core, main = false, io = Dispatchers.Unconfined).apply { start(); open(it) }
        } ?: chat
        private val screen: LiveChatScreen

        init {
            activity.setTheme(R.style.Theme_Chat)
            // The chat's stream follows the activity, as MainActivity's onStart and onStop have it.
            activity.lifecycle.addObserver(object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) = view.setForeground(true)
                override fun onStop(owner: LifecycleOwner) = view.setForeground(false)
            })
            controller.create(saved)
            screen = LiveChatScreen(activity, view, auth.state, retrySession = {}, onOpenAccount = {}, router = task == null,
                embedded = task != null, media = media)
            activity.setContentView(screen.root)
            screen.bind()
            controller.start().postCreate(saved).resume().visible()
            ShadowLooper.idleMainLooper()
        }

        private val composer: ComposerView get() = descendants(screen.root).filterIsInstance<ComposerView>().single()
        val field: EditText get() = composer.field

        fun type(text: String) {
            field.requestFocus()
            field.text.append(text)
            ShadowLooper.idleMainLooper()
        }

        /** Taps the microphone, with a recorder that only notes being dropped. */
        fun dictate(): HeldRecording {
            shadowOf(activity).grantPermissions(android.Manifest.permission.RECORD_AUDIO)
            val recording = HeldRecording()
            composer.dictationAudio = object : DictationMicrophone {
                override suspend fun start(ended: () -> Unit) = recording
            }
            byDescription(activity.getString(R.string.composer_dictate)).performClick()
            ShadowLooper.idleMainLooper()
            return recording
        }

        fun menuShown(): Boolean {
            val title = activity.getString(R.string.composer_agent_commands)
            return descendants(screen.root).any { it is TextView && it.text == title && it.isShown }
        }

        fun shown(): List<String> = composer.attachments.map { it.file.name }

        /** Picks [name], a small text file, in the document picker. */
        fun attach(name: String) = answer(pickFiles(), name)

        /** Opens the document picker over the app; returns its request, for [answer]. */
        fun pickFiles(): Intent {
            byDescription(activity.getString(R.string.composer_attach)).performClick()
            byDescription(activity.getString(R.string.composer_attach_files)).performClick()
            return shadowOf(activity).nextStartedActivityForResult.intent
        }

        /** The picker opened with [request] picked [name], a small text file. */
        fun answer(request: Intent, name: String) {
            val file = File(folder.root, name).apply { writeText("draft notes") }
            shadowOf(activity).receiveResult(request, Activity.RESULT_OK,
                Intent().apply { clipData = ClipData.newRawUri(null, Uri.fromFile(file)) })
            ShadowLooper.idleMainLooper()
        }

        /** Something comes over the activity and hides it, as a picker does. */
        fun leave() {
            controller.pause().stop()
            ShadowLooper.idleMainLooper()
        }

        fun comeBack() {
            controller.restart().resume()
            ShadowLooper.idleMainLooper()
        }

        /** The activity ends while hidden, as the system may end it under a picker. */
        fun destroy() {
            controller.destroy()
            screen.release()
            ShadowLooper.idleMainLooper()
        }

        fun remove() {
            byDescription(activity.getString(R.string.composer_attachment_remove)).performClick()
            ShadowLooper.idleMainLooper()
        }

        fun retry() {
            byDescription(activity.getString(R.string.composer_attachment_retry)).performClick()
            ShadowLooper.idleMainLooper()
        }

        /** Whether the composer shows [name] written on a file card rather than a picture. */
        fun card(name: String): Boolean = descendants(composer).any { it is TextView && it.text == name && it.isShown } &&
            descendants(composer).filterIsInstance<ImageView>().none { (it.drawable as? BitmapDrawable)?.bitmap != null }

        fun tapSend() {
            byDescription(activity.getString(R.string.composer_send)).performClick()
            ShadowLooper.idleMainLooper()
        }

        /** Sends the draft, which the core takes. */
        fun send() {
            val before = core.sends.size
            tapSend()
            assertEquals("the core took the message", before + 1, core.sends.size)
        }

        /** The activity ends and returns what it saved. */
        fun end(): Bundle {
            val saved = Bundle()
            controller.pause().stop().saveInstanceState(saved)
            controller.destroy()
            screen.release()
            ShadowLooper.idleMainLooper()
            return saved
        }

        /** The Task's dock lets it go: its chat, then its conversation; the activity stays. */
        fun close() {
            screen.release()
            view.close()
            ShadowLooper.idleMainLooper()
            controller.pause().stop().destroy()
        }

        private fun byDescription(description: String): View =
            descendants(screen.root).single { it.contentDescription == description }
    }

    private fun descendants(view: View): Sequence<View> = sequence {
        yield(view)
        if (view is ViewGroup) view.children.forEach { yieldAll(descendants(it)) }
    }
}
