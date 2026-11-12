package surf.comma.android.shell

import android.animation.ValueAnimator
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import surf.comma.android.ui.widget.LiquidGlass

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ShellTabBarTest {
    private val selections = mutableListOf<AppTab>()

    @After fun reset() {
        LiquidGlass.enabled = false
        setAnimatorScale(1f)
    }

    @Test fun `a tap on the selected tab selects it again`() {
        val bar = bar()
        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_UP, HOME_X)
        assertEquals(listOf(AppTab.HOME), selections)
    }

    @Test fun `a gesture the system cancels selects nothing`() {
        val bar = bar()
        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_CANCEL, HOME_X)
        assertEquals(emptyList<AppTab>(), selections)
    }

    @Test fun `a drag away and back to the selected tab selects nothing`() {
        val bar = bar()
        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_MOVE, INBOX_X)
        bar.touch(MotionEvent.ACTION_MOVE, HOME_X)
        bar.touch(MotionEvent.ACTION_UP, HOME_X)
        assertEquals(emptyList<AppTab>(), selections)
    }

    @Test fun `a drag to another tab selects it`() {
        val bar = bar()
        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_MOVE, INBOX_X)
        bar.touch(MotionEvent.ACTION_UP, INBOX_X)
        assertEquals(listOf(AppTab.INBOX), selections)
    }

    @Test fun `a flight lands on arriving at its tab`() {
        val bar = bar()
        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_UP, SETTINGS_X)
        arriveAtOnce()
        bar.lens().moveTo(SETTINGS_X)
        assertEquals(View.GONE, bar.lens().visibility)
    }

    @Test fun `a press during a flight keeps the lens up on arriving at its tab`() {
        val bar = bar()
        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_UP, SETTINGS_X)
        arriveAtOnce()
        bar.touch(MotionEvent.ACTION_DOWN, SETTINGS_X)
        assertEquals(View.VISIBLE, bar.lens().visibility)
    }

    @Test fun `only a touch on the capsule presses the bar's glass`() {
        val bar = bar()
        val pressed = mutableListOf<Int>()
        bar.onGlassTouch = { pressed += it.actionMasked }

        bar.touch(MotionEvent.ACTION_DOWN, ROUTER_X)
        bar.touch(MotionEvent.ACTION_UP, ROUTER_X)
        assertEquals(emptyList<Int>(), pressed)

        bar.touch(MotionEvent.ACTION_DOWN, HOME_X)
        bar.touch(MotionEvent.ACTION_UP, HOME_X)
        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP), pressed)
    }

    @Test fun `without the glass the bar builds no lens`() {
        assertTrue(bar(glass = false).children().none { it is TabBarLens })
    }

    private fun bar(glass: Boolean = true): ShellTabBar {
        LiquidGlass.enabled = glass
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        return ShellTabBar(activity).apply {
            onSelect = { selections += it; select(it) }
            activity.setContentView(this, ViewGroup.LayoutParams(WIDTH, ViewGroup.LayoutParams.WRAP_CONTENT))
            measure(View.MeasureSpec.makeMeasureSpec(WIDTH, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            layout(0, 0, measuredWidth, measuredHeight)
        }
    }

    private fun ShellTabBar.touch(action: Int, x: Float) {
        val event = MotionEvent.obtain(0L, 0L, action, x, 30f, 0)
        dispatchTouchEvent(event)
        event.recycle()
    }

    private fun ViewGroup.children() = (0 until childCount).map(::getChildAt)

    private fun ShellTabBar.lens() = children().filterIsInstance<TabBarLens>().single()

    /** Springs step no frames here: with animations off the lens is at once wherever it is sent, still on its flight. */
    private fun arriveAtOnce() = setAnimatorScale(0f)

    private fun setAnimatorScale(scale: Float) {
        ReflectionHelpers.callStaticMethod<Unit>(ValueAnimator::class.java, "setDurationScale",
            ReflectionHelpers.ClassParameter.from(Float::class.javaPrimitiveType, scale))
    }

    private companion object {
        const val WIDTH = 1080
        // At Robolectric's density the capsule is 1010 wide, with four tabs of 248 starting at 8.
        const val HOME_X = 132f
        const val INBOX_X = 380f
        const val SETTINGS_X = 876f
        const val ROUTER_X = 1050f
    }
}
