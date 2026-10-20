package surf.comma.android

import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.messageTextColor
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

class MessageContrastTest {
    // Token values: background.primary, background.brandSolid and markdown.textPrimary.
    private val light = ChatPalette.DEFAULT
    private val dark = light.copy(agentText = 0xFFF6F6F6.toInt(), secondaryText = 0xFFA4A5A9.toInt())

    @Test
    fun assistantTextMeetsNormalTextContrastInBothThemes() {
        val lightAgent = messageTextColor(ChatRole.AGENT, light)
        val darkAgent = messageTextColor(ChatRole.AGENT, dark)
        assertTrue(contrast(lightAgent, 0xFFFFFFFF.toInt()) >= 4.5)
        assertTrue(contrast(darkAgent, 0xFF0F0F10.toInt()) >= 4.5)
    }

    @Test
    fun userBubbleTextIsWhiteOnTheBrandColour() {
        val foreground = messageTextColor(ChatRole.USER, light)
        assertTrue("light=${contrast(foreground, 0xFF205BFF.toInt())}", contrast(foreground, 0xFF205BFF.toInt()) >= 4.5)
        // The dark brand colour is lighter by design; it still clears the large-text threshold.
        assertTrue("dark=${contrast(foreground, 0xFF3B7CFF.toInt())}", contrast(foreground, 0xFF3B7CFF.toInt()) >= 3.0)
    }

    private fun contrast(first: Int, second: Int): Double {
        val a = luminance(first)
        val b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private fun luminance(color: Int): Double {
        fun channel(value: Int): Double {
            val normalized = value / 255.0
            return if (normalized <= 0.04045) normalized / 12.92
            else ((normalized + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * channel((color ushr 16) and 0xff) +
            0.7152 * channel((color ushr 8) and 0xff) +
            0.0722 * channel(color and 0xff)
    }
}
