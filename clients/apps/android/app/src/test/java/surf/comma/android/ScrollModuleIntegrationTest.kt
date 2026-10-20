package surf.comma.android

import android.app.Activity
import android.view.LayoutInflater
import android.widget.LinearLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import surf.comma.android.scroll.widget.ScrollContainer
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.scroll.widget.RecyclerView

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ScrollModuleIntegrationTest {
    @Test fun conversationLayoutInflatesTheScrollModuleView() {
        Robolectric.buildActivity(Activity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Comma_Auth) }
            controller.create()
            val view = LayoutInflater.from(activity).inflate(R.layout.view_conversations, LinearLayout(activity), false)
            val list = view.findViewById<RecyclerView>(R.id.conversationsList)
            assertEquals(RecyclerView::class.java, list.javaClass)
        }
    }

    @Test fun emptyTimelineContentIsDiscoverableBeforeFirstLayout() {
        Robolectric.buildActivity(Activity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Comma_Auth) }
            controller.create()
            val view = LayoutInflater.from(activity).inflate(R.layout.view_empty_timeline, LinearLayout(activity), false)
            val strip = view.findViewById<ScrollContainer>(R.id.emptySuggestionRow)
            assertEquals(ScrollContainer.HORIZONTAL, strip.orientation)
            assertNotNull(view.findViewById<LinearLayout>(R.id.suggestions))
        }
    }
}
