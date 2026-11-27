package surf.comma.android.ui.kit

import android.widget.FrameLayout
import android.widget.ProgressBar
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** A screen reader hears the indicator as a progress bar that is loading. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN")
class ActivityIndicatorTest {
    @Test fun `a screen reader reads it as a progress bar that is loading`() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val indicator = ActivityIndicator(activity)
        activity.setContentView(FrameLayout(activity).apply { addView(indicator) })
        val node = indicator.createAccessibilityNodeInfo()
        assertEquals(ProgressBar::class.java.name, node.className)
        assertEquals("正在加载", node.contentDescription)
        assertTrue(indicator.isImportantForAccessibility)
    }
}
