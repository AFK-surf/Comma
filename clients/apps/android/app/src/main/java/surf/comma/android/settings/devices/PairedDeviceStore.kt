package surf.comma.android.settings.devices

import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.SessionCipher
import surf.comma.android.auth.StorageFailure
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * What this phone needs to revoke a Comma device's credentials later: the server keeps only the
 * connector token's hash, so revoking it takes the token itself. [confirmed] is false from minting
 * until the device has connected with the credentials; unconfirmed records are revoked if the device never
 * shows up.
 */
internal class PairedDevice(
    val accountId: String,
    val workspaceId: String,
    val deviceId: String,
    val voiceKeyId: String,
    val connectorToken: String,
    val name: String,
    val createdAtMillis: Long,
    val confirmed: Boolean,
) {
    fun confirmed() = PairedDevice(accountId, workspaceId, deviceId, voiceKeyId, connectorToken, name, createdAtMillis, true)
    override fun toString() = "PairedDevice([redacted])"
}

internal interface PairedDeviceStore {
    fun all(): List<PairedDevice>
    fun put(device: PairedDevice)
    fun remove(deviceId: String)
}

internal class MemoryPairedDeviceStore : PairedDeviceStore {
    private val devices = linkedMapOf<String, PairedDevice>()
    @Synchronized override fun all() = devices.values.toList()
    @Synchronized override fun put(device: PairedDevice) { devices[device.deviceId] = device }
    @Synchronized override fun remove(deviceId: String) { devices.remove(deviceId) }
}

/** One encrypted file in no-backup storage, rewritten atomically on each change. */
internal class EncryptedPairedDeviceStore(private val file: File, private val cipher: SessionCipher) : PairedDeviceStore {
    @Synchronized override fun all(): List<PairedDevice> = storage {
        if (!file.exists()) return@storage emptyList()
        require(file.length() <= MAX_BYTES)
        val bytes = cipher.decrypt(file.readBytes())
        try {
            val array = JSONArray(bytes.toString(Charsets.UTF_8))
            (0 until array.length()).map { index ->
                val json = array.getJSONObject(index)
                PairedDevice(json.getString("account_id"), json.getString("workspace_id"), json.getString("device_id"),
                    json.getString("voice_key_id"), json.getString("connector_token"), json.getString("name"),
                    json.getLong("created_at"), json.getBoolean("confirmed"))
            }
        } finally { bytes.fill(0) }
    }

    @Synchronized override fun put(device: PairedDevice) = write(all().filterNot { it.deviceId == device.deviceId } + device)

    @Synchronized override fun remove(deviceId: String) {
        val devices = all()
        if (devices.any { it.deviceId == deviceId }) write(devices.filterNot { it.deviceId == deviceId })
    }

    private fun write(devices: List<PairedDevice>) = storage {
        val array = JSONArray()
        devices.forEach {
            array.put(JSONObject().put("account_id", it.accountId).put("workspace_id", it.workspaceId)
                .put("device_id", it.deviceId).put("voice_key_id", it.voiceKeyId).put("connector_token", it.connectorToken)
                .put("name", it.name).put("created_at", it.createdAtMillis).put("confirmed", it.confirmed))
        }
        val bytes = array.toString().toByteArray(Charsets.UTF_8)
        val temp = File(file.path + ".tmp")
        try {
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            temp.outputStream().use { it.write(cipher.encrypt(bytes)); it.fd.sync() }
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            Unit
        } finally { bytes.fill(0); temp.delete() }
    }

    private inline fun <T> storage(block: () -> T): T = try { block() } catch (_: Exception) { throw StorageFailure() }

    private companion object { const val MAX_BYTES = 262_144L }
}
