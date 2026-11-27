package surf.comma.android.people

import org.robolectric.shadows.ShadowDialog
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.ConversationScope
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.TestSessionCore
import surf.comma.android.auth.awaitState
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.conversation.ChatView
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError
import surf.comma.android.miniapps.MiniAppRuntimes
import surf.comma.android.settings.desktop.WorkspaceScope
import surf.comma.android.shell.AppShell
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * People in the shell, against the test core: the tab lists everyone by name, a person opens with both ways to work
 * with them, Collaborate starts a Task with them, and an invitation waits in the Inbox and joins the host's Task.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "en-w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PeopleShellTest {
    private val now = 1_800_000_000L
    private val maya = JSONObject().put("id", "maya").put("name", "Maya Chen").put("email", "maya@example.com")

    private fun request() = JSONObject().put("id", "req-1").put("title", "Review the venue contract")
        .put("content", "Please check the cancellation terms before we sign tomorrow.")
        .put("status", "pending").put("created_at", now - 7_200).put("sender", maya)

    private fun sentRequest() = JSONObject().put("id", "sent-1").put("title", "Book the Kyoto train tickets")
        .put("content", "Please book two morning seats on the Nozomi from Tokyo to Kyoto.")
        .put("status", "accepted").put("task_status", "completed")
        .put("reply", "Booked the 09:15 Nozomi from Tokyo Station.")
        .put("created_at", now - 86_400).put("task_updated_at", now - 1_800)
        .put("workspace", JSONObject().put("id", "maya-w").put("name", "Maya's workspace").put("owner", maya))

    private fun taskRequests(workspace: String) = JSONObject()
        .put("workspace", workspace)
        .put("incoming", JSONArray().put(request()))
        .put("received", JSONArray().put(request()))
        .put("sent", JSONArray().put(sentRequest()))
        .put("grants", JSONArray())
        .put("targets", JSONArray().put(JSONObject().put("grant_id", "target-maya")
            .put("workspace", JSONObject().put("id", "maya-w").put("name", "Maya's workspace").put("owner", maya))
            .put("daily_limit", 10).put("pending_limit", 5).put("sent_today", 1).put("pending", 0)))
        .put("links", JSONArray()).put("own", "review").put("error", false)
        .put("people", JSONArray()
            .put(JSONObject().put("id", "maya").put("name", "Maya Chen").put("email", "maya@example.com")
                .put("sends", JSONObject().put("grant", "grant-maya").put("mode", "review"))
                .put("receives", JSONArray().put(JSONObject().put("grant", "target-maya").put("workspace", "maya-w").put("full", false))))
            .put(JSONObject().put("id", "sam").put("name", "Sam Rivera").put("email", "sam@example.com")
                .put("sends", JSONObject().put("grant", "grant-sam").put("mode", "auto_accept")).put("receives", JSONArray()))
            .put(JSONObject().put("id", "ana").put("name", "Ana Souza").put("email", "ana@example.com")
                .put("receives", JSONArray().put(JSONObject().put("grant", "target-ana").put("workspace", "ana-w").put("full", false)))))

    private val collaborations = JSONObject().put("error", false).put("items", JSONArray().put(JSONObject()
        .put("id", "invite-1").put("status", "invited").put("title", "Pick the dinner place for Friday")
        .put("task", JSONObject().put("id", "kyoto").put("group_id", "host-g").put("workspace_id", "maya-w"))
        .put("host", maya)
        .put("members", JSONArray().put(JSONObject().put("person", JSONObject().put("id", "sam").put("name", "Sam Rivera")).put("status", "active")))
        .put("invited_at", now - 600)))

    @Test fun `People lists everyone, a person offers both ways, and Collaborate starts a Task with them`() = shell { activity, shell, core, store ->
        activity.findViewById<View>(R.id.tab_people).performClick()
        settle(40)
        shoot(shell, "people-01-list")
        val names = shell.descendants.filterIsInstance<TextView>().filter { it.isShown }.map { it.text.toString() }
        assertTrue("everyone by name, alphabetically", names.indexOf("Ana Souza") in 0 until names.indexOf("Maya Chen"))

        // The row takes the press, not its name.
        (shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Maya Chen" }.parent.parent as View).performClick()
        settle(60)
        shoot(shell, "people-02-person")
        assertTrue(activity.findViewById<View>(R.id.people_collaborate).isShown)
        assertTrue("Maya takes requests", activity.findViewById<View>(R.id.people_request).isShown)

        activity.findViewById<View>(R.id.people_request).performClick()
        settle(60)
        shoot(activity.window.decorView, "people-06-request")
        activity.onBackPressedDispatcher.onBackPressed()
        settle(60)

        activity.findViewById<View>(R.id.people_collaborate).performClick()
        settle(60)
        val field = (activity.window.decorView as android.view.ViewGroup).descendants.filterIsInstance<android.widget.EditText>()
            .first { it.isShown && it.hint == activity.getString(R.string.people_compose_placeholder) }
        field.setText("Plan our offsite in Kyoto")
        settle(10)
        shoot(activity.window.decorView, "people-03-collaborate")
        activity.findViewById<View>(R.id.people_start).performClick()
        settle(60)
        val started = core.calls.last { it.first == "collaborations.start" }.second
        assertEquals("maya", started.getJSONArray("people").getString(0))
        assertEquals("Plan our offsite in Kyoto", started.getString("content"))
        assertEquals("the new Task opens", "collab-1", store.openTask.value.id)
    }

    @Test fun `an invitation waits in the Inbox and joining opens the host's Task through its Group`() = shell { activity, shell, core, store ->
        activity.findViewById<View>(R.id.tab_inbox).performClick()
        settle(40)
        shoot(shell, "people-04-inbox")
        activity.findViewById<View>(R.id.people_invitation).performClick()
        settle(60)
        shoot(activity.window.decorView, "people-05-invitation")
        (activity.window.decorView as android.view.ViewGroup).descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Join" }.performClick()
        settle(60)
        assertEquals("accept", core.calls.last { it.first == "collaborations.answer" }.second.getString("answer"))
        assertEquals("kyoto", store.openTask.value.id)
        assertEquals("the host's Group", "host-g", store.openTask.value.group)
    }

    @Test fun `InvitationSheet ignores double tap while in flight and restores buttons on failure`() = shell { activity, _, core, _ ->
        val gate = CompletableDeferred<Unit>()
        var attempts = 0
        core.answer = { name, _ ->
            when (name) {
                "collaborations.answer" -> {
                    attempts++
                    gate.await()
                    throw CoreError("failed", "Try again")
                }
                else -> null
            }
        }
        activity.findViewById<View>(R.id.tab_inbox).performClick()
        settle(40)
        activity.findViewById<View>(R.id.people_invitation).performClick()
        settle(60)
        val join = (activity.window.decorView as android.view.ViewGroup).descendants.filterIsInstance<TextView>()
            .first { it.isShown && it.text == "Join" }
        val decline = (activity.window.decorView as android.view.ViewGroup).descendants.filterIsInstance<TextView>()
            .first { it.isShown && it.text == "Decline" }
        join.performClick()
        join.performClick()
        settle(5)
        assertEquals("rapid double tap sends only one answer", 1, attempts)
        assertFalse(join.isEnabled)
        assertFalse(decline.isEnabled)
        gate.complete(Unit)
        settle(40)
        assertTrue("join restored after failure", join.isEnabled)
        assertTrue("decline restored after failure", decline.isEnabled)
        assertEquals(1f, join.alpha, 0.01f)
    }

    @Test fun `PersonPage opens RequestDetailPage when tapping a pending request row`() = shell { activity, shell, _, _ ->
        activity.findViewById<View>(R.id.tab_people).performClick()
        settle(40)
        (shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Maya Chen" }.parent.parent as View).performClick()
        settle(60)
        val row = shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Review the venue contract" }.parent.parent as View
        row.performClick()
        settle(60)
        shoot(shell, "people-09-incoming-request")
        val accept = shell.descendants.filterIsInstance<TextView>().firstOrNull {
            it.isShown && it.text == activity.getString(R.string.ds_requests_accept)
        }
        val decline = shell.descendants.filterIsInstance<TextView>().firstOrNull {
            it.isShown && it.text == activity.getString(R.string.ds_requests_decline)
        }
        assertTrue("RequestDetailPage shows Create task action for pending incoming request", accept != null)
        assertTrue("RequestDetailPage shows Decline action for pending incoming request", decline != null)
        decline!!.performClick()
        settle(40)
        val dialog = ShadowDialog.getLatestDialog()
        assertTrue("Tapping Decline opens the decline reason dialog", dialog != null && dialog.isShowing)
        val dialogRoot = dialog!!.window!!.decorView
        dialogRoot.measure(
            View.MeasureSpec.makeMeasureSpec(shell.width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(shell.height, View.MeasureSpec.EXACTLY),
        )
        dialogRoot.layout(0, 0, shell.width, shell.height)
        shoot(dialogRoot, "people-10-decline-dialog")
        val confirm = dialogRoot.findViewById<TextView>(R.id.settings_dialog_confirm)
        assertTrue("Decline dialog allows declining without typing a reason", confirm != null && confirm.isEnabled)
        val reasonInput = (dialogRoot as android.view.ViewGroup).descendants.filterIsInstance<android.widget.EditText>().first()
        reasonInput.setText("中".repeat(334))
        assertEquals("Decline reason clamps 3-byte CJK input to 1000 UTF-8 bytes", 333, reasonInput.text.length)
        assertTrue(reasonInput.text.toString().toByteArray(Charsets.UTF_8).size <= 1000)
        reasonInput.setText("😀".repeat(251))
        assertEquals("Decline reason clamps 4-byte emoji input without splitting surrogate pairs", 500, reasonInput.text.length)
        assertEquals(1000, reasonInput.text.toString().toByteArray(Charsets.UTF_8).size)
        dialog.dismiss()
    }

    @Test fun `RequestDetailPage reads updated status from received when request leaves incoming`() = shell { activity, shell, core, _ ->
        val declined = request().put("status", "declined").put("decline_reason", "Not this week")
        core.topics = { topic ->
            when (topic.getString("topic")) {
                "taskRequests" -> taskRequests(topic.optString("prefer"))
                    .put("incoming", JSONArray())
                    .put("received", JSONArray().put(declined))
                "collaborations" -> collaborations
                else -> null
            }
        }
        activity.findViewById<View>(R.id.tab_people).performClick()
        settle(40)
        (shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Maya Chen" }.parent.parent as View).performClick()
        settle(60)
        val peopleField = AppShell::class.java.getDeclaredField("people").apply { isAccessible = true }
        val tab = peopleField.get(shell) as PeopleTab
        val personPage = tab.host.pages().filterIsInstance<PersonPage>().first()
        val modelField = PersonPage::class.java.getDeclaredField("model").apply { isAccessible = true }
        val model = modelField.get(personPage) as PeopleModel
        // Pass a stale pending snapshot while the topic already moved req-1 out of incoming into received as declined.
        tab.open(surf.comma.android.settings.desktop.RequestDetailPage(tab, model.requests, request(), incoming = true))
        settle(60)
        val shown = shell.descendants.filterIsInstance<TextView>().filter { it.isShown }.map { it.text.toString() }
        assertFalse("RequestDetailPage must not keep showing Accept once declined in received",
            shown.contains(activity.getString(R.string.ds_requests_accept)))
        assertTrue("RequestDetailPage shows Declined status from received",
            shown.contains(activity.getString(R.string.ds_requests_declined)))
        assertTrue("RequestDetailPage shows decline reason from received",
            shown.contains("Not this week"))
    }

    @Test fun `WorkspaceScope onChange unsubscribes cleanly`() = shell { activity, _, core, _ ->
        val auth = AuthGraph.get(activity)
        val sessions = AuthConversationSessions(auth)
        val session = sessions.scopes.value!!
        val scope = WorkspaceScope(core, sessions, session, CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
        var calls = 0
        val unlisten = scope.onChange { calls++ }
        scope.changed()
        assertEquals(1, calls)
        unlisten()
        scope.changed()
        assertEquals("removed listener is not called again", 1, calls)
        scope.close()
    }

    @Test fun `CollaborateSheet typing does not reload cached recipient avatars`() = shell { activity, shell, core, _ ->
        PersonAvatarView.clearCache()
        val png = ByteArrayOutputStream().also { out ->
            Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, out)
        }.toByteArray()
        val avatarSource = JSONObject().put("id", "avatar-maya")
        core.topics = { topic ->
            when (topic.getString("topic")) {
                "taskRequests" -> taskRequests(topic.optString("prefer")).also { tr ->
                    tr.getJSONArray("people").getJSONObject(0).put("avatar", avatarSource)
                }
                "collaborations" -> collaborations
                else -> null
            }
        }
        var reads = 0
        core.answer = { name, _ ->
            when (name) {
                "files.read" -> { reads++; JSONObject().put("bytes", CoreBytes.json(png)) }
                else -> null
            }
        }
        activity.findViewById<View>(R.id.tab_people).performClick()
        settle(40)
        (shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Maya Chen" }.parent.parent as View).performClick()
        settle(60)
        activity.findViewById<View>(R.id.people_collaborate).performClick()
        settle(60)
        val beforeTyping = reads
        assertTrue("avatar was read at least once", beforeTyping >= 1)
        val field = (activity.window.decorView as android.view.ViewGroup).descendants.filterIsInstance<android.widget.EditText>()
            .first { it.isShown && it.hint == activity.getString(R.string.people_compose_placeholder) }
        field.setText("P")
        field.setText("Pl")
        field.setText("Plan our offsite")
        settle(20)
        assertEquals("typing does not trigger extra files.read", beforeTyping, reads)
    }

    @Test fun `peopleSectionLetter folds Latin diacritics and groups non-Latin under hash`() {
        assertEquals('E', peopleSectionLetter("Élodie"))
        assertEquals('A', peopleSectionLetter("alice"))
        assertEquals('#', peopleSectionLetter("张三"))
        assertEquals('#', peopleSectionLetter("123"))
        val ordered = listOf("张三", "Zoe", "Élodie", "123", "Alice")
            .groupBy(::peopleSectionLetter).entries
            .sortedWith(compareBy<Map.Entry<Char, List<String>>> { it.key == '#' }.thenBy { it.key })
            .map { it.key }
        assertEquals(listOf('A', 'E', 'Z', '#'), ordered)
    }

    @Test fun `TaskStatusBucket fromTaskStatus maps raw server statuses`() {
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.DONE, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("completed"))
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.NEEDS_REVIEW, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("ready_for_review"))
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.NEEDS_REVIEW, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("escalated"))
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.CANCELLED, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("failed"))
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.CANCELLED, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("cancelled"))
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.IN_PROGRESS, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("active"))
        assertEquals(surf.comma.android.tasks.TaskStatusBucket.ARCHIVED, surf.comma.android.tasks.TaskStatusBucket.fromTaskStatus("archived"))
    }

    @Test fun `sent request reflects task_status and RequestDetailPage deletes after confirmation`() = shell { activity, shell, core, _ ->
        core.answer = { name, _ ->
            when (name) {
                "taskRequests.hide" -> JSONObject()
                else -> null
            }
        }
        activity.findViewById<View>(R.id.tab_people).performClick()
        settle(40)
        (shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Maya Chen" }.parent.parent as View).performClick()
        settle(60)
        val personTexts = shell.descendants.filterIsInstance<TextView>().filter { it.isShown }.map { it.text.toString() }
        assertTrue("PersonPage shows completed task_status instead of Accepted", personTexts.contains("Your request · Done"))

        val sentRow = shell.descendants.filterIsInstance<TextView>().first { it.isShown && it.text == "Book the Kyoto train tickets" }.parent.parent as View
        sentRow.performClick()
        settle(60)
        shoot(shell, "people-07-sent-request")
        val detailTexts = shell.descendants.filterIsInstance<TextView>().filter { it.isShown }.map { it.text.toString() }
        assertTrue("RequestDetailPage shows Done status", detailTexts.contains("Done"))
        assertTrue("RequestDetailPage shows reply", detailTexts.contains("Booked the 09:15 Nozomi from Tokyo Station."))

        val more = activity.findViewById<View>(R.id.request_detail_more)
        assertTrue("RequestDetailPage shows trailing more button for decided sent request", more.isShown)
        more.performClick()
        settle(30)
        val menuRoots = listOfNotNull(
            activity.window.decorView as? android.view.ViewGroup,
            org.robolectric.Shadows.shadowOf(activity.application).latestPopupWindow?.contentView as? android.view.ViewGroup,
        )
        val deleteItem = menuRoots.flatMap { it.descendants.filterIsInstance<TextView>().toList() }
            .first { it.isShown && it.text.toString() == activity.getString(R.string.ds_requests_delete_request) }
        (deleteItem.parent as View).performClick()
        settle(30)

        val dialog = org.robolectric.shadows.ShadowDialog.getLatestDialog()
        val dialogRoot = dialog.window!!.decorView as android.view.ViewGroup
        val dialogTexts = dialogRoot.descendants.filterIsInstance<TextView>().filter { it.isShown }.map { it.text.toString() }
        assertTrue("Confirmation dialog asks before deleting", dialogTexts.contains(activity.getString(R.string.ds_requests_delete_title)))
        assertTrue("Confirmation dialog explains cross-device removal", dialogTexts.contains(activity.getString(R.string.ds_requests_delete_description)))
        shoot(dialogRoot, "people-08-delete-confirm")

        assertTrue("hide not called before confirming", core.calls.none { it.first == "taskRequests.hide" })
        dialogRoot.descendants.filterIsInstance<TextView>()
            .first { it.isShown && it.text.toString() == activity.getString(R.string.ds_requests_delete_request) }
            .performClick()
        settle(60)
        val hideCall = core.calls.lastOrNull { it.first == "taskRequests.hide" }
        assertTrue("taskRequests.hide called after confirmation", hideCall != null)
        assertEquals("sent-1", hideCall!!.second.getString("request"))
    }

    private fun shell(check: (ComponentActivity, AppShell, TestSessionCore, WorkspaceStore) -> Unit) =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Chat) }
            controller.create()
            val sessions = MemorySessions()
            val core = TestSessionCore(sessions)
            core.topics = { topic ->
                when (topic.getString("topic")) {
                    "taskRequests" -> taskRequests(topic.optString("prefer"))
                    "collaborations" -> collaborations
                    else -> null
                }
            }
            core.answer = { name, _ ->
                when (name) {
                    "collaborations.start" -> JSONObject().put("task", JSONObject().put("id", "collab-1").put("group_id", "g-alice"))
                    "collaborations.answer" -> JSONObject()
                    else -> null
                }
            }
            AuthGraph.install(TestAuthRepository(sessions, core = core), CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), core)
            val auth = AuthGraph.get(activity)
            val runtimesAuth = MiniAppRuntimes::class.java.getDeclaredField("auth").apply { isAccessible = true }
            val earlier = runtimesAuth.get(MiniAppRuntimes)
            runtimesAuth.set(MiniAppRuntimes, auth)
            runBlocking {
                auth.start()
                auth.awaitState<AuthState.Login>()
                auth.sendCode("alice@example.test")
                auth.awaitState<AuthState.Login> { it.challengeId != null }
                auth.verify("123456")
                auth.awaitState<AuthState.Connected>()
            }
            val chat = ChatView(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val screen = LiveChatScreen(activity, chat, auth.state, retrySession = {}, onOpenAccount = {}, router = true)
            val tasks = ServerTaskRepository(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val store = WorkspaceStore(activity, auth, tasks, CommaApi(null))
            val shell = AppShell(activity, screen, chat, store)
            activity.setContentView(shell)
            controller.start().resume().visible()
            try {
                settle(30)
                // A signed-in launch opens the router chat; the member goes back to the tabs.
                activity.onBackPressedDispatcher.onBackPressed()
                settle(40)
                check(activity, shell, core, store)
            } finally {
                shell.release()
                runtimesAuth.set(MiniAppRuntimes, earlier)
                screen.release()
                chat.close()
                tasks.close()
            }
        }

    private fun settle(frames: Int) = repeat(frames) { ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS) }

    /** Writes [view] as drawn to `$COMMA_SHOTS`, for looking at it; nothing when unset. */
    private fun shoot(view: View, name: String) {
        val dir = System.getenv("COMMA_SHOTS") ?: return
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        File(dir).mkdirs()
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
