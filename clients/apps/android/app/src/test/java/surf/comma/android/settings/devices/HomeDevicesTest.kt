package surf.comma.android.settings.devices

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.scope
import surf.comma.android.settings.HomeDevice
import surf.comma.android.core.CoreError
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList

// All identifiers, names and credentials below are invented test data.
private val credentials = DeviceCredentials("dev_test_1", "salix_conn_test", "wss://connect.example.test/v1/connect",
    "gak_test", "salix_vk_test", "https://voice.example.test", "grp1_test")
class HomeDevicesTest {
    private class FakeBackend : HomeDeviceBackend {
        val calls = CopyOnWriteArrayList<String>()
        var devices = listOf<HomeDevice>()
        var failRevoke = false
        var accessError: Exception? = null
        /** Holds access changes until completed, to look at the state meanwhile. */
        var accessGate: CompletableDeferred<Unit>? = null
        /** Holds list loads until completed. */
        var listGate: CompletableDeferred<Unit>? = null

        override fun devices(): Flow<Result<List<HomeDevice>>> = flow {
            calls += "devices"
            val answer = devices
            listGate?.await()
            emit(Result.success(answer))
        }
        override suspend fun reload() { calls += "reload" }
        override suspend fun device(id: String) = devices.firstOrNull { it.id == id }
        override suspend fun rename(id: String, name: String) { calls += "rename $id $name" }
        override suspend fun remove(id: String) { calls += "remove $id"; devices = devices.filterNot { it.id == id } }
        override suspend fun setAccess(id: String, allow: Boolean): Boolean {
            calls += "access $id $allow"
            accessGate?.await()
            accessError?.let { throw it }
            devices = devices.map { if (it.id == id) it.copy(allowsOperations = allow) else it }
            return allow
        }
        override suspend fun provision(name: String, offer: String?): ProvisionedDevice {
            calls += "provision $name"
            return ProvisionedDevice(credentials, offerUpdated = offer != null)
        }
        override suspend fun unprovision(deviceId: String, connectorToken: String?, voiceKeyId: String?) {
            calls += "unprovision $deviceId $connectorToken $voiceKeyId"
            if (failRevoke) throw IOException("offline")
        }
    }

    private val backend = FakeBackend()
    private val sessions = FakeSessions().apply { scopes.value = scope(1) }
    private val scheduler = TestCoroutineScheduler()
    private val owner = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
    private val store = MemoryPairedDeviceStore()
    private var now = 1_800_000_000_000L
    private val devices = HomeDevices(sessions, { "wsp_test" }, store, owner, { now }, { _, _ -> backend }).apply { start() }

    @After fun tearDown() = owner.cancel()

    /** [source] null: the device never reported its host facts. */
    private fun device(id: String = "dev_test_1", online: Boolean = false, allows: Boolean = false,
                       source: String? = "t-circle") =
        HomeDevice(id, "Kitchen", online, source, null, allows)

    private fun listed(vararg list: HomeDevice) {
        backend.devices = list.toList()
        devices.refresh()
        waitFor { devices.state.value.devices?.size == list.size }
        backend.calls.clear()
    }

    /** The owner's work runs until it waits for something; then [condition] holds. */
    private fun waitFor(condition: () -> Boolean) {
        scheduler.runCurrent()
        assertTrue(condition())
    }

    @Test fun removingADeviceSetUpHereRevokesBothThenDeletesIt() = runBlocking {
        val owner = devices.currentOwner()!!
        devices.remember(owner, credentials, "Kitchen")
        devices.confirm(owner, "dev_test_1")
        assertTrue(devices.setUpHere("dev_test_1"))
        backend.devices = listOf(device(online = true))
        backend.calls.clear()

        devices.remove(device())
        waitFor { store.all().isEmpty() }
        assertEquals(listOf("unprovision dev_test_1 salix_conn_test gak_test", "remove dev_test_1"), backend.calls)
    }

    @Test fun removingADeviceSetUpElsewhereLeavesItsKeyToBeFoundByName() {
        assertFalse(devices.setUpHere("dev_test_2"))
        devices.remove(device("dev_test_2"))
        waitFor { "remove dev_test_2" in backend.calls }
        assertEquals(listOf("unprovision dev_test_2 null null", "remove dev_test_2"), backend.calls)
    }

    @Test fun aFailedRevocationKeepsTheDevice() = runBlocking {
        val owner = devices.currentOwner()!!
        devices.remember(owner, credentials, "Kitchen")
        backend.failRevoke = true
        backend.calls.clear()
        devices.remove(device())
        waitFor { devices.state.value.removing.isEmpty() && backend.calls.isNotEmpty() }
        assertFalse(backend.calls.any { it.startsWith("remove") })
        assertEquals(1, store.all().size)
    }

    @Test fun revokingOfflineKeepsARecordToRetryFrom() = runBlocking {
        val owner = devices.currentOwner()!!
        backend.failRevoke = true
        devices.revoke(owner, credentials)
        val kept = store.all().single()
        assertFalse(kept.confirmed)
        assertEquals("salix_conn_test", kept.connectorToken)

        // The next look at the list, once online, finishes the job.
        backend.failRevoke = false
        backend.calls.clear()
        devices.refresh()
        waitFor { store.all().isEmpty() }
        assertEquals(listOf("devices", "unprovision dev_test_1 salix_conn_test gak_test"), backend.calls)
    }

    @Test fun pendingSetupsAreConfirmedOrRevokedOnRefresh() = runBlocking {
        val owner = devices.currentOwner()!!
        devices.remember(owner, credentials, "Kitchen")

        // Recent and not seen yet: left alone.
        backend.calls.clear()
        devices.refresh()
        waitFor { devices.state.value.devices != null }
        assertEquals(listOf("devices"), backend.calls)
        assertFalse(store.all().single().confirmed)

        // Listed but never reported by the device: still unconfirmed.
        backend.devices = listOf(device(source = null))
        devices.refresh()
        waitFor { devices.state.value.devices?.singleOrNull() != null }
        assertFalse(store.all().single().confirmed)

        // Reported by the device once: it has its credentials.
        backend.devices = listOf(device())
        devices.refresh()
        waitFor { store.all().single().confirmed }

        // A second setup that never showed up, past the grace period: revoked.
        store.put(PairedDevice("usr_test_a", "wsp_test", "dev_test_9", "gak_nine", "salix_conn_nine", "Hall", now, false))
        now += DeviceCredentialRules.PENDING_GRACE_MILLIS + 1
        backend.calls.clear()
        devices.refresh()
        waitFor { store.all().size == 1 }
        assertTrue("unprovision dev_test_9 salix_conn_nine gak_nine" in backend.calls)
        assertEquals("dev_test_1", store.all().single().deviceId)
    }

    @Test fun aDeviceThatNeverReportedIsRevokedAfterTheGracePeriod() = runBlocking {
        val owner = devices.currentOwner()!!
        devices.remember(owner, credentials, "Kitchen")
        // The server lists a device reserved for the token, which never reported.
        backend.devices = listOf(device(source = null))
        now += DeviceCredentialRules.PENDING_GRACE_MILLIS + 1
        backend.calls.clear()
        devices.refresh()
        waitFor { store.all().isEmpty() }
        assertTrue("unprovision dev_test_1 salix_conn_test gak_test" in backend.calls)
    }

    @Test fun otherAccountsRecordsAreLeftAlone() {
        store.put(PairedDevice("usr_test_b", "wsp_other", "dev_test_8", "gak_eight", "salix_conn_eight", "Den", 0, false))
        devices.refresh()
        waitFor { devices.state.value.devices != null }
        assertEquals(listOf("devices"), backend.calls)
        assertEquals(1, store.all().size)
        assertFalse(devices.setUpHere("dev_test_8"))
    }

    @Test fun recordsDoNotPrintSecrets() {
        assertFalse(PairedDevice("a", "w", "d", "k", "salix_conn_test", "n", 0, false).toString().contains("salix_"))
    }

    @Test fun allowingShowsTheChangeUntilTheDeviceAnswers() {
        listed(device(online = true))
        val gate = CompletableDeferred<Unit>().also { backend.accessGate = it }
        devices.setAccess(device(online = true), true)
        waitFor { "access dev_test_1 true" in backend.calls }
        val pending = devices.state.value
        assertTrue(pending.allowsOperations(pending.devices!!.single()))
        assertFalse(pending.devices!!.single().allowsOperations)

        // A second tap while the device has not answered does nothing.
        devices.setAccess(device(online = true), false)
        gate.complete(Unit)
        waitFor { devices.state.value.accessPending.isEmpty() }
        val state = devices.state.value
        assertTrue(state.devices!!.single().allowsOperations)
        assertTrue(state.allowsOperations(state.devices!!.single()))
        assertEquals(listOf("access dev_test_1 true"), backend.calls)
        assertTrue(state.accessProblems.isEmpty())
    }

    @Test fun answersForTheAccountSignedOutOfLeaveTheNextOneAlone() {
        listed(device(online = true))
        val access = CompletableDeferred<Unit>().also { backend.accessGate = it }
        backend.accessError = CoreError("device_access_unavailable", "Unconfirmed.", 400)
        devices.setAccess(device(online = true), true)
        val list = CompletableDeferred<Unit>().also { backend.listGate = it }
        devices.refresh()
        waitFor { "access dev_test_1 true" in backend.calls && "devices" in backend.calls }

        // Another account (or workspace) signs in while both requests are on their way.
        sessions.scopes.value = scope(2, account = "usr_test_b")
        waitFor { devices.state.value == HomeDevicesState() }
        access.complete(Unit)
        list.complete(Unit)
        waitFor { owner.coroutineContext[Job]!!.children.count() == 1 }

        assertEquals(HomeDevicesState(), devices.state.value)
    }

    @Test fun anUnconfirmedChangeGoesBackAndSaysWhy() {
        listed(device(online = true, allows = true))
        backend.accessError = CoreError("device_access_unavailable", "Unconfirmed.", 400)
        devices.setAccess(device(online = true, allows = true), false)
        waitFor { devices.state.value.accessProblems.isNotEmpty() }
        val state = devices.state.value
        assertEquals(AccessProblem.UNCONFIRMED, state.accessProblems["dev_test_1"])
        assertTrue(state.allowsOperations(state.devices!!.single()))
        assertTrue(state.devices!!.single().online)

        // The next try starts clean.
        backend.accessError = null
        devices.setAccess(state.devices!!.single(), false)
        waitFor { devices.state.value.accessPending.isEmpty() && !devices.state.value.devices!!.single().allowsOperations }
        assertTrue(devices.state.value.accessProblems.isEmpty())
    }

    @Test fun anOfflineDeviceIsShownOffline() {
        listed(device(online = true))
        backend.accessError = CoreError("disconnected", "Offline.", 400)
        devices.setAccess(device(online = true), true)
        waitFor { devices.state.value.accessProblems.isNotEmpty() }
        val state = devices.state.value
        assertEquals(AccessProblem.OFFLINE, state.accessProblems["dev_test_1"])
        assertFalse(state.devices!!.single().online)
        assertFalse(state.allowsOperations(state.devices!!.single()))
    }

    @Test fun aNetworkFailureGoesBack() {
        listed(device(online = true))
        backend.accessError = IOException("Network unavailable")
        devices.setAccess(device(online = true), true)
        waitFor { devices.state.value.accessProblems.isNotEmpty() }
        val state = devices.state.value
        assertEquals(AccessProblem.NETWORK, state.accessProblems["dev_test_1"])
        assertFalse(state.allowsOperations(state.devices!!.single()))
        assertTrue(state.devices!!.single().online)
    }

    @Test fun refreshingOneDeviceReadsItsAccess() {
        listed(device(online = true), device("dev_test_2", online = false))
        backend.devices = listOf(device(online = true, allows = true), device("dev_test_2"))
        devices.refresh("dev_test_1")
        waitFor { devices.state.value.devices!!.first().allowsOperations }
        assertEquals(listOf("dev_test_1", "dev_test_2"), devices.state.value.devices!!.map { it.id })

        // Gone from the workspace: gone from the list.
        backend.devices = listOf(device(online = true, allows = true))
        devices.refresh("dev_test_2")
        waitFor { devices.state.value.devices!!.size == 1 }
    }
}
