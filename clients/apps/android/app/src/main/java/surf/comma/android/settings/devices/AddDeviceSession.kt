package surf.comma.android.settings.devices

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import surf.comma.android.core.CoreError

/**
 * Runs one add-device flow: feeds BLE, backend and timer results into [AddDeviceFlow] one at a
 * time and carries out what it asks for. It lives in the process so the flow survives the settings
 * page being recreated; [close] cancels it, revoking credentials the device never confirmed.
 */
internal class AddDeviceSession(
    private val owner: DeviceOwner,
    private val devices: HomeDevices,
    private val scanner: DeviceScanner,
    private val linkFor: (FoundDevice) -> DeviceLink,
    /** Outlives the session: revocations and the final rename must finish after it closes. */
    private val process: CoroutineScope,
    private val pollMillis: Long = 2_000L,
    private val preferredName: String? = null,
    /** The setup offer this flow answers: the device set up for it is told it, when it is the offered one. */
    private val offer: String? = null,
    /** The offer could not be told of the device (setup goes on). */
    private val onOfferNotUpdated: () -> Unit = {},
) {
    private val flow = AddDeviceFlow(preferredName)
    private val work = CoroutineScope(process.coroutineContext + SupervisorJob(process.coroutineContext[Job]))
    private val events = Channel<AddDeviceEvent>(Channel.UNLIMITED)
    private val mutableStep = MutableStateFlow(flow.step)
    val step: StateFlow<AddDeviceStep> = mutableStep.asStateFlow()

    private var link: DeviceLink? = null
    private var linkJob: Job? = null
    private var watchJob: Job? = null
    private val scan = WifiScanCollector()

    init {
        work.launch {
            run(flow.start())
            for (event in events) {
                run(flow.handle(event))
                if (flow.step == AddDeviceStep.Cancelled) break
            }
            // Late results now fail to send, which tells the minting above to revoke on its own.
            events.close()
            // Results queued before the close still reach the flow, which revokes their credentials.
            for (event in events) run(flow.handle(event))
            work.cancel()
        }
    }

    fun send(event: AddDeviceEvent) {
        events.trySend(event)
    }

    fun close() = send(AddDeviceEvent.Cancel)

    private fun run(effects: List<AddDeviceEffect>) {
        mutableStep.value = flow.step
        effects.forEach(::execute)
    }

    private fun execute(effect: AddDeviceEffect) {
        when (effect) {
            AddDeviceEffect.StartScan -> scanner.start({ send(AddDeviceEvent.Found(it)) }, {})
            AddDeviceEffect.StopScan -> scanner.stop()
            is AddDeviceEffect.Connect -> connect(effect.device)
            AddDeviceEffect.Pair -> withLink { link ->
                try { send(AddDeviceEvent.Paired(link.pair())) } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    send(AddDeviceEvent.PairingFailed)
                }
            }
            AddDeviceEffect.ScanWifi -> withLink { link ->
                scan.reset()
                if (!accepted { link.write(TCircleGatt.WIFI_SCAN, "{}".toByteArray()) }) send(AddDeviceEvent.WifiScanFailed(busy = false))
            }
            is AddDeviceEffect.JoinWifi -> withLink { link ->
                val bytes = TCircleRules.wifiJson(effect.ssid, effect.password)
                // A refused write is a failed attempt; the person can pick again.
                if (!accepted { link.write(TCircleGatt.WIFI_CREDENTIALS, bytes) }) {
                    send(AddDeviceEvent.Status(TCircleStatus(TCircleStatus.WIFI_FAILED, effect.ssid, "failed", provisioned = false)))
                }
            }
            is AddDeviceEffect.Mint -> {
                // A fallback list selection may be a different board. Do not resolve this offer for it.
                val offeredDevice = (flow.step as? AddDeviceStep.Setup)?.device?.name == preferredName
                process.launch {
                    val event = try {
                        val answer = offer?.takeIf { offeredDevice }
                        val provisioned = owner.backend.provision(effect.name, answer)
                        if (answer != null && !provisioned.offerUpdated) onOfferNotUpdated()
                        AddDeviceEvent.Minted(provisioned.credentials, effect.attempt)
                    } catch (e: Exception) {
                        AddDeviceEvent.MintFailed(problem(e), effect.attempt)
                    }
                    // After the session ended nobody would revoke them; do it here.
                    if (!events.trySend(event).isSuccess && event is AddDeviceEvent.Minted) devices.revoke(owner, event.credentials)
                }
            }
            is AddDeviceEffect.Remember -> process.launch {
                send(try {
                    devices.remember(owner, effect.credentials, effect.name)
                    AddDeviceEvent.Remembered(effect.attempt)
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    AddDeviceEvent.RememberFailed(effect.attempt)
                })
            }
            is AddDeviceEffect.WriteCredentials -> withLink { link ->
                val status = try {
                    link.write(TCircleGatt.CREDENTIALS, TCircleRules.credentialsJson(effect.credentials, owner.workspaceId, effect.name))
                } catch (e: IllegalArgumentException) { 0x82 }
                send(if (status == 0) AddDeviceEvent.CredentialsWritten else AddDeviceEvent.WriteFailed(WriteRejection.of(status)))
            }
            is AddDeviceEffect.Confirm -> process.launch { runCatching { devices.confirm(owner, effect.deviceId) } }
            is AddDeviceEffect.Revoke -> process.launch { devices.revoke(owner, effect.credentials) }
            is AddDeviceEffect.WatchOnline -> {
                watchJob?.cancel()
                watchJob = work.launch {
                    while (true) {
                        val device = try { owner.backend.device(effect.deviceId) } catch (e: Exception) {
                            if (e is CancellationException) throw e
                            null
                        }
                        if (device?.online == true) { send(AddDeviceEvent.Online); return@launch }
                        delay(pollMillis)
                    }
                }
            }
            AddDeviceEffect.StopWatching -> { watchJob?.cancel(); watchJob = null }
            is AddDeviceEffect.Rename -> process.launch {
                runCatching { owner.backend.rename(effect.deviceId, effect.name) }
                devices.refresh()
            }
            AddDeviceEffect.Disconnect -> disconnect()
            is AddDeviceEffect.Arm -> work.launch {
                delay(effect.millis)
                send(AddDeviceEvent.TimedOut(effect.timer, effect.generation))
            }
        }
    }

    private fun connect(device: FoundDevice) {
        disconnect()
        val link = linkFor(device)
        this.link = link
        linkJob = work.launch {
            launch {
                link.events.collect { event ->
                    when (event) {
                        LinkEvent.Disconnected -> send(AddDeviceEvent.LinkLost)
                        is LinkEvent.Notification -> notification(event)
                    }
                }
            }
            try {
                link.connect()
                send(AddDeviceEvent.Connected)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                send(AddDeviceEvent.ConnectFailed)
            }
        }
    }

    private fun notification(event: LinkEvent.Notification) {
        when (event.characteristic) {
            TCircleGatt.STATUS -> TCircleStatus.parse(event.value)?.let { send(AddDeviceEvent.Status(it)) }
            TCircleGatt.WIFI_SCAN -> when (val result = scan.accept(event.value)) {
                is WifiScanCollector.Result.Done -> send(AddDeviceEvent.WifiScanned(result.networks))
                is WifiScanCollector.Result.Failed -> send(AddDeviceEvent.WifiScanFailed(result.busy))
                WifiScanCollector.Result.Pending -> Unit
            }
        }
    }

    private fun withLink(block: suspend (DeviceLink) -> Unit) {
        val link = link ?: return send(AddDeviceEvent.LinkLost)
        val parent = linkJob ?: return
        CoroutineScope(work.coroutineContext + Job(parent)).launch {
            try { block(link) } catch (e: Exception) {
                if (e is CancellationException) throw e
                send(AddDeviceEvent.LinkLost)
            }
        }
    }

    private suspend fun accepted(write: suspend () -> Int): Boolean = try { write() == 0 } catch (e: Exception) {
        if (e is CancellationException) throw e
        false
    }

    private fun disconnect() {
        linkJob?.cancel()
        linkJob = null
        link?.close()
        link = null
    }

    private fun problem(e: Exception): AddDeviceProblem = when {
        e is CoreError && e.status == 403 -> AddDeviceProblem.FORBIDDEN
        e is CoreError && e.status == 409 -> AddDeviceProblem.LIMIT
        e is CoreError && (e.status != null || e.code == "bad_response") -> AddDeviceProblem.SERVER
        else -> AddDeviceProblem.NETWORK
    }
}
