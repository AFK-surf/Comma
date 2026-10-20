package surf.comma.android.auth

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class StorageFailure : IOException("Private session storage unavailable")

/** Version + random 96-bit nonce + AES-GCM ciphertext/tag; the format is authenticated. */
internal class SessionCipher(
    private val purpose: String = "comma.session.v1",
    private val key: () -> SecretKey,
) {
    fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(purpose.toByteArray(Charsets.UTF_8))
        check(cipher.iv.size == 12)
        return byteArrayOf(1) + cipher.iv + cipher.doFinal(plaintext)
    }
    fun decrypt(bytes: ByteArray): ByteArray {
        require(bytes.size >= 29 && bytes[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        cipher.updateAAD(purpose.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(bytes, 13, bytes.size - 13)
    }
}

/**
 * The sign-outs an earlier version queued (`pending-logouts`, one encrypted file per credential): each credential
 * still to sign out, and when it expires. Read once, to hand them to the credential store.
 */
internal class EarlierLogouts(private val root: File, private val cipher: SessionCipher) {
    /** The ids of the records, which the earlier version also named its scheduled work by. */
    fun ids(): List<String> = runCatching {
        root.listFiles().orEmpty().filter { it.extension == "bin" && ID.matches(it.nameWithoutExtension) }.map { it.nameWithoutExtension }
    }.getOrDefault(emptyList())

    /** The credential of record [id] and when it expires, when the record asked for a sign-out; null otherwise. */
    fun read(id: String): Pair<String, Long>? = runCatching {
        val file = File(root, "$id.bin")
        require(file.length() <= 65_536)
        val plaintext = cipher.decrypt(file.readBytes())
        try {
            val json = JSONObject(plaintext.toString(Charsets.UTF_8))
            if (!json.optBoolean("logout_session", true)) null else json.requiredString("token") to json.getLong("expires_at")
        } finally { plaintext.fill(0) }
    }.getOrNull()

    fun delete() { root.deleteRecursively() }

    private companion object { val ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") }
}

internal class EncryptedSessionStore(private val file: File, private val cipher: SessionCipher) : SessionStore {
    override fun read(): Session? = storage {
        if (!file.exists()) return@storage null
        require(file.length() <= 65_536)
        val plaintext = cipher.decrypt(file.readBytes())
        try {
            val json = JSONObject(plaintext.toString(Charsets.UTF_8))
            json.session(SessionToken(json.requiredString("token")))
        } finally { plaintext.fill(0) }
    }
    override fun write(session: Session) = storage {
        val user = session.user
        val plaintext = JSONObject().put("token", session.token.value).put("expires_at", session.expiresAt)
            .put("session_id", session.sessionId).put("user", JSONObject().put("id", user.id)
                .put("email", user.email).put("name", user.name ?: JSONObject.NULL).put("status", user.status))
            .toString().toByteArray(Charsets.UTF_8)
        try { atomicWrite(file, cipher.encrypt(plaintext)) } finally { plaintext.fill(0) }
    }
    override fun clear() = storage {
        Files.deleteIfExists(file.toPath())
        Files.deleteIfExists(File(file.path + ".tmp").toPath())
        Unit
    }
}

private inline fun <T> storage(block: () -> T): T = try { block() } catch (_: Exception) { throw StorageFailure() }
private fun atomicWrite(file: File, bytes: ByteArray) {
    check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
    val temp = File(file.path + ".tmp")
    try {
        temp.outputStream().use { it.write(bytes); it.fd.sync() }
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    } finally { temp.delete() }
}

internal fun JSONObject.requiredString(key: String): String = optString(key).takeIf { it.isNotBlank() && it != "null" }
    ?: throw StorageFailure()
private fun JSONObject.account(): Account = Account(requiredString("id"), requiredString("email"),
    if (isNull("name")) null else optString("name"), requiredString("status"))
internal fun JSONObject.session(token: SessionToken): Session = Session(token,
    optLong("expires_at").takeIf { it > 0 } ?: throw StorageFailure(), requiredString("session_id"),
    optJSONObject("user")?.account() ?: throw StorageFailure())
