package surf.comma.android.settings.devices

/** A device advertising the setup service. [address] is only good for this pairing session. */
internal data class FoundDevice(val address: String, val name: String, val rssi: Int,
    val advertisement: NearbyAdvertisement? = null)

/** Credentials minted for one device. The secrets never appear in logs or strings. */
internal class DeviceCredentials(
    val deviceId: String,
    val connectorToken: String,
    /** The Connector's `wss://…/v1/connect`, exactly as the connector-token response gave it. */
    val connectUrl: String,
    val voiceKeyId: String,
    val voiceKey: String,
    val server: String,
    val groupId: String,
) {
    override fun toString() = "DeviceCredentials([redacted])"
}

internal enum class AddDeviceProblem {
    CONNECT_FAILED, PAIRING_FAILED, DISCONNECTED, TIMEOUT, REJECTED, SAVE_FAILED, NOT_ONLINE, NETWORK, SERVER, FORBIDDEN,
    /** The workspace holds the most voice keys it may. */
    LIMIT,
    /** The device saved its credentials, but the backend refused its connector token. */
    CONNECTOR_REJECTED,
    /** The phone could not store what it needs to revoke the new credentials later. */
    STORAGE,
}

internal enum class SetupPhase { JOINING_WIFI, MINTING, SAVING, COMING_ONLINE }

/** What the add-device page shows: scan, pair, Wi-Fi, setup, done, or a failure. */
internal sealed interface AddDeviceStep {
    /** [quiet]: nothing new turned up for a while, so the page explains pairing mode. */
    data class Scanning(val devices: List<FoundDevice>, val quiet: Boolean, val selectingName: String? = null) : AddDeviceStep
    /** [connected]: the link is up and the phone is asking for the code on the device's screen. */
    data class Pairing(val device: FoundDevice, val connected: Boolean) : AddDeviceStep
    /** [networks] is null until the first scan answers. [failure] is about [failedSsid]. */
    data class ChoosingWifi(
        val device: FoundDevice,
        val name: String,
        val networks: List<WifiNetwork>?,
        val scanning: Boolean,
        val scanFailed: Boolean,
        val failure: WifiFailure?,
        val failedSsid: String?,
        /** Offers keep the BLE name so the server can also match the device by its short id. */
        val nameEditable: Boolean = true,
    ) : AddDeviceStep
    /** [networks] are the Wi-Fi step's, shown again if joining fails. */
    data class Setup(
        val device: FoundDevice,
        val name: String,
        val ssid: String,
        val phase: SetupPhase,
        val networks: List<WifiNetwork>?,
    ) : AddDeviceStep
    /** [online] is false when the device saved its settings but has not reached Comma yet. */
    data class Done(val name: String, val deviceId: String, val online: Boolean) : AddDeviceStep
    data class Failed(val problem: AddDeviceProblem) : AddDeviceStep
    data object Cancelled : AddDeviceStep
}

internal enum class FlowTimer { QUIET, CONNECT, PAIR, WIFI_SCAN, JOIN, SAVE, ONLINE }

/** Work the flow asks for. The controller runs them and reports back with [AddDeviceEvent]s. */
internal sealed interface AddDeviceEffect {
    data object StartScan : AddDeviceEffect
    data object StopScan : AddDeviceEffect
    data class Connect(val device: FoundDevice) : AddDeviceEffect
    /** Reads `info`, pairing first (the system asks for the code), then subscribes to `status`. */
    data object Pair : AddDeviceEffect
    data object ScanWifi : AddDeviceEffect
    data class JoinWifi(val ssid: String, val password: String) : AddDeviceEffect {
        override fun toString() = "JoinWifi([redacted])"
    }
    /** [attempt] comes back with the result, so that a result from an earlier attempt is known. */
    data class Mint(val name: String, val attempt: Int) : AddDeviceEffect
    /**
     * Keeps what is needed to revoke [credentials] until the device confirms them. The credentials
     * go to the device only once this is stored.
     */
    data class Remember(val credentials: DeviceCredentials, val name: String, val attempt: Int) : AddDeviceEffect
    data class WriteCredentials(val credentials: DeviceCredentials, val name: String) : AddDeviceEffect
    /** The device reached Comma with them; they stay until the user removes the device. */
    data class Confirm(val deviceId: String) : AddDeviceEffect
    /** Revokes both credentials and forgets them. */
    data class Revoke(val credentials: DeviceCredentials) : AddDeviceEffect
    data class WatchOnline(val deviceId: String) : AddDeviceEffect
    data object StopWatching : AddDeviceEffect
    data class Rename(val deviceId: String, val name: String) : AddDeviceEffect
    data object Disconnect : AddDeviceEffect
    data class Arm(val timer: FlowTimer, val millis: Long, val generation: Int) : AddDeviceEffect
}

internal sealed interface AddDeviceEvent {
    data class Found(val device: FoundDevice) : AddDeviceEvent
    data class Pick(val device: FoundDevice) : AddDeviceEvent
    data object Connected : AddDeviceEvent
    data class Paired(val info: TCircleInfo) : AddDeviceEvent
    data object PairingFailed : AddDeviceEvent
    data object ConnectFailed : AddDeviceEvent
    data object LinkLost : AddDeviceEvent
    data class WifiScanned(val networks: List<WifiNetwork>) : AddDeviceEvent
    data class WifiScanFailed(val busy: Boolean) : AddDeviceEvent
    data object Rescan : AddDeviceEvent
    data class Rename(val name: String) : AddDeviceEvent
    data class Join(val network: WifiNetwork, val password: String) : AddDeviceEvent {
        override fun toString() = "Join([redacted])"
    }
    data class Status(val status: TCircleStatus) : AddDeviceEvent
    data class Minted(val credentials: DeviceCredentials, val attempt: Int) : AddDeviceEvent
    data class MintFailed(val problem: AddDeviceProblem, val attempt: Int) : AddDeviceEvent
    data class Remembered(val attempt: Int) : AddDeviceEvent
    data class RememberFailed(val attempt: Int) : AddDeviceEvent
    data object CredentialsWritten : AddDeviceEvent
    data class WriteFailed(val rejection: WriteRejection) : AddDeviceEvent
    data object Online : AddDeviceEvent
    data class TimedOut(val timer: FlowTimer, val generation: Int) : AddDeviceEvent
    data object Retry : AddDeviceEvent
    data object Cancel : AddDeviceEvent
}

/**
 * The add-device flow as a state machine, free of Android so it can be tested on the JVM.
 *
 * The order follows the device contract: Wi-Fi first, and only once the device is on the network
 * are the connector token and voice key minted, so a wrong password never leaves credentials behind.
 * Credentials minted for a setup that does not finish are revoked. When the link drops after they
 * were written, the device may or may not have saved them; the flow then waits to see it online.
 */
internal class AddDeviceFlow(private val preferredName: String? = null) {
    var step: AddDeviceStep = AddDeviceStep.Scanning(emptyList(), quiet = false)
        private set

    private var credentials: DeviceCredentials? = null
    /**
     * The device said `saved`: the flow keeps its credentials. Only coming online confirms them, so a
     * device that saved but never connects is still revoked by the reconciliation of pending setups.
     */
    private var saved = false
    private var timer: FlowTimer? = null
    /** The latest minting; results of earlier ones belong to setups that already ended. */
    private var mintAttempt = 0
    private var generation = 0

    fun start(): List<AddDeviceEffect> = scan()

    fun handle(event: AddDeviceEvent): List<AddDeviceEffect> {
        val current = step
        return when (event) {
            is AddDeviceEvent.TimedOut -> if (event.generation == generation && event.timer == timer) timedOut(event.timer) else none
            AddDeviceEvent.Cancel -> cancel()
            AddDeviceEvent.Retry -> if (current is AddDeviceStep.Failed) scan() else none
            // Credentials that arrive after the setup ended belong to nobody.
            is AddDeviceEvent.Minted -> minted(event.credentials, event.attempt)
            else -> when (current) {
                is AddDeviceStep.Scanning -> scanning(current, event)
                is AddDeviceStep.Pairing -> pairing(current, event)
                is AddDeviceStep.ChoosingWifi -> choosingWifi(current, event)
                is AddDeviceStep.Setup -> setup(current, event)
                is AddDeviceStep.Done, is AddDeviceStep.Failed, AddDeviceStep.Cancelled -> none
            }
        }
    }

    private fun scan(): List<AddDeviceEffect> {
        credentials = null
        saved = false
        step = AddDeviceStep.Scanning(emptyList(), quiet = false, selectingName = preferredName)
        return listOf(AddDeviceEffect.StartScan, arm(FlowTimer.QUIET))
    }

    private fun scanning(current: AddDeviceStep.Scanning, event: AddDeviceEvent): List<AddDeviceEffect> = when (event) {
        is AddDeviceEvent.Found -> {
            if (current.selectingName == event.device.name) scanning(current, AddDeviceEvent.Pick(event.device)) else {
                // Each pairing session advertises from a new address; a name shows once, newest first.
                val others = current.devices.filter { it.address != event.device.address && it.name != event.device.name }
                step = current.copy(devices = (others + event.device).sortedBy { it.name })
                none
            }
        }
        is AddDeviceEvent.Pick -> {
            step = AddDeviceStep.Pairing(event.device, connected = false)
            listOf(AddDeviceEffect.StopScan, AddDeviceEffect.Connect(event.device), arm(FlowTimer.CONNECT))
        }
        else -> none
    }

    private fun pairing(current: AddDeviceStep.Pairing, event: AddDeviceEvent): List<AddDeviceEffect> = when (event) {
        AddDeviceEvent.Connected -> if (current.connected) none else {
            step = current.copy(connected = true)
            listOf(AddDeviceEffect.Pair, arm(FlowTimer.PAIR))
        }
        is AddDeviceEvent.Paired -> {
            step = AddDeviceStep.ChoosingWifi(current.device,
                if (current.device.name == preferredName) preferredName else event.info.name, networks = null, scanning = true,
                scanFailed = false, failure = null, failedSsid = null, nameEditable = current.device.name != preferredName)
            listOf(AddDeviceEffect.ScanWifi, arm(FlowTimer.WIFI_SCAN))
        }
        AddDeviceEvent.ConnectFailed -> fail(AddDeviceProblem.CONNECT_FAILED)
        AddDeviceEvent.PairingFailed -> fail(AddDeviceProblem.PAIRING_FAILED)
        AddDeviceEvent.LinkLost -> fail(if (current.connected) AddDeviceProblem.PAIRING_FAILED else AddDeviceProblem.CONNECT_FAILED)
        else -> none
    }

    private fun choosingWifi(current: AddDeviceStep.ChoosingWifi, event: AddDeviceEvent): List<AddDeviceEffect> = when (event) {
        is AddDeviceEvent.WifiScanned -> {
            step = current.copy(networks = event.networks, scanning = false, scanFailed = false)
            disarm()
        }
        is AddDeviceEvent.WifiScanFailed -> {
            step = current.copy(scanning = false, scanFailed = true)
            disarm()
        }
        AddDeviceEvent.Rescan -> if (current.scanning) none else {
            step = current.copy(scanning = true, scanFailed = false)
            listOf(AddDeviceEffect.ScanWifi, arm(FlowTimer.WIFI_SCAN))
        }
        is AddDeviceEvent.Rename -> {
            if (current.nameEditable && TCircleRules.nameValid(event.name)) step = current.copy(name = event.name.trim())
            none
        }
        is AddDeviceEvent.Join -> if (!TCircleRules.passwordValid(event.network, event.password)) none else {
            step = AddDeviceStep.Setup(current.device, current.name, event.network.ssid, SetupPhase.JOINING_WIFI, current.networks)
            listOf(AddDeviceEffect.JoinWifi(event.network.ssid, event.password), arm(FlowTimer.JOIN))
        }
        AddDeviceEvent.LinkLost -> fail(AddDeviceProblem.DISCONNECTED)
        else -> none
    }

    private fun setup(current: AddDeviceStep.Setup, event: AddDeviceEvent): List<AddDeviceEffect> = when (current.phase) {
        SetupPhase.JOINING_WIFI -> when {
            event is AddDeviceEvent.Status && event.status.state == TCircleStatus.WIFI_FAILED -> backToWifi(current, event.status)
            // A provisioned device in pairing mode is already up on its stored network; wait for this one.
            event is AddDeviceEvent.Status && event.status.state == TCircleStatus.WIFI_UP &&
                (event.status.ssid == null || event.status.ssid == current.ssid) -> {
                step = current.copy(phase = SetupPhase.MINTING)
                listOf(AddDeviceEffect.Mint(current.name, ++mintAttempt)) + disarm()
            }
            event == AddDeviceEvent.LinkLost -> fail(AddDeviceProblem.DISCONNECTED)
            else -> none
        }
        SetupPhase.MINTING -> when (event) {
            is AddDeviceEvent.MintFailed -> if (event.attempt == mintAttempt) fail(event.problem) else none
            is AddDeviceEvent.Remembered -> {
                val minted = credentials
                if (event.attempt != mintAttempt || minted == null) none else {
                    step = current.copy(phase = SetupPhase.SAVING)
                    listOf(AddDeviceEffect.WriteCredentials(minted, current.name), arm(FlowTimer.SAVE))
                }
            }
            // Without a record nothing could revoke them later; take them back now.
            is AddDeviceEvent.RememberFailed ->
                if (event.attempt == mintAttempt && credentials != null) fail(AddDeviceProblem.STORAGE) else none
            // Minting goes on; its credentials are revoked when they arrive.
            AddDeviceEvent.LinkLost -> fail(AddDeviceProblem.DISCONNECTED)
            else -> none
        }
        SetupPhase.SAVING -> when {
            event is AddDeviceEvent.Status && event.status.state == TCircleStatus.SAVED -> {
                saved = true
                comingOnline(current, linked = true)
            }
            event is AddDeviceEvent.Status && event.status.saveFailed -> fail(AddDeviceProblem.SAVE_FAILED)
            event is AddDeviceEvent.WriteFailed -> fail(AddDeviceProblem.REJECTED)
            // The credentials may have been saved; whether the device comes online tells.
            event == AddDeviceEvent.LinkLost -> comingOnline(current, linked = false)
            else -> none
        }
        SetupPhase.COMING_ONLINE -> when {
            // The token is useless to the device; take back both credentials.
            event is AddDeviceEvent.Status && event.status.state == TCircleStatus.CONNECTOR_FAILED -> {
                saved = false
                fail(AddDeviceProblem.CONNECTOR_REJECTED)
            }
            event == AddDeviceEvent.Online -> {
                val deviceId = credentials?.deviceId ?: return none
                saved = true
                step = AddDeviceStep.Done(current.name, deviceId, online = true)
                listOf(AddDeviceEffect.Confirm(deviceId), AddDeviceEffect.StopWatching, AddDeviceEffect.Disconnect, AddDeviceEffect.Rename(deviceId, current.name)) +
                    disarm()
            }
            else -> none
        }
    }

    private fun backToWifi(current: AddDeviceStep.Setup, status: TCircleStatus): List<AddDeviceEffect> {
        step = AddDeviceStep.ChoosingWifi(current.device, current.name, current.networks, scanning = false, scanFailed = false,
            failure = status.wifiFailure, failedSsid = status.ssid ?: current.ssid, nameEditable = current.device.name != preferredName)
        return disarm()
    }

    private fun minted(minted: DeviceCredentials, attempt: Int): List<AddDeviceEffect> {
        val current = step
        if (attempt != mintAttempt || current !is AddDeviceStep.Setup || current.phase != SetupPhase.MINTING ||
            credentials != null) {
            return listOf(AddDeviceEffect.Revoke(minted))
        }
        credentials = minted
        return listOf(AddDeviceEffect.Remember(minted, current.name, attempt))
    }

    /** [linked]: the device answered `saved` over a link that is still up. */
    private fun comingOnline(current: AddDeviceStep.Setup, linked: Boolean): List<AddDeviceEffect> {
        val deviceId = credentials?.deviceId ?: return fail(AddDeviceProblem.DISCONNECTED)
        step = current.copy(phase = SetupPhase.COMING_ONLINE)
        // After `saved` the link stays up (the device closes it within 30 s) so a refused token is heard.
        return (if (linked) none else listOf(AddDeviceEffect.Disconnect)) +
            listOf(AddDeviceEffect.WatchOnline(deviceId), arm(FlowTimer.ONLINE))
    }

    private fun timedOut(timer: FlowTimer): List<AddDeviceEffect> {
        this.timer = null
        val current = step
        return when (timer) {
            FlowTimer.QUIET -> {
                if (current is AddDeviceStep.Scanning) step = current.copy(quiet = true, selectingName = null)
                none
            }
            FlowTimer.WIFI_SCAN -> {
                if (current is AddDeviceStep.ChoosingWifi) step = current.copy(scanning = false, scanFailed = true)
                none
            }
            FlowTimer.SAVE -> if (current is AddDeviceStep.Setup) comingOnline(current, linked = false) else none
            FlowTimer.ONLINE -> {
                val minted = credentials
                if (saved && current is AddDeviceStep.Setup && minted != null) {
                    // Saved on the device; it may still connect. Its credentials stay, unconfirmed, for the
                    // reconciliation of pending setups to keep or revoke.
                    step = AddDeviceStep.Done(current.name, minted.deviceId, online = false)
                    listOf(AddDeviceEffect.StopWatching, AddDeviceEffect.Disconnect)
                } else fail(AddDeviceProblem.NOT_ONLINE)
            }
            FlowTimer.CONNECT -> fail(AddDeviceProblem.CONNECT_FAILED)
            FlowTimer.PAIR, FlowTimer.JOIN -> fail(AddDeviceProblem.TIMEOUT)
        }
    }

    private fun cancel(): List<AddDeviceEffect> {
        val current = step
        if (current is AddDeviceStep.Done || current == AddDeviceStep.Cancelled) return none
        // A device that may have saved its credentials is left to the reconciliation of pending setups.
        val uncertain = current is AddDeviceStep.Setup && current.phase == SetupPhase.COMING_ONLINE
        val effects = end(revoke = !uncertain)
        step = AddDeviceStep.Cancelled
        return effects
    }

    private fun fail(problem: AddDeviceProblem): List<AddDeviceEffect> {
        val effects = end(revoke = true)
        step = AddDeviceStep.Failed(problem)
        return effects
    }

    /** Stops everything; revokes credentials the device has not confirmed. */
    private fun end(revoke: Boolean): List<AddDeviceEffect> {
        val minted = credentials
        credentials = null
        val revocation = if (revoke && minted != null && !saved) listOf(AddDeviceEffect.Revoke(minted)) else none
        return listOf(AddDeviceEffect.StopScan, AddDeviceEffect.StopWatching, AddDeviceEffect.Disconnect) + revocation + disarm()
    }

    private fun arm(next: FlowTimer): AddDeviceEffect {
        timer = next
        return AddDeviceEffect.Arm(next, TIMEOUTS.getValue(next), ++generation)
    }

    private fun disarm(): List<AddDeviceEffect> {
        timer = null
        generation++
        return none
    }

    companion object {
        private val none = emptyList<AddDeviceEffect>()
        val TIMEOUTS = mapOf(
            FlowTimer.QUIET to 15_000L,
            FlowTimer.CONNECT to 20_000L,
            // The person reads the code off the device and types it in.
            FlowTimer.PAIR to 120_000L,
            FlowTimer.WIFI_SCAN to 20_000L,
            // The device gives up on a network after 30 s.
            FlowTimer.JOIN to 45_000L,
            FlowTimer.SAVE to 20_000L,
            FlowTimer.ONLINE to 90_000L,
        )
    }
}
