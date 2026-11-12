package surf.comma.android.settings.desktop

import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.core.CoreError
import java.util.Base64

/**
 * The Workspace pages' models on a fake core: their changes name the page's Workspace, a page retired by an account
 * or Workspace change sends nothing more, and the voice sample and one-time key values behave as on iOS.
 */
// All identifiers, names and numbers below are invented test data.
class WorkspacePagesModelTest {
    private val h = DesktopHarness()

    @After fun tearDown() = h.owner.cancel()

    private class Playback : VoicePlayback {
        var finished: ((Boolean) -> Unit)? = null
        var playing = false
        override fun play(data: ByteArray, finished: (Boolean) -> Unit) { this.finished = finished; playing = true }
        override fun stop() { playing = false; finished = null }
    }

    private fun voiceModel(audio: VoicePlayback): VoiceModel {
        h.core.publish("voice", json("workspace" to "wsp_test", "integration" to json(
            "voices" to JSONArray(listOf("coral", "quartz")),
            "preferences" to json("voice" to json("kind" to "preset", "name" to "coral"),
                "custom_voice" to json("name" to "Narrator", "description" to "Warm and clear")))))
        return VoiceModel(h.scope, audio) { "en" }.also { it.feed.follow() }
    }

    private val sample = json("audio" to Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)), "contentType" to "audio/wav")

    @Test
    fun voiceSamplesNeverSelectAndAnOlderSampleCannotEndANewerOne() {
        val audio = Playback()
        val model = voiceModel(audio)
        h.core.on("voice.preview") { sample }
        assertEquals("coral", model.selected)
        assertEquals("Warm and clear", model.customVoice?.detail)

        model.preview("quartz")
        assertEquals(VoicePreview.Playing("quartz"), model.preview)
        val request = h.core.called("voice.preview").last()
        assertEquals("quartz", request.getJSONObject("voice").getString("name"))
        assertEquals("wsp_test", request.getString("workspace"))
        assertTrue("a sample does not choose the voice", h.core.called("voice.setPreferences").isEmpty())

        val older = audio.finished
        model.preview("custom")
        assertEquals(json("kind" to "custom").toString(), h.core.called("voice.preview").last().getJSONObject("voice").toString())
        older?.invoke(true)
        assertEquals(VoicePreview.Playing("custom"), model.preview)
        audio.finished?.invoke(true)
        assertNull(model.preview)

        model.preview("")
        assertTrue("the default voice is null", h.core.called("voice.preview").last().isNull("voice"))
        assertTrue(runBlocking { model.select("quartz") })
        assertNull("choosing a voice stops the sample", model.preview)
        assertFalse(audio.playing)
        assertEquals("quartz", h.core.called("voice.setPreferences").last().getJSONObject("voice").getString("name"))

        h.switch()
        val count = h.core.called("voice.preview").size
        model.preview("quartz")
        assertEquals("a retired page asks for no sample", count, h.core.called("voice.preview").size)
        assertNull(model.preview)
    }

    @Test
    fun aFailedSampleCanBeRetriedAndPressingThePlayingRowStopsIt() {
        val audio = Playback()
        val model = voiceModel(audio)
        h.core.on("voice.preview") { json("audio" to "not base64!") }
        model.preview("quartz")
        assertTrue(model.previewFailed)
        assertNull(model.preview)
        h.core.on("voice.preview") { sample }
        model.preview("quartz")
        assertFalse(model.previewFailed)
        assertEquals(VoicePreview.Playing("quartz"), model.preview)
        model.preview("quartz")
        assertNull(model.preview)
        assertFalse(audio.playing)
        assertEquals("stopping asks for no other sample", 2, h.core.called("voice.preview").size)
    }

    @Test
    fun aCreatedKeyShowsOnceAndARetiredPageCreatesNone() {
        val keys = ApiKeysModel(VoiceModel(h.scope, Playback()).feed, voice = true)
        h.core.on("voice.createKey") { json("key_id" to "key-1", "key" to "once-only-secret") }
        assertTrue(runBlocking { keys.create("My client") })
        assertEquals("My client", h.core.called("voice.createKey").single().getString("name"))
        assertEquals("once-only-secret", keys.secret)
        keys.clearSecret()
        assertNull(keys.secret)
        h.switch()
        assertFalse(runBlocking { keys.create("Another client") })
        assertEquals(1, h.core.called("voice.createKey").size)
    }

    @Test
    fun requestApprovalChangesNameTheirWorkspaceAndRetireAfterSwitching() {
        val model = TaskRequestsModel(h.scope)
        runBlocking {
            model.setMode("grant-review", "auto_accept")
            model.setOwnAutoAccept(false)
        }
        val mode = h.core.called("taskRequests.setMode").single()
        assertEquals("grant-review", mode.getString("grant"))
        assertEquals("auto_accept", mode.getString("mode"))
        assertEquals("wsp_test", mode.getString("workspace"))
        assertEquals("review", h.core.called("taskRequests.setOwnMode").single().getString("mode"))
        h.switch()
        runBlocking {
            model.setMode("grant-review", "review")
            model.setOwnAutoAccept(true)
        }
        assertEquals(1, h.core.called("taskRequests.setMode").size)
        assertEquals(1, h.core.called("taskRequests.setOwnMode").size)
    }

    @Test
    fun aChatAccountLinksOnlyAfterItsOwnPreview() {
        val model = TaskRequestsModel(h.scope)
        h.core.on("taskRequests.linkPreview") { json("provider" to "Slack", "name" to "Alex") }
        h.core.on("taskRequests.acceptLink") { JSONObject() }
        var link = "first-token"
        runBlocking { model.previewLink(link) { link } }
        link = "different-token"
        assertFalse(runBlocking { model.acceptLink(link) })
        assertTrue(h.core.called("taskRequests.acceptLink").isEmpty())
        runBlocking { model.previewLink(link) { link } }
        assertTrue(runBlocking { model.acceptLink(link) })
        assertNull(model.linkPreview)
    }

    @Test
    fun anInviteIsAcceptedOnlyAfterItsOwnPreviewInThisWorkspace() {
        val model = TaskRequestsModel(h.scope)
        h.core.on("taskRequests.invitePreview") { json("own" to false) }
        h.core.on("taskRequests.acceptInvite") { json("reciprocal" to true) }
        var link = "first-token"
        assertFalse(runBlocking { model.acceptInvitation(link) })
        runBlocking { model.previewInvitation(link) { link } }
        assertEquals("wsp_test", h.core.called("taskRequests.invitePreview").single().getString("workspace"))
        link = "different-token"
        assertFalse(runBlocking { model.acceptInvitation(link) })
        assertTrue(h.core.called("taskRequests.acceptInvite").isEmpty())
        runBlocking { model.previewInvitation(link) { link } }
        assertTrue(runBlocking { model.acceptInvitation(link) })
        assertEquals("wsp_test", h.core.called("taskRequests.acceptInvite").single().getString("workspace"))
        assertNull(model.invitePreview)
    }

    @Test
    fun anOwnInviteIsNotAccepted() {
        val model = TaskRequestsModel(h.scope)
        h.core.on("taskRequests.invitePreview") { json("own" to true) }
        runBlocking { model.previewInvitation("token") { "token" } }
        assertFalse(runBlocking { model.acceptInvitation("token") })
        assertTrue(h.core.called("taskRequests.acceptInvite").isEmpty())
    }

    @Test
    fun anotherWorkspacesPluginNoticeIsNeitherClaimedNorShown() {
        val model = PluginsModel(h.scope)
        h.core.on("plugin.notice.claim") { true }
        runBlocking {
            model.receiveNotice(json("id" to 1, "workspace" to "wsp_other", "kind" to "authorize", "plugin" to "gmail",
                "url" to "https://auth.example.test/other"))
        }
        assertTrue(h.core.called("plugin.notice.claim").isEmpty())
        assertNull(model.authorizationUrl)
        runBlocking {
            model.receiveNotice(json("id" to 2, "workspace" to "wsp_test", "kind" to "authorize", "plugin" to "gmail",
                "url" to "https://auth.example.test/mine"))
        }
        assertEquals("https://auth.example.test/mine", model.authorizationUrl)
        assertEquals("gmail", model.authorizationPlugin)
    }

    @Test
    fun aScreenViewOverTheMeshAcknowledgesFramesAndLeavesTheDeviceToAnAgent() {
        val events = kotlinx.coroutines.channels.Channel<JSONObject>(kotlinx.coroutines.channels.Channel.UNLIMITED)
        h.core.onStream("devices.openScreenView") { _, progress ->
            for (event in events) progress(event)
            null
        }
        val states = mutableListOf<MeshScreenState>()
        val view = MeshScreenView(h.scope, "dev_test_1", "simulator:A", "i1", control = true) { states += it }
        val running = h.owner.launch { view.run() }
        val opened = h.core.called("devices.openScreenView").single()
        assertEquals("simulator:A", opened.getString("target"))
        assertEquals("i1", opened.getString("instance"))
        assertEquals("h264", opened.getJSONArray("codecs").getString(0))
        assertTrue(opened.getBoolean("control"))

        events.trySend(json("type" to "open", "view" to 3))
        events.trySend(json("type" to "state", "state" to json("switches" to true, "control" to true)))
        // A frame with no decoder yet and no key frame before it is of no use to one: acknowledged, the station would
        // wait for it. (A key frame waits for the decoder: ScreenPicturesTest.)
        events.trySend(json("type" to "video", "key" to false, "ts" to 42, "data" to surf.comma.android.core.CoreBytes.json(byteArrayOf(0, 0, 0, 1, 0x65))))
        val ack = h.core.called("devices.sendToScreenView").single()
        assertEquals(3, ack.getInt("view"))
        assertEquals(42L, ack.getLong("ack"))

        // An agent's lease: the view goes to Watch, on the open view, so the agent's input reaches the device.
        events.trySend(json("type" to "state", "state" to json("agent" to true, "agentPointer" to json("x" to 0.5, "y" to 0.25, "down" to true))))
        assertFalse(h.core.called("devices.sendToScreenView").last().getBoolean("control"))
        assertTrue(view.state.agent)
        assertEquals(0.5f to 0.25f, view.state.agentPointer)
        running.cancel()
    }

    @Test
    fun picturesComeStraightFromTheCoreAndAreAcknowledged() {
        h.core.sinks = true
        val events = kotlinx.coroutines.channels.Channel<JSONObject>(kotlinx.coroutines.channels.Channel.UNLIMITED)
        h.core.onStream("devices.openScreenView") { _, progress ->
            for (event in events) progress(event)
            null
        }
        val view = MeshScreenView(h.scope, "dev_test_1", "display", null, control = false) {}
        val running = h.owner.launch { view.run() }
        val sink = h.core.called("devices.openScreenView").single().getInt("sink")
        events.trySend(json("type" to "open", "view" to 4))
        // No decoder yet (no surface): a frame with no key frame before it is of no use to one, and is acknowledged.
        h.core.picture(sink, surf.comma.android.core.ScreenFrame(3, 99, 0, 0, byteArrayOf(0, 0, 0, 1, 0x41)))
        val ack = h.core.called("devices.sendToScreenView").single()
        assertEquals(4, ack.getInt("view"))
        assertEquals(99L, ack.getLong("ack"))
        // A config's size reaches the page.
        val avcc = byteArrayOf(1, 0x42, 0, 0x1f, 0xff.toByte(), 0xe1.toByte(), 0, 2, 0x67, 0x42, 1, 0, 2, 0x68, 0x43)
        h.core.picture(sink, surf.comma.android.core.ScreenFrame(1, 0, 882, 1920, avcc))
        assertEquals(882 to 1920, view.state.width to view.state.height)
        running.cancel()
    }

    @Test
    fun aMeshThatDoesNotReachTheComputerSaysSo() {
        h.core.onStream("devices.openScreenView") { _, _ -> throw CoreError("unreachable", "The mesh did not reach that computer.") }
        val view = MeshScreenView(h.scope, "dev_test_1", "display", null, control = false) {}
        // It says so, then waits to try again by itself.
        val running = h.owner.launch { view.run() }
        assertEquals(MeshScreenState.Phase.FAILED, view.state.phase)
        assertTrue(view.state.unreachable)
        assertTrue(running.isActive)
        running.cancel()
    }

    @Test
    fun aRefusedScreenViewIsNotTriedAgain() {
        h.core.onStream("devices.openScreenView") { _, _ -> throw CoreError("forbidden", "this computer does not allow its screen to be viewed") }
        val view = MeshScreenView(h.scope, "dev_test_1", "display", null, control = false) {}
        runBlocking { view.run() }
        assertEquals(MeshScreenState.Phase.FAILED, view.state.phase)
        assertEquals("this computer does not allow its screen to be viewed", view.state.failure)
        assertEquals(1, h.core.called("devices.openScreenView").size)
    }

    @Test
    fun anAvcConfigGivesItsParameterSetsAndFramesComeOutAsAnnexB() {
        // avcC: version 1, profile, compat, level, 4-byte NAL lengths; one SPS (2 bytes), one PPS (1 byte).
        val avcC = byteArrayOf(1, 0x42, 0, 0x1e, 0xff.toByte(), 0xe1.toByte(), 0, 2, 0x67, 0x42, 1, 0, 1, 0x68)
        val config = AvcConfig.parse(avcC)!!
        assertEquals(4, config.nalLength)
        assertEquals(listOf<Byte>(0, 0, 0, 1, 0x67, 0x42), config.sps.toList())
        assertEquals(listOf<Byte>(0, 0, 0, 1, 0x68), config.pps.toList())
        val frame = byteArrayOf(0, 0, 0, 2, 0x65, 9, 0, 0, 0, 1, 0x41)
        assertEquals(listOf<Byte>(0, 0, 0, 1, 0x65, 9, 0, 0, 0, 1, 0x41), AvcConfig.annexB(frame, 4)!!.toList())
        assertEquals(null, AvcConfig.annexB(byteArrayOf(0, 0, 0, 9, 1), 4))
        // 4-byte lengths become start codes where they are: the same array, no copy.
        val same = byteArrayOf(0, 0, 0, 2, 0x65, 9, 0, 0, 0, 1, 0x41)
        assertTrue(AvcConfig.annexBInPlace(same) === same)
        assertEquals(listOf<Byte>(0, 0, 0, 1, 0x65, 9, 0, 0, 0, 1, 0x41), same.toList())
        val broken = byteArrayOf(0, 0, 0, 9, 1)
        assertEquals(null, AvcConfig.annexBInPlace(broken))
        assertEquals(listOf<Byte>(0, 0, 0, 9, 1), broken.toList())
    }

    @Test
    fun aConflictingInstructionSaveKeepsTheEditAndReadsTheLatest() {
        val model = RouterSettingsModel(h.scope)
        var saved = "Be brief."
        h.core.on("systemFiles.instructions") { json("content" to saved, "hash" to "v-$saved") }
        runBlocking { model.loadInstructions() }
        saved = "Be thorough."
        h.core.on("systemFiles.writeInstructions") { throw CoreError("conflict", "changed", 409) }
        model.instructions = "Be brief and kind."
        assertFalse(runBlocking { model.saveInstructions(model.instructions) })
        assertEquals("v-Be brief.", h.core.called("systemFiles.writeInstructions").single().getString("expectedHash"))
        assertEquals("Be brief and kind.", model.instructions)
        assertEquals("Be thorough.", model.savedInstructions)
        assertTrue(model.instructionsChanged)
        assertEquals("grp_test_1", h.core.called("systemFiles.writeInstructions").single().getString("group"))
    }
}
