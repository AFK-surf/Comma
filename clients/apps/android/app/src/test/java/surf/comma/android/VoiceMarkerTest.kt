package surf.comma.android

import surf.comma.android.chat.model.MessageSource
import surf.comma.android.chat.render.VoiceMarker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 标记的几何。纯 Kotlin，不碰 Canvas：它必须能在已经量好的格子里画完，
 * 不能靠加高、加边距或改正文宽度给自己腾位置。
 */
class VoiceMarkerTest {

    @Test
    fun typedMessagesHaveNoMarker() {
        assertNull(VoiceMarker.spec(null, columnLeft = 84f, contentTop = 20f, density = 3f))
    }

    @Test
    fun overlaySitsInTheGutterWithoutTakingVerticalSpaceFromTheCell() {
        val spec = VoiceMarker.spec(
            source = MessageSource.VOICE,
            columnLeft = 84f,
            contentTop = 20f,
            density = 3f,
        )!!
        assertTrue(
            "marker right=${spec.left + spec.width} must stay left of the text column at 84",
            spec.left + spec.width <= 84f,
        )
        assertTrue(spec.left >= 0f)
        assertEquals(20f, spec.top)
        assertEquals(VoiceMarker.widthDp * 3f, spec.width, 0.01f)
        assertEquals(VoiceMarker.heightDp * 3f, spec.height, 0.01f)
    }

    @Test
    fun sizeDependsOnlyOnDensityNotOnTheMessage() {
        val shortLine = VoiceMarker.spec(MessageSource.VOICE, 84f, 12f, 2.75f)!!
        val tallColumn = VoiceMarker.spec(MessageSource.VOICE, 240f, 80f, 2.75f)!!
        assertEquals(shortLine.width, tallColumn.width, 0f)
        assertEquals(shortLine.height, tallColumn.height, 0f)
        assertEquals(shortLine.dotRadius, tallColumn.dotRadius, 0f)
        assertEquals(shortLine.pitch, tallColumn.pitch, 0f)
    }
}
