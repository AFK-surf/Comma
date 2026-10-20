package surf.comma.android.voice

import org.json.JSONObject
import surf.comma.android.auth.SessionCipher
import surf.comma.android.auth.StorageFailure
import surf.comma.android.auth.requiredString
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

internal class VoiceKeyRecord(
    val accountId: String,
    val sessionId: String,
    val workspaceId: String,
    val keyId: String,
    val expiresAt: Long,
    val endpoint: VoiceEndpoint,
) {
    override fun toString() = "VoiceKeyRecord([redacted])"
}

internal interface VoiceKeyStore {
    fun read(): VoiceKeyRecord?
    fun write(record: VoiceKeyRecord)
    fun clear()
}

/** Stored in no-backup storage; the same Keystore AES-GCM key uses a distinct authenticated purpose. */
internal class EncryptedVoiceKeyStore(private val file: File, private val cipher: SessionCipher) : VoiceKeyStore {
    override fun read(): VoiceKeyRecord? = storage {
        if (!file.exists()) return@storage null
        require(file.length() <= 65_536)
        val bytes = cipher.decrypt(file.readBytes())
        try {
            val json = JSONObject(bytes.toString(Charsets.UTF_8))
            VoiceKeyRecord(json.requiredString("account_id"), json.requiredString("session_id"),
                json.requiredString("workspace_id"), json.requiredString("key_id"), json.getLong("expires_at"),
                VoiceEndpoint(json.requiredString("sessions_url"), json.requiredString("readiness_url"), json.requiredString("key")))
        } finally { bytes.fill(0) }
    }

    override fun write(record: VoiceKeyRecord) = storage {
        val bytes = JSONObject().put("account_id", record.accountId).put("session_id", record.sessionId)
            .put("workspace_id", record.workspaceId).put("key_id", record.keyId).put("expires_at", record.expiresAt)
            .put("sessions_url", record.endpoint.sessionsUrl).put("readiness_url", record.endpoint.readinessUrl)
            .put("key", record.endpoint.bearer).toString().toByteArray(Charsets.UTF_8)
        val temp = File(file.path + ".tmp")
        try {
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            temp.outputStream().use { it.write(cipher.encrypt(bytes)); it.fd.sync() }
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            Unit
        } finally { bytes.fill(0); temp.delete() }
    }

    override fun clear() = storage {
        Files.deleteIfExists(file.toPath())
        Files.deleteIfExists(File(file.path + ".tmp").toPath())
        Unit
    }

    private inline fun <T> storage(block: () -> T): T = try { block() } catch (_: Exception) { throw StorageFailure() }
}
