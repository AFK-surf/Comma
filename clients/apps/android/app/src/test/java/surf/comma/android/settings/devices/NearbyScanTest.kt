package surf.comma.android.settings.devices

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.advanceTimeBy
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.conversation.scope

@OptIn(ExperimentalCoroutinesApi::class)
class NearbyScanTest {
    private val advertisement = NearbyAdvertisement.parse(0xFFFF, byteArrayOf(1, 1, 0, 0x5D, 0x28))!!
    private val device = FoundDevice("random-session-address", "Comma-5D28", -58, advertisement)
    private val target = NearbyReportTarget(scope(1), "wsp_test", "phone-one")
    private class Scanner : DeviceScanner {
        var starts = 0
        var scanning = false
        lateinit var found: (FoundDevice) -> Unit
        override fun start(onFound: (FoundDevice) -> Unit, onFailed: () -> Unit) {
            starts++; scanning = true; found = onFound
        }
        override fun stop() { scanning = false }
    }
    private class History : NearbyReportHistory {
        val seen = mutableMapOf<String, Long>()
        override fun lastReported(target: NearbyReportTarget, shortId: String) = seen[shortId]
        override fun remember(target: NearbyReportTarget, shortId: String, now: Long) { seen[shortId] = now }
    }

    @Test fun `manufacturer payload requires the test company and supported version and model`() {
        assertEquals(NearbyAdvertisement(NearbyAdvertisement.SETUP_FAMILY_MODEL, "unprovisioned", "5D28"), advertisement)
        assertNull(NearbyAdvertisement.parse(0x1234, byteArrayOf(1, 1, 0, 0x5D, 0x28)))
        assertNull(NearbyAdvertisement.parse(0xFFFF, byteArrayOf(2, 1, 0, 0x5D, 0x28)))
        assertNull(NearbyAdvertisement.parse(0xFFFF, byteArrayOf(1, 1, 0, 0x5D)))
        assertNull(NearbyAdvertisement.parse(0xFFFF, null))
        assertNull(NearbyAdvertisement.parse(0xFFFF, byteArrayOf(1, 2, 0, 0x5D, 0x28)))
        assertEquals("ABFF", NearbyAdvertisement.parse(0xFFFF, byteArrayOf(1, 1, 1, 0xAB.toByte(), 0xFF.toByte()))!!.shortId)
    }

    @Test fun `scan stops at first unprovisioned match and reports only once for thirty minutes`() = runTest {
        val scanner = Scanner()
        val history = History()
        val reports = mutableListOf<FoundDevice>()
        val controller = NearbyScanController(scanner, backgroundScope, history, { _, requestId, found ->
            java.util.UUID.fromString(requestId)
            assertFalse(scanner.scanning)
            reports += found
            true
        }, now = { testScheduler.currentTime })
        controller.update(true, target, true, false)
        runCurrent()
        scanner.found(device.copy(advertisement = advertisement.copy(state = "pairing")))
        scanner.found(device.copy(advertisement = null))
        scanner.found(device.copy(name = "Comma-FFFF"))
        runCurrent()
        assertTrue(reports.isEmpty())
        scanner.found(device)
        scanner.found(device)
        runCurrent()
        assertEquals(listOf(device), reports)
        controller.update(true, target, true, false)
        runCurrent()
        assertEquals(1, scanner.starts)
        controller.update(false, target, true, false)
        controller.update(true, target, true, false)
        runCurrent()
        scanner.found(device)
        runCurrent()
        assertEquals(1, reports.size)
        advanceTimeBy(NearbyScanController.SCAN_MILLIS)
        runCurrent()
        assertFalse(scanner.scanning)
        advanceTimeBy(NearbyScanController.DEDUPE_MILLIS)
        controller.update(false, target, true, false)
        controller.update(true, target, true, false)
        runCurrent()
        scanner.found(device)
        runCurrent()
        assertEquals(2, reports.size)
    }

    @Test fun `permission sign in and Add device gate scans and background cancels immediately`() = runTest {
        val scanner = Scanner()
        var reports = 0
        val controller = NearbyScanController(scanner, backgroundScope, History(), { _, _, _ -> reports++; true })
        controller.update(true, null, true, false)
        controller.update(true, target, false, false)
        controller.update(true, target, true, true)
        runCurrent()
        assertEquals(0, scanner.starts)
        controller.update(true, target, true, false)
        runCurrent()
        val late = scanner.found
        controller.update(true, target, true, true)
        assertFalse(scanner.scanning)
        late(device)
        runCurrent()
        assertEquals(0, reports)
        controller.update(false, target, true, false)
        controller.update(true, target, true, false)
        runCurrent()
        controller.update(false, target, true, false)
        assertFalse(scanner.scanning)
        scanner.found(device)
        runCurrent()
        assertEquals(0, reports)
    }

    @Test fun `failed report is not persisted and retries on the next foreground`() = runTest {
        val scanner = Scanner()
        val history = History()
        var reports = 0
        val controller = NearbyScanController(scanner, backgroundScope, history, { _, _, _ -> reports++; false })
        repeat(2) {
            controller.update(true, target, true, false)
            runCurrent()
            scanner.found(device)
            runCurrent()
            controller.update(false, target, true, false)
        }
        assertEquals(2, reports)
        assertTrue(history.seen.isEmpty())
    }
}
