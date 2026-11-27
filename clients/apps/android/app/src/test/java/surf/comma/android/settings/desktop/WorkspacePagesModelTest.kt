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

    private fun colabNotice(id: Int, attempt: String, reauthorize: Boolean = false, error: String? = null) = json(
        "id" to id, "workspace" to "wsp_test", "kind" to "configure", "plugin" to "google-colab", "origin" to "plugins",
        "configuration" to json("workspace" to "wsp_test", "operation" to if (reauthorize) "reauthorize" else "install",
            "connectionId" to "google-colab-oauth".takeIf { reauthorize }, "bindingId" to "colab_acc_1".takeIf { reauthorize },
            "setup" to json("key" to "GOOGLE_COLAB_AUTH_CODE", "label" to "Authorization code",
                "helpUrl" to "https://accounts.google.com/o/oauth2/v2/auth?state=$attempt", "format" to "oauth_code",
                "attemptId" to attempt, "error" to error)))

    private fun colab(installed: Boolean) = Plugin.parse(json("id" to "google-colab", "name" to "Google Colab",
        "brand" to "google-colab", "installed" to installed, "credentialSetup" to null))!!

    @Test
    fun aGoogleSignInFormComesFromTheConfigureNoticeAndARejectedCodeKeepsItsAttempt() {
        val model = PluginsModel(h.scope)
        h.core.on("plugin.notice.claim") { true }
        val plugin = colab(installed = false)
        assertNull("the catalog lists no form for it", plugin.credentialKey)
        runBlocking { model.receiveNotice(colabNotice(1, "colab_att_1")) }
        val form = model.configuration(plugin)!!
        assertTrue(form.oauthCode)
        assertEquals("https://accounts.google.com/o/oauth2/v2/auth?state=colab_att_1", form.helpUrl)

        h.core.on("plugin.install") { json("failure" to "credential_rejected") }
        runBlocking { model.install(plugin, "4/0Abc") }
        val sent = h.core.called("plugin.install").last()
        assertEquals("4/0Abc", sent.getJSONObject("configValues").getString("GOOGLE_COLAB_AUTH_CODE"))
        assertEquals("colab_att_1", sent.getString("attemptId"))
        assertEquals("wsp_test", sent.getString("workspace"))
        assertEquals(PageError.Text(surf.comma.android.R.string.ds_plugins_code_rejected), model.formError)
        assertNull(h.scope.error)
        assertEquals("a rejected code keeps its sign-in", "colab_att_1", model.configuration(plugin)?.attemptId)

        // The server's words for a code from another Google account reach the form as they are.
        val wrongAccount = "Sign in with alice@gmail.com, the account this workspace connected."
        h.core.on("plugin.install") { json("failure" to "credential_rejected", "message" to wrongAccount) }
        runBlocking { model.install(plugin, "4/0Other") }
        assertEquals(PageError.Message(wrongAccount), model.formError)
        assertEquals("colab_att_1", model.configuration(plugin)?.attemptId)

        // An expired sign-in comes back as a fresh link and attempt, which replaces the form in place.
        runBlocking { model.receiveNotice(colabNotice(2, "colab_att_2", error = "The sign-in expired.")) }
        assertEquals("colab_att_2", model.configuration(plugin)?.attemptId)
        assertEquals("The sign-in expired.", model.configuration(plugin)?.error)
        assertNull(model.formError)

        h.core.on("plugin.install") { JSONObject() }
        runBlocking { model.install(plugin, "4/0Def") }
        assertEquals("colab_att_2", h.core.called("plugin.install").last().getString("attemptId"))
        assertNull("a connected account puts the form away", model.configuration)
        assertTrue(h.core.called("plugin.reauthorize").isEmpty())
    }

    @Test
    fun aColabReconnectNamesItsAccountAndSendsTheCodeToTheReconnect() {
        val model = PluginsModel(h.scope)
        h.core.on("plugin.notice.claim") { true }
        h.core.on("plugin.reauthorize") { JSONObject() }
        val plugin = colab(installed = true)
        runBlocking { model.install(plugin, connection = "google-colab-oauth", binding = "colab_acc_1") }
        val started = h.core.called("plugin.reauthorize").last()
        assertEquals("google-colab-oauth", started.getString("connection"))
        assertEquals("colab_acc_1", started.getString("bindingId"))
        assertFalse(started.has("configValues"))

        runBlocking { model.receiveNotice(colabNotice(3, "colab_att_3", reauthorize = true)) }
        assertTrue(model.configuration(plugin)!!.reauthorize)
        runBlocking { model.install(plugin, "4/0Ghi") }
        val sent = h.core.called("plugin.reauthorize").last()
        assertEquals("colab_att_3", sent.getString("attemptId"))
        assertEquals("colab_acc_1", sent.getString("bindingId"))
        assertEquals("google-colab-oauth", sent.getString("connection"))
        assertEquals("4/0Ghi", sent.getJSONObject("configValues").getString("GOOGLE_COLAB_AUTH_CODE"))
        assertTrue("a reconnect's code never installs a second account", h.core.called("plugin.install").isEmpty())
    }

    @Test
    fun aChatInstallTakesOnlyItsOwnPluginsNotices() {
        val model = PluginsModel(h.scope, only = "google-colab")
        h.core.on("plugin.notice.claim") { true }
        runBlocking {
            model.receiveNotice(json("id" to 4, "workspace" to "wsp_test", "kind" to "authorize", "plugin" to "gmail",
                "url" to "https://auth.example.test/gmail"))
        }
        assertTrue("another plugin's notice stays for the Plugins page", h.core.called("plugin.notice.claim").isEmpty())
        runBlocking { model.receiveNotice(colabNotice(5, "colab_att_5")) }
        assertEquals(5, h.core.called("plugin.notice.claim").single().getInt("id"))
        assertEquals("colab_att_5", model.configuration?.attemptId)
    }

    @Test
    fun stillfailShowFormatNeverAsksForCredentialAndParsesConnectLine() {
        val stillfail = Plugin.parse(json(
            "id" to "stillfail",
            "name" to "Monoid",
            "brand" to "stillfail",
            "installed" to false,
            "stations" to true,
            "credentialSetup" to json(
                "key" to "STILLFAIL_CONNECT_LINE",
                "label" to "Connect line",
                "helpUrl" to "https://still.fail/docs/comma",
                "format" to "show",
            ),
        ))!!
        assertEquals("show", stillfail.credentialFormat)
        assertTrue(stillfail.showsConnectLine)
        assertFalse("format == show must not be treated as a secret input", stillfail.asksCredential)
        assertTrue(stillfail.isStillfail)

        val model = PluginsModel(h.scope)
        h.core.on("plugin.notice.claim") { true }
        runBlocking {
            model.receiveNotice(json(
                "id" to 9,
                "workspace" to "wsp_test",
                "kind" to "configure",
                "plugin" to "stillfail",
                "configuration" to json(
                    "workspace" to "wsp_test",
                    "operation" to "install",
                    "setup" to json(
                        "key" to "STILLFAIL_CONNECT_LINE",
                        "label" to "Connect line",
                        "format" to "show",
                        "value" to "comma https://salix.comma.surf tok_test_line",
                    ),
                ),
            ))
        }
        val config = model.configuration(stillfail)!!
        assertTrue(config.showValue)
        assertEquals("comma https://salix.comma.surf tok_test_line", config.value)
    }

    @Test
    fun pluginStationsModelParsesWorkspacesDisconnectAndNotificationLevel() {
        val model = PluginStationsModel(h.scope, Plugin.STILLFAIL)
        val job = model.follow()
        val sub = h.core.subscribed.last()
        assertEquals("pluginStations", sub.getString("topic"))
        assertEquals("wsp_test", sub.getString("workspace"))
        assertEquals("stillfail", sub.getString("plugin"))

        h.core.publish("pluginStations", json(
            "stations" to JSONArray()
                .put(json(
                    "id" to "st_online",
                    "workspace" to "Alpha Studio",
                    "emoji" to "🚀",
                    "station" to "mac-mini-1",
                    "stationCount" to 3,
                    "connected" to true,
                    "connectedAt" to "2026-11-25T01:00:00Z",
                ))
                .put(json(
                    "id" to "st_offline",
                    "workspace" to "Beta Lab",
                    "station" to "linux-box-2",
                    "stationCount" to 1,
                    "connected" to false,
                    "connectedAt" to "2026-11-24T12:00:00Z",
                ))
                .put(json(
                    "id" to "st_waiting",
                    "connected" to false,
                    "connectedAt" to null,
                )),
            "notificationLevel" to "issues",
            "notificationPending" to false,
            "pending" to null,
            "error" to null,
        ))
        assertEquals(3, model.stations?.size)
        assertTrue(model.hasOfflineStation)
        assertTrue(model.stations!![1].offline)
        assertTrue(model.stations!![2].waiting)
        assertEquals(StillfailNotificationLevel.ISSUES, model.notificationLevel)

        // Disconnect calls plugin.station.disconnect with workspace, plugin, station.
        h.core.on("plugin.station.disconnect") { JSONObject() }
        assertTrue(runBlocking { model.disconnect("st_offline") })
        val disc = h.core.called("plugin.station.disconnect").single()
        assertEquals("wsp_test", disc.getString("workspace"))
        assertEquals("stillfail", disc.getString("plugin"))
        assertEquals("st_offline", disc.getString("station"))
        assertNull(model.pending)

        // Notification level change calls plugin.station.notificationLevel.set.
        h.core.on("plugin.station.notificationLevel.set") { JSONObject() }
        assertTrue(runBlocking { model.setNotificationLevel(StillfailNotificationLevel.ALL) })
        val setLevel = h.core.called("plugin.station.notificationLevel.set").single()
        assertEquals("wsp_test", setLevel.getString("workspace"))
        assertEquals("stillfail", setLevel.getString("plugin"))
        assertEquals("all", setLevel.getString("level"))
        assertEquals(StillfailNotificationLevel.ALL, model.notificationLevel)
        assertFalse(model.notificationPending)

        // Failed notification level save rolls back to previous level and sets error.
        h.core.on("plugin.station.notificationLevel.set") { throw CoreError("server_error", "boom", 500) }
        assertFalse(runBlocking { model.setNotificationLevel(StillfailNotificationLevel.OFF) })
        assertEquals(StillfailNotificationLevel.ALL, model.notificationLevel)
        assertEquals("notification_save_failed", model.error)
        job.cancel()
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
