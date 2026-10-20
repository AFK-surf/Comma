package surf.comma.android.chat.live

import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.graphics.ColorUtils
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.tasks.pages.TaskPages
import surf.comma.android.ui.widget.DrawerHostLayout

/**
 * The signed-in home: the chat with the task sidebar at its start edge.
 *
 * The sidebar opens from the top bar's button or by dragging sideways anywhere on the chat, except
 * where something there owns sideways drags (code blocks and tables, text fields) or on the
 * composer. A drag that starts on the screen edge itself is the system's back gesture and is
 * left to it. While the sidebar shows, back closes it, and so does a tap on the dimmed chat.
 */
internal class ChatHome(
    activity: ComponentActivity,
    private val screen: LiveChatScreen,
    onOpenSettings: () -> Unit,
) {
    val sidebar = ChatSidebar(activity)
    val scrim = View(activity).apply {
        id = R.id.chat_sidebar_scrim
        contentDescription = activity.getString(R.string.chat_close_sidebar)
        // Light: `background.overlay`, near black. Dark: that token is lighter than the page and
        // would wash the chat out, so the scrim is the page colour itself, which dims it.
        val dark = activity.resources.configuration.isNightModeActive
        setBackgroundColor(if (dark) ColorUtils.setAlphaComponent(activity.getColor(R.color.token_bg_primary), SCRIM_ALPHA_DARK)
            else ColorUtils.setAlphaComponent(activity.getColor(R.color.token_bg_overlay), SCRIM_ALPHA_LIGHT))
        setOnClickListener { close() }
    }
    val root = DrawerHostLayout(activity)
    /** Tasks opened from cards in the chat; over everything, sidebar included. */
    val taskSheet: ChatTaskSheet
    private val back = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = close()
    }

    val isOpen: Boolean get() = root.isOpen

    init {
        root.addView(screen.root, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        root.addView(scrim, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        // The host sets the drawer's width.
        root.addView(sidebar.view, FrameLayout.LayoutParams(0, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.START))
        var shown = false
        root.bind(sidebar.view, scrim, listOf(screen.root)) { visible ->
            back.isEnabled = visible
            if (visible && !shown) screen.dismissInput()
            shown = visible
        }
        taskSheet = ChatTaskSheet(activity, root)
        // While a task sheet is up, sideways drags belong to it, never to the sidebar.
        root.excludesDragAt = { x, y -> taskSheet.layout.isVisible || screen.excludesSidebarDragAt(x, y) }
        screen.onOpenTaskCard = { id, known ->
            screen.dismissInput()
            taskSheet.open(id, known)
        }
        sidebar.onOpenTask = { TaskPages.openDetail(activity, it) }
        sidebar.onViewAll = { TaskPages.openList(activity) }
        sidebar.onOpenSettings = onOpenSettings
        screen.onOpenSidebar = ::open
        activity.onBackPressedDispatcher.addCallback(activity, back)
    }

    fun open() = root.open()

    fun close() = root.close()

    private companion object {
        const val SCRIM_ALPHA_LIGHT = 0x2E
        const val SCRIM_ALPHA_DARK = 0xA6
    }
}
