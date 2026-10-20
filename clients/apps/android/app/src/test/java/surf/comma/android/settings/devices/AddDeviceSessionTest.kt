package surf.comma.android.settings.devices

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.auth.StorageFailure
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.scope
import surf.comma.android.settings.HomeDevice
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import surf.comma.android.settings.devices.AddDeviceEvent as Event

// All identifiers, names and credentials below are invented test data.
/** The session with a scripted device link and backend, on a dispatcher the test steps by hand. */
class AddDeviceSessionTest {
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun `picking a different device after fallback does not attach it to the offer`() {
        val attached = mutableListOf<String>()
        val session = AddDeviceSession(DeviceOwner(sessions.scopes.value!!, "wsp_test", backend), devices, scanner,
            { link }, process, preferredName = "Comma-FFFF", offer = "off_test",
            onOfferNotUpdated = { attached += "not updated" })
        scheduler.runCurrent()
        scheduler.advanceTimeBy(AddDeviceFlow.TIMEOUTS.getValue(FlowTimer.QUIET))
        scheduler.runCurrent()
        session.toMinting()
        assertTrue(attached.isEmpty())
        assertEquals(listOf("provision no offer"), backend.calls.toList())
        assertTrue(TCircleGatt.CREDENTIALS in link.writes)
        session.close()
        scheduler.runCurrent()
    }

    @Test fun `offer path skips the list and answers the offer with the device it sets up`() {
        val session = AddDeviceSession(DeviceOwner(sessions.scopes.value!!, "wsp_test", backend), devices, scanner,
            { link }, process, preferredName = device.name, offer = "off_test",
            onOfferNotUpdated = { backend.calls += "not updated" })
        scheduler.runCurrent()
        scanner.onFound!!(device)
        scheduler.runCurrent()
        assertTrue(session.step.value is AddDeviceStep.ChoosingWifi)
        session.send(Event.Join(home, "correct horse"))
        scheduler.runCurrent()
        assertEquals(listOf("provision off_test", "not updated"), backend.calls.toList())
        assertTrue(TCircleGatt.CREDENTIALS in link.writes)
        session.close()
        scheduler.runCurrent()
    }
    private class Backend : HomeDeviceBackend {
        val calls = CopyOnWriteArrayList<String>()
        /** Holds provisioning until completed. */
        var voiceGate: CompletableDeferred<Unit>? = null

        override fun devices() = flowOf(Result.success(emptyList<HomeDevice>()))
        override suspend fun reload() = Unit
        override suspend fun device(id: String): HomeDevice? = null
        override suspend fun rename(id: String, name: String) { calls += "rename $id" }
        override suspend fun remove(id: String) { calls += "remove $id" }
        override suspend fun setAccess(id: String, allow: Boolean) = allow
        override suspend fun provision(name: String, offer: String?): ProvisionedDevice {
            calls += "provision ${offer ?: "no offer"}"
            voiceGate?.await()
            return ProvisionedDevice(DeviceCredentials("dev_test_1", "salix_conn_test",
                "wss://connect.example.test/v1/connect", "gak_test", "salix_vk_test", "https://voice.example.test",
                "grp1_test"), offerUpdated = false)
        }
        override suspend fun unprovision(deviceId: String, connectorToken: String?, voiceKeyId: String?) {
            calls += "unprovision $deviceId"
        }
    }

    /** Answers a Wi-Fi scan with one network and joining with `wifi_up` on that network. */
    private class Link : DeviceLink {
        override val events = MutableSharedFlow<LinkEvent>(extraBufferCapacity = 16)
        val writes = CopyOnWriteArrayList<UUID>()

        override suspend fun connect() = Unit
        override suspend fun pair() = TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", "1.0", provisioned = false)
        override suspend fun write(characteristic: UUID, value: ByteArray): Int {
            writes += characteristic
            when (characteristic) {
                TCircleGatt.WIFI_SCAN -> notify(TCircleGatt.WIFI_SCAN,
                    """{"page":0,"pages":1,"aps":[{"ssid":"Home","rssi":-45,"secure":true}]}""")
                TCircleGatt.WIFI_CREDENTIALS -> notify(TCircleGatt.STATUS, """{"state":"wifi_up","ssid":"Home"}""")
            }
            return 0
        }
        override fun close() = Unit

        private fun notify(characteristic: UUID, json: String) {
            events.tryEmit(LinkEvent.Notification(characteristic, json.toByteArray()))
        }
    }

    /** A store whose writes fail while [broken], as when the phone's storage cannot be written. */
    private class Store : PairedDeviceStore {
        private val memory = MemoryPairedDeviceStore()
        @Volatile var broken = false
        override fun all() = memory.all()
        override fun put(device: PairedDevice) { if (broken) throw StorageFailure() else memory.put(device) }
        override fun remove(deviceId: String) { if (broken) throw StorageFailure() else memory.remove(deviceId) }
    }

    private class Scanner : DeviceScanner {
        var onFound: ((FoundDevice) -> Unit)? = null
        override fun start(onFound: (FoundDevice) -> Unit, onFailed: () -> Unit) { this.onFound = onFound }
        override fun stop() = Unit
    }

    private val scheduler = TestCoroutineScheduler()
    private val process = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
    private val backend = Backend()
    private val link = Link()
    private val scanner = Scanner()
    private val store = Store()
    private val sessions = FakeSessions().apply { scopes.value = scope(1) }
    private val devices = HomeDevices(sessions, { "wsp_test" }, store, process, backendFor = { _, _ -> backend })
    private val device = FoundDevice("C0:00:00:00:00:01", "Comma-5D28", -50)
    private val home = WifiNetwork("Home", -45, secure = true)

    @After fun tearDown() = process.cancel()

    private fun session() = AddDeviceSession(DeviceOwner(sessions.scopes.value!!, "wsp_test", backend), devices, scanner,
        { link }, process).also { scheduler.runCurrent() }

    /** Picks the device and joins [home], which starts minting its credentials. */
    private fun AddDeviceSession.toMinting() {
        scanner.onFound!!(device)
        send(Event.Pick(device))
        scheduler.runCurrent()
        assertTrue(step.value is AddDeviceStep.ChoosingWifi)
        send(Event.Join(home, "correct horse"))
        scheduler.runCurrent()
    }

    @Test fun credentialsQueuedBehindACancelAreRevoked() {
        val gate = CompletableDeferred<Unit>().also { backend.voiceGate = it }
        val session = session()
        session.toMinting()
        assertEquals(SetupPhase.MINTING, (session.step.value as AddDeviceStep.Setup).phase)

        // The minting finishes while the loop is still busy, and lands in the queue right after the
        // cancel: the flow has to see it after cancelling rather than drop it.
        gate.complete(Unit)
        session.send(Event.Rescan)
        session.close()
        scheduler.runCurrent()

        assertEquals(AddDeviceStep.Cancelled, session.step.value)
        assertTrue(backend.calls.toString(), "unprovision dev_test_1" in backend.calls)
        assertTrue(TCircleGatt.CREDENTIALS !in link.writes)
    }

    @Test fun credentialsAreWrittenOnlyAfterTheirRecordIsStored() {
        store.broken = true
        val session = session()
        session.toMinting()
        scheduler.runCurrent()

        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.STORAGE), session.step.value)
        assertTrue(TCircleGatt.CREDENTIALS !in link.writes)
        assertTrue(backend.calls.toString(), "unprovision dev_test_1" in backend.calls)
    }

    @Test fun aStoredRecordLetsTheCredentialsGoToTheDevice() {
        val session = session()
        session.toMinting()
        scheduler.runCurrent()

        assertEquals(SetupPhase.SAVING, (session.step.value as AddDeviceStep.Setup).phase)
        assertEquals(listOf("dev_test_1"), store.all().map { it.deviceId })
        assertTrue(TCircleGatt.CREDENTIALS in link.writes)
    }
}
