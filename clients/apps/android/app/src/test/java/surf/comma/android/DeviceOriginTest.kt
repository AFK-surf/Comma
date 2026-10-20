package surf.comma.android

import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.DeviceOrigin
import surf.comma.android.chat.model.MessageSource
import surf.comma.android.chat.render.DeviceOriginMarker
import surf.comma.android.chat.render.VoiceMarker
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Where a user message was sent from, as its row shows it. */
class DeviceOriginTest {
    @Test
    fun theMarkIsOnlyEverOnAUserMessageFromAnotherKindOfDevice() {
        fun message(role: ChatRole, originKind: String?) = ChatMessage(
            id = 1,
            conversationId = "c1",
            role = role,
            text = "t",
            createdAt = 0,
            originKind = originKind,
        )
        assertEquals(DeviceOrigin.MAC, DeviceOrigin.markFor(message(ChatRole.USER, "mac")))
        assertNull(DeviceOrigin.markFor(message(ChatRole.USER, "phone")))
        assertNull(DeviceOrigin.markFor(message(ChatRole.USER, null)))
        assertNull(DeviceOrigin.markFor(message(ChatRole.USER, "watch")))
        assertNull(DeviceOrigin.markFor(message(ChatRole.AGENT, "mac")))
        assertNull(DeviceOrigin.markFor(message(ChatRole.SYSTEM, "mac")))
    }

    @Test
    fun theMarkSitsLeftOfTheBubbleAndClearOfTheVoiceMarker() {
        val density = 3f
        val width = 14.4f * density
        val height = 12.75f * density

        assertNull(DeviceOriginMarker.spec(null, null, 500f, 40f, width, height, density))

        val plain = DeviceOriginMarker.spec(DeviceOrigin.MAC, null, 500f, 40f, width, height, density)!!
        assertEquals(500f - VoiceMarker.GAP_DP * density, plain.right, 0.01f)
        assertEquals(40f, plain.top, 0.01f)
        assertEquals(width, plain.right - plain.left, 0.01f)
        assertEquals(height, plain.bottom - plain.top, 0.01f)

        val voice = VoiceMarker.spec(MessageSource.VOICE, 500f, 40f, density)!!
        val beside = DeviceOriginMarker.spec(DeviceOrigin.MAC, MessageSource.VOICE, 500f, 40f, width, height, density)!!
        assertTrue(beside.right <= voice.left)
    }

    @Test
    fun theTwoPicturesAreDistinctOneColourDotsOfOneHeight() {
        assertNotEquals(
            DeviceOriginMarker.drawableFor(DeviceOrigin.PHONE),
            DeviceOriginMarker.drawableFor(DeviceOrigin.MAC),
        )
        assertNotEquals(
            DeviceOriginMarker.labelFor(DeviceOrigin.PHONE),
            DeviceOriginMarker.labelFor(DeviceOrigin.MAC),
        )
        val icons = listOf("ic_device_phone", "ic_device_mac").map { name ->
            File(chatRoot(), "app/src/main/res/drawable/$name.xml").readText()
        }
        val heights = icons.map { Regex("""android:viewportHeight="([0-9.]+)"""").find(it)!!.groupValues[1] }
        assertEquals(1, heights.toSet().size)
        icons.forEach { xml ->
            val fills = Regex("""android:fillColor="([^"]+)"""").findAll(xml).map { it.groupValues[1] }.toSet()
            assertEquals(setOf("@color/ink_muted"), fills)
            assertFalse("no strokes: dots only", xml.contains("strokeColor"))
        }
    }

    private fun chatRoot(): File = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) {
        it.parentFile
    }.first { File(it, "app/build.gradle.kts").isFile }
}
