package surf.comma.android.ui.widget

import android.content.Context
import android.graphics.Color
import android.graphics.ColorMatrix
import androidx.core.graphics.ColorUtils
import org.robolectric.RuntimeEnvironment
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.R
import kotlin.math.roundToInt

/**
 * A blue bubble scrolled under the top chrome leaves a haze, not a blue glow. The haze is the
 * blurred bubble with the band's colour filter, spread thin over the page: QA measured #E9ECF6
 * on white, about 11 % of the half-saturated brand blue.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class BackdropHazeTest {
    private fun haze(): Int {
        val context = RuntimeEnvironment.getApplication() as Context
        val page = context.getColor(R.color.token_bg_primary)
        val bubble = context.getColor(R.color.token_bg_brand_solid)
        val m = ColorMatrix().apply { setSaturation(BackdropBlurLayout.BLUR_SATURATION) }.array
        fun channel(row: Int) = (m[row * 5] * Color.red(bubble) + m[row * 5 + 1] * Color.green(bubble) +
            m[row * 5 + 2] * Color.blue(bubble) + m[row * 5 + 4]).roundToInt().coerceIn(0, 255)
        val filtered = Color.rgb(channel(0), channel(1), channel(2))
        return ColorUtils.blendARGB(page, filtered, COVERAGE)
    }

    private fun assertNeutral(color: Int) {
        val channels = listOf(Color.red(color), Color.green(color), Color.blue(color))
        val spread = channels.max() - channels.min()
        assertTrue("haze #%06X is tinted by %d levels".format(color and 0xFFFFFF, spread), spread <= MAX_SPREAD)
    }

    @Test fun `on the light page the haze is neutral`() = assertNeutral(haze())

    @Config(qualifiers = "night")
    @Test fun `on the dark page the haze is neutral`() = assertNeutral(haze())

    private companion object {
        const val COVERAGE = 0.11f
        /** Channel spread of a grey a reader does not see as coloured. */
        const val MAX_SPREAD = 4
    }
}
