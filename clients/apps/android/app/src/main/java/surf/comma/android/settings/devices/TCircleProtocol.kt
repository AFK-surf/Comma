package surf.comma.android.settings.devices

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** The BLE setup service of a Comma device (T-Circle). All values are UTF-8 JSON. */
internal object TCircleGatt {
    val SERVICE: UUID = uuid(0x0001)
    val WIFI_SCAN: UUID = uuid(0x0002)
    val WIFI_CREDENTIALS: UUID = uuid(0x0003)
    val CREDENTIALS: UUID = uuid(0x0004)
    val STATUS: UUID = uuid(0x0005)
    val INFO: UUID = uuid(0x0006)
    val CLIENT_CONFIG: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val MTU = 517
    /** The device rejects longer writes with ATT error 0x0D. */
    const val MAX_WRITE_BYTES = 512

    private fun uuid(short: Int) = UUID.fromString("f2d2%04x-eb8e-4a64-9ec7-ab0cbb8107c8".format(short))
}

/** What `info` says about the device. [mac] is its stable identity; the BLE address changes each session. */
internal data class TCircleInfo(val mac: String, val name: String, val firmware: String?, val provisioned: Boolean) {
    companion object {
        fun parse(bytes: ByteArray): TCircleInfo? = json(bytes)?.let {
            val mac = it.text("mac") ?: return null
            TCircleInfo(mac, it.text("name") ?: mac, it.text("fw_version"), it.optBoolean("provisioned"))
        }
    }
}

internal data class WifiNetwork(val ssid: String, val rssi: Int, val secure: Boolean)

/** Collects the pages of one `wifi_scan` answer. Pages may arrive in any order. */
internal class WifiScanCollector {
    sealed interface Result {
        data object Pending : Result
        data class Done(val networks: List<WifiNetwork>) : Result
        /** [busy]: a Wi-Fi connection attempt is running; scan again once it ends. */
        data class Failed(val busy: Boolean) : Result
    }

    private var pages = 0
    private val received = mutableMapOf<Int, List<WifiNetwork>>()

    fun accept(bytes: ByteArray): Result {
        val json = json(bytes) ?: return Result.Pending
        json.text("error")?.let { reset(); return Result.Failed(busy = it == "busy") }
        val total = json.optInt("pages", 0)
        val page = json.optInt("page", -1)
        if (total !in 1..MAX_PAGES || page !in 0 until total) return Result.Pending
        // A page from a newer scan restarts the collection.
        if (total != pages) reset().also { pages = total }
        val aps = json.optJSONArray("aps") ?: JSONArray()
        received[page] = (0 until aps.length()).mapNotNull { index ->
            val ap = aps.optJSONObject(index) ?: return@mapNotNull null
            val ssid = ap.text("ssid") ?: return@mapNotNull null
            WifiNetwork(ssid, ap.optInt("rssi", -100), ap.optBoolean("secure", true))
        }
        if (received.size < pages) return Result.Pending
        val networks = (0 until pages).flatMap { received[it].orEmpty() }
            .groupBy { it.ssid }.map { (_, same) -> same.maxBy { it.rssi } }
            .sortedByDescending { it.rssi }
        reset()
        return Result.Done(networks)
    }

    fun reset() {
        pages = 0
        received.clear()
    }

    private companion object { const val MAX_PAGES = 32 }
}

/** Why the device could not join the network. */
internal enum class WifiFailure {
    WRONG_PASSWORD, NOT_FOUND, TIMEOUT, FAILED;

    companion object {
        fun parse(value: String?) = when (value) {
            "wrong_password" -> WRONG_PASSWORD
            "not_found" -> NOT_FOUND
            "timeout" -> TIMEOUT
            else -> FAILED
        }
    }
}

/** One `status` value. Unknown states are kept as [state] and otherwise ignored. */
internal data class TCircleStatus(
    val state: String,
    val ssid: String?,
    val error: String?,
    val provisioned: Boolean,
) {
    val wifiFailure: WifiFailure? get() = if (state == WIFI_FAILED) WifiFailure.parse(error) else null
    /** Wi-Fi is up but storing the credentials failed. */
    val saveFailed: Boolean get() = state == WIFI_UP && error == "save_failed"

    companion object {
        const val IDLE = "idle"
        const val WIFI_CONNECTING = "wifi_connecting"
        const val WIFI_FAILED = "wifi_failed"
        const val WIFI_UP = "wifi_up"
        const val SAVED = "saved"
        const val CONNECTOR_FAILED = "connector_failed"

        fun parse(bytes: ByteArray): TCircleStatus? = json(bytes)?.let {
            TCircleStatus(it.text("state") ?: return null, it.text("ssid"), it.text("error"), it.optBoolean("provisioned"))
        }
    }
}

/** ATT errors from a rejected write, as `onCharacteristicWrite` reports them. */
internal enum class WriteRejection {
    NOT_PAIRED, TOO_LONG, INVALID;

    companion object {
        fun of(status: Int): WriteRejection = when (status) {
            0x05, 0x0F -> NOT_PAIRED
            0x0D -> TOO_LONG
            else -> INVALID
        }
    }
}

/** The device's limits on what can be written to it. */
internal object TCircleRules {
    const val NAME_MAX_BYTES = 63
    private const val SSID_MAX_BYTES = 32
    private const val SERVER_MAX_BYTES = 127
    private const val CONNECT_URL_MAX_BYTES = 159
    private const val ID_MAX_BYTES = 95
    private const val SECRET_MAX_BYTES = 159

    fun nameValid(name: String): Boolean = name.trim().let { it.isNotEmpty() && it.utf8() <= NAME_MAX_BYTES }

    /** An open network takes no password; a secured one 8 to 64 characters. */
    fun passwordValid(network: WifiNetwork, password: String): Boolean =
        if (network.secure) password.length in 8..64 else password.isEmpty()

    fun wifiJson(ssid: String, password: String): ByteArray {
        require(ssid.utf8() in 1..SSID_MAX_BYTES) { "Invalid network" }
        require(password.isEmpty() || password.length in 8..64) { "Invalid password" }
        return JSONObject().put("ssid", ssid).put("password", password).toString().toByteArray(Charsets.UTF_8)
    }

    /** The `credentials` value; fails rather than send something the device would refuse. */
    fun credentialsJson(credentials: DeviceCredentials, workspaceId: String, deviceName: String): ByteArray {
        val name = deviceName.trim()
        require(nameValid(name)) { "Invalid name" }
        require(credentials.server.utf8() <= SERVER_MAX_BYTES && credentials.server.matches(HTTP))
        require(credentials.connectUrl.utf8() <= CONNECT_URL_MAX_BYTES && credentials.connectUrl.matches(SOCKET))
        require(workspaceId.utf8() in 1..ID_MAX_BYTES && credentials.groupId.utf8() in 1..ID_MAX_BYTES)
        require(credentials.connectorToken.utf8() in 1..SECRET_MAX_BYTES && credentials.voiceKey.utf8() in 1..SECRET_MAX_BYTES)
        require(credentials.connectorToken.startsWith("salix_conn_") && credentials.voiceKey.startsWith("salix_vk_"))
        val json = JSONObject()
            .put("server", credentials.server)
            // As the connector-token response gave it: the Salix host, not the API host.
            .put("connect_url", credentials.connectUrl)
            .put("workspace_id", workspaceId)
            .put("group_id", credentials.groupId)
            .put("connector_token", credentials.connectorToken)
            .put("voice_key", credentials.voiceKey)
            .put("device_name", name)
        val bytes = json.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= TCircleGatt.MAX_WRITE_BYTES) { "Credentials too long" }
        return bytes
    }

    private fun String.utf8() = toByteArray(Charsets.UTF_8).size
    private val HTTP = Regex("^https?://.+")
    private val SOCKET = Regex("^wss?://.+")
}

private fun json(bytes: ByteArray): JSONObject? =
    try { JSONObject(bytes.toString(Charsets.UTF_8)) } catch (_: Exception) { null }

private fun JSONObject.text(key: String): String? =
    if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }
