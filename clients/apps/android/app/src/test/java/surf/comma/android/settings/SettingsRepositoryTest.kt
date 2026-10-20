package surf.comma.android.settings

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.scope
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The account settings as the screens see them: the client core's `profile`, label policy and signed-in devices, the
 * changes the person asks for handed to the core, and a refusal said. Showing a change before the server answers, and
 * what the core sends to the server, are the core's and are tested there.
 */
// All identifiers, names and addresses below are invented test data.
class SettingsRepositoryTest {
    @get:Rule val folder = TemporaryFolder()

    private val core = FakeAccountCore()
    private val sessions = FakeSessions()
    private val owner = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val repository = SettingsRepository(sessions, core, owner)
    private val notices = CopyOnWriteArrayList<SettingsNotice>()

    init {
        owner.launch { repository.notices.collect { notices += it } }
    }

    @After fun tearDown() = owner.cancel()

    /** The settings now: the repository and the fake core work in place, so a step's effect is there when it returns. */
    private fun await(condition: (SettingsState) -> Boolean) =
        assertTrue(repository.state.value.toString(), condition(repository.state.value))

    private fun refused(code: String, status: Int) = CoreError(code, "refused", status)

    private fun until(condition: () -> Boolean) = assertTrue("not settled", condition())

    private fun signedIn() {
        sessions.scopes.value = scope(1)
        repository.start()
        await { it.profile?.name == "Ada" }
    }

    @Test fun showsTheProfileOfTheSignedInAccount() {
        core.profile.value = core.profile(avatar = "av-1")
        signedIn()
        val state = repository.state.value
        assertEquals(1L, state.generation)
        assertEquals("ada@example.test", state.profile?.email)
        assertEquals(AvatarSource.Remote("av-1"), state.avatar)
    }

    @Test fun aRenameIsAskedOfTheCoreWhichShowsIt() = runBlocking<Unit> {
        signedIn()
        repository.rename("  Grace  ")
        assertEquals("Grace", core.called("profile.update").single().getString("name"))
        await { it.profile?.name == "Grace" }
        assertTrue(notices.isEmpty())
    }

    @Test fun aRefusedRenameSaysWhyAndShowsWhatTheCoreSays() = runBlocking<Unit> {
        signedIn()
        core.fail["profile.update"] = refused("name_too_long", 400)
        repository.rename("Grace")
        until { notices.isNotEmpty() }
        await { it.profile?.name == "Ada" }
        assertEquals(SettingsNotice(SettingsAction.RENAME, SettingsProblem.NAME_TOO_LONG), notices.single())
    }

    @Test fun invalidNamesAreRefusedWithoutACall() = runBlocking<Unit> {
        signedIn()
        repository.rename("   ")
        repository.rename("x".repeat(65))
        until { notices.size >= 2 }
        assertEquals(listOf(SettingsProblem.NAME_EMPTY, SettingsProblem.NAME_TOO_LONG), notices.map { it.problem })
        assertTrue(core.called("profile.update").isEmpty())
        // Graphemes, not UTF-16 units: 64 emoji fit.
        assertNull(ProfileRules.problem("👩‍💻".repeat(64)))
    }

    @Test fun anAvatarIsHandedToTheCoreAndItsFileDeleted() = runBlocking<Unit> {
        signedIn()
        val file = folder.newFile("avatar.jpg").apply { writeBytes(ByteArray(2048) { 7 }) }
        repository.changeAvatar(file, "image/jpeg")
        await { it.avatar is AvatarSource.Remote }
        val sent = core.called("profile.uploadAvatar").single()
        assertEquals("image/jpeg", sent.getString("type"))
        assertArrayEquals(ByteArray(2048) { 7 }, CoreBytes.read(sent.get("bytes")))
        until { !file.exists() }
    }

    @Test fun aRefusedAvatarSaysWhyAndShowsWhatTheCoreSays() = runBlocking<Unit> {
        core.profile.value = core.profile(avatar = "av-1")
        signedIn()
        core.fail["profile.uploadAvatar"] = refused("avatar_too_large", 400)
        val file = folder.newFile("avatar.png").apply { writeBytes(ByteArray(10)) }
        repository.changeAvatar(file, "image/png")
        until { notices.isNotEmpty() }
        await { it.avatar == AvatarSource.Remote("av-1") }
        assertEquals(SettingsNotice(SettingsAction.CHANGE_AVATAR, SettingsProblem.AVATAR_TOO_LARGE), notices.single())
        until { !file.exists() }
    }

    @Test fun avatarsTheServerWouldRefuseAreNotSent() = runBlocking<Unit> {
        signedIn()
        val big = folder.newFile("big.jpg").apply { writeBytes(ByteArray(102_401)) }
        repository.changeAvatar(big, "image/jpeg")
        val gif = folder.newFile("a.gif").apply { writeBytes(ByteArray(10)) }
        repository.changeAvatar(gif, "image/gif")
        until { notices.size >= 2 }
        assertEquals(listOf(SettingsProblem.AVATAR_TOO_LARGE, SettingsProblem.AVATAR_TYPE), notices.map { it.problem })
        assertTrue(core.called("profile.uploadAvatar").isEmpty())
        assertFalse(big.exists())
        assertFalse(gif.exists())
    }

    @Test fun aRefusedAvatarRemovalSaysWhy() = runBlocking<Unit> {
        core.profile.value = core.profile(avatar = "av-1")
        signedIn()
        core.fail["profile.removeAvatar"] = refused("avatar_storage_unavailable", 503)
        repository.removeAvatar()
        until { notices.isNotEmpty() }
        await { it.avatar == AvatarSource.Remote("av-1") }
        assertEquals(SettingsAction.REMOVE_AVATAR, notices.single().action)

        notices.clear()
        core.fail.remove("profile.removeAvatar")
        repository.removeAvatar()
        await { it.avatar == AvatarSource.None && it.profile?.avatarId == null }
        assertTrue(notices.isEmpty())
    }

    @Test fun theAvatarImageIsReadThroughTheCore() = runBlocking<Unit> {
        signedIn()
        assertArrayEquals(byteArrayOf(1, 2, 3), repository.avatarBytes("av-1"))
        val read = core.called("files.read").single()
        assertEquals("avatar", read.getString("source"))
        assertEquals("av-1", read.getString("revision"))
    }

    @Test fun theLabelPolicyOfTheCurrentGroupChangesAndARefusalIsSaid() = runBlocking<Unit> {
        signedIn()
        repository.refreshLabelPolicy()
        await { it.labelPolicy == LabelPolicy.ASK }
        assertEquals("grp_test_1", core.subscribed.single { it.getString("topic") == "taskLabels" }.getString("group"))

        repository.setLabelPolicy(LabelPolicy.AUTO)
        until { core.policy.value == "auto" }
        await { it.labelPolicy == LabelPolicy.AUTO }
        assertEquals("grp_test_1", core.called("taskLabels.setPolicy").single().getString("group"))

        core.fail["taskLabels.setPolicy"] = refused("conflict", 409)
        repository.setLabelPolicy(LabelPolicy.ASK)
        until { notices.isNotEmpty() }
        await { it.labelPolicy == LabelPolicy.AUTO }
        assertEquals(SettingsAction.LABEL_POLICY, notices.single().action)
    }

    @Test fun signingOutAnotherDeviceOrAllOthersSaysWhenRefused() = runBlocking<Unit> {
        signedIn()
        repository.refreshSessions()
        await { it.sessions?.size == 2 }

        core.fail["accountSessions.revoke"] = refused("internal", 500)
        repository.removeSession("ses-other")
        until { notices.isNotEmpty() }
        assertEquals(SettingsAction.REMOVE_DEVICE, notices.single().action)

        // This device is never signed out from here.
        repository.removeSession("ses-this")
        core.fail.remove("accountSessions.revoke")
        repository.removeSession("ses-other")
        await { state -> state.sessions?.map { it.id } == listOf("ses-this") }
        assertEquals(listOf("ses-other", "ses-other"), core.called("accountSessions.revoke").map { it.getString("id") })

        repository.removeOtherSessions()
        until { core.called("accountSessions.revokeOthers").isNotEmpty() }
    }

    @Test fun anotherAccountShowsOnlyItsOwnValues() = runBlocking<Unit> {
        signedIn()
        val release = CompletableDeferred<Unit>().also { core.hold["profile.update"] = it }
        repository.rename("Late")
        until { core.called("profile.update").isNotEmpty() }

        core.profile.value = core.profile(id = "usr_test_b", name = "Bea")
        sessions.scopes.value = scope(2, account = "usr_test_b")
        await { it.generation == 2L && it.profile?.name == "Bea" }
        // The late answer lands in place: nothing of it reaches the next account.
        release.complete(Unit)
        assertEquals(2L, repository.state.value.generation)
        assertEquals(AvatarSource.None, repository.state.value.avatar)
        assertTrue(notices.isEmpty())

        sessions.scopes.value = null
        await { it == SettingsState() }
    }

    @Test fun signedOutNothingIsAsked() = runBlocking<Unit> {
        signedIn()
        sessions.scopes.value = null
        await { it == SettingsState() }
        repository.rename("Nobody")
        repository.removeOtherSessions()
        assertTrue(core.called("profile.update").isEmpty())
        assertTrue(core.called("accountSessions.revokeOthers").isEmpty())
    }
}
