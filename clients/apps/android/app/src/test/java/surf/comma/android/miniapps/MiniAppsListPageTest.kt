package surf.comma.android.miniapps

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.flowOf
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
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
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.Workspace
import surf.comma.android.auth.awaitState
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.workspace.WorkspaceStore
import java.io.File
import java.util.concurrent.TimeUnit

/** The Apps list's empty and failed states, placed as on iOS. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MiniAppsListPageTest {
    /** The Workspace's apps topic, answering [value] once. */
    private class AppsCore(private val value: JSONObject) : CoreApi {
        override suspend fun call(name: String, params: JSONObject): Any? = null
        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = flowOf(TopicValue.Value(read(value)))
    }

    private data class Shown(val activity: ComponentActivity, val page: MiniAppsListPage, val layout: SettingsPageLayout, val asked: List<String>)

    /** The list page on [value], signed in, laid out under [bottom] px of shell below it, then given [bottomAfter]. */
    private fun shown(value: JSONObject, bottomDp: Int, bottomAfterDp: Int, check: (Shown) -> Unit) =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Chat) }
            controller.setup()
            // A signed-in scope, so the list follows its topic rather than loading.
            AuthGraph.install(TestAuthRepository(MemorySessions()), CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
            val auth = AuthGraph.get(activity)
            runBlocking {
                auth.start()
                auth.sendCode("alice@example.test")
                auth.awaitState<AuthState.Login> { it.challengeId != null }
                auth.verify("123456")
                auth.awaitState<AuthState.Connected>()
            }
            // The page opens under the scope the runtimes follow: this test's session, whatever ran before.
            val runtimesAuth = MiniAppRuntimes::class.java.getDeclaredField("auth").apply { isAccessible = true }
            val earlier = runtimesAuth.get(MiniAppRuntimes)
            runtimesAuth.set(MiniAppRuntimes, auth)
            val asked = mutableListOf<String>()
            val ctx = object : MiniAppsContext {
                override val activity = activity
                override val core: CoreApi = AppsCore(value)
                override val store: WorkspaceStore get() = error("not used by the list")
                override fun open(page: SettingsPage) = Unit
                override fun back() = Unit
                override fun toast(text: String, failure: Boolean) = Unit
                override fun newApp(prompt: String) { asked += prompt }
            }
            val page = MiniAppsListPage(ctx, Workspace("wsp", "grp", "Team"))
            val layout = page.view as SettingsPageLayout
            try {
                val density = activity.resources.displayMetrics.density
                layout.applyInsets((24 * density).toInt(), (bottomDp * density).toInt())
                activity.setContentView(FrameLayout(activity).apply { addView(layout) })
                page.setFollowing(true)
                settle()
                // The shell reserves its bars once they are laid out: only the bottom inset changes.
                layout.applyInsets((24 * density).toInt(), (bottomAfterDp * density).toInt())
                settle()
                check(Shown(activity, page, layout, asked))
            } finally {
                page.setFollowing(false)
                runtimesAuth.set(MiniAppRuntimes, earlier)
            }
        }

    private fun visibleStates(layout: SettingsPageLayout) = layout.descendants.filterIsInstance<EmptyStateView>().filter { it.isShown }.toList()

    @Test fun `with no apps, the empty state and New app sit in the middle of the page under a bare bar`() =
        shown(JSONObject().put("status", "ready").put("apps", JSONArray()), bottomDp = 0, bottomAfterDp = 200) { (activity, _, layout, asked) ->
            shoot(layout, "apps-empty")
            val density = activity.resources.displayMetrics.density
            val empty = visibleStates(layout).single()
            val emptyAt = IntArray(2).also(empty::getLocationInWindow)[1]
            val barBottom = IntArray(2).also(layout.bar::getLocationInWindow)[1] + layout.bar.height
            val roomCentre = (barBottom + layout.height - 200 * density) / 2f
            assertEquals("centred in the room the new bottom inset leaves", roomCentre, emptyAt + empty.height / 2f, 2 * density)
            assertEquals("no hairline under the bar before anything scrolls", 0f, layout.hairline.alpha)

            empty.descendants.filterIsInstance<TextView>().single { it.text == activity.getString(R.string.mini_apps_new) }.performClick()
            assertEquals("New app starts the request to build one", listOf(activity.getString(R.string.mini_apps_new_prompt)), asked)
        }

    @Test fun `a failed refresh over loaded apps shows above them, not over them`() =
        shown(JSONObject().put("status", "failed").put("apps", JSONArray().put(JSONObject().put("id", "app1")
            .put("workspace_id", "wsp").put("name", "Notes").put("status", "active"))), bottomDp = 200, bottomAfterDp = 200) { (_, _, layout, _) ->
            shoot(layout, "apps-failed-over-apps")
            val failure = visibleStates(layout).single()
            val card = layout.descendants.single { it.contentDescription == "Notes" }
            val failureBottom = IntArray(2).also(failure::getLocationInWindow)[1] + failure.height
            val cardTop = IntArray(2).also(card::getLocationInWindow)[1]
            assertTrue("the failure ($failureBottom) ends above the app ($cardTop)", failureBottom <= cardTop)
        }

    private fun settle() = repeat(60) { ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS) }

    /** Writes the page as drawn to `$COMMA_SHOTS`, for looking at it; nothing when unset. */
    private fun shoot(view: View, name: String) {
        val dir = System.getenv("COMMA_SHOTS") ?: return
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        File(dir).mkdirs()
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
