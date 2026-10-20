package surf.comma.android.settings.devices

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import surf.comma.android.auth.ConversationScope
import java.util.UUID

internal data class NearbyReportTarget(val scope: ConversationScope, val workspaceId: String, val reporterId: String)

internal interface NearbyReportHistory {
    fun lastReported(target: NearbyReportTarget, shortId: String): Long?
    fun remember(target: NearbyReportTarget, shortId: String, now: Long)
}

/** One bounded attempt per foreground. All state changes run on the owning dispatcher. */
internal class NearbyScanController(
    private val scanner: DeviceScanner,
    private val owner: CoroutineScope,
    private val history: NearbyReportHistory,
    private val report: suspend (NearbyReportTarget, String, FoundDevice) -> Boolean,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private var foreground = false
    private var attempted = false
    private var target: NearbyReportTarget? = null
    private var job: Job? = null
    private var scanGeneration = 0

    fun update(foreground: Boolean, target: NearbyReportTarget?, canScan: Boolean, addDeviceOpen: Boolean) {
        if (!foreground) attempted = false
        this.foreground = foreground
        if (!foreground || target != this.target || !canScan || addDeviceOpen) {
            scanGeneration++
            job?.cancel()
            job = null
            scanner.stop()
        }
        this.target = target
        if (!foreground || target == null || !canScan || addDeviceOpen || attempted) return
        attempted = true
        val generation = ++scanGeneration
        job = owner.launch {
            val match = CompletableDeferred<FoundDevice?>()
            try {
                scanner.start({ device ->
                    owner.launch found@{
                        if (generation != scanGeneration || !this@NearbyScanController.foreground ||
                            match.isCompleted || !eligible(device, target)) return@found
                        match.complete(device)
                    }
                }, { match.complete(null) })
                val device = try { withTimeoutOrNull(SCAN_MILLIS) { match.await() } }
                    finally { if (generation == scanGeneration) scanner.stop() }
                if (device != null && report(target, UUID.randomUUID().toString(), device)) {
                    history.remember(target, device.advertisement!!.shortId, now())
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                // A denied or failed report is retried only on a later foreground.
            } finally {
                if (generation == scanGeneration) scanner.stop()
                match.cancel()
            }
        }
    }

    private fun eligible(device: FoundDevice, target: NearbyReportTarget): Boolean {
        val ad = device.advertisement ?: return false
        if (ad.state != "unprovisioned" || device.name != ad.name) return false
        val last = history.lastReported(target, ad.shortId) ?: return true
        return now() - last >= DEDUPE_MILLIS
    }

    companion object {
        const val SCAN_MILLIS = 8_000L
        const val DEDUPE_MILLIS = 30 * 60 * 1000L
    }
}
