package surf.comma.android.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Encrypts the credential file (the app's: an Android Keystore key). */
interface Sealer {
    fun seal(plaintext: ByteArray): ByteArray
    fun open(sealed: ByteArray): ByteArray
}

/** A session credential the app keeps. The bearer never leaves this module. */
class StoredCredential(
    val token: String,
    val audience: String,
    val sessionId: String,
    val userId: String,
    val email: String,
    val expiresAtEpochSeconds: Long,
) {
    override fun toString() = "StoredCredential([redacted])"
}

/** A credential to revoke at the server. */
class PendingRevocation(val token: String, val audience: String, val sessionId: String?) {
    override fun toString() = "PendingRevocation([redacted])"
}

/** The session a product request is made for (no credential in it). */
data class SessionLease(val audience: String, val authorityInstanceId: String, val generation: Long, val sessionId: String) {
    fun toJson(): JSONObject = JSONObject().put("audience", audience).put("authorityInstanceId", authorityInstanceId)
        .put("generation", generation).put("sessionId", sessionId)

    companion object {
        fun from(json: JSONObject?): SessionLease? {
            json ?: return null
            val audience = json.optString("audience")
            val authority = json.optString("authorityInstanceId")
            val session = json.optString("sessionId")
            if (audience.isEmpty() || authority.isEmpty() || session.isEmpty() || !json.has("generation")) return null
            return SessionLease(audience, authority, json.optLong("generation"), session)
        }
    }
}

/**
 * The bearer for exactly one lease, while that lease is the open one. [bearer] is for the app's own requests to the
 * Comma API (media, voice, devices): it is never logged, stored or given to the core.
 */
class LeasedCredential(val lease: SessionLease, private val token: String, internal val epoch: Long) {
    fun bearer(): String = token
    override fun toString() = "LeasedCredential([redacted])"
}

/** Whose credential the store keeps, without the bearer. */
data class StoredIdentity(val userId: String, val email: String, val sessionId: String, val expiresAtEpochSeconds: Long)

/**
 * The app's part of the session, as Electron's main process has it. The client core runs the session lifecycle and
 * is its authority; the app keeps what the core must never see:
 *
 * - the bearer, in one encrypted file ([file], [sealer]). The core names credentials by opaque references and asks
 *   for the store to be changed by reference ([vault], [change]);
 * - a bearer in an auth answer ([keepBearer]): taken out and kept here, the core answered a reference instead;
 * - the gate ([gate]): it follows each snapshot the core publishes and gives the bearer for exactly the current
 *   lease ([acquire]). A 401 shuts it at once ([revoke]), and that generation never opens again.
 *
 * All of it is guarded by one lock; the file is written before a change is answered.
 */
class SessionCustody(
    private val file: File,
    private val sealer: Sealer,
    apiOrigin: String,
    val authorityInstanceId: String = UUID.randomUUID().toString(),
) {
    val audience: String = canonicalAudience(apiOrigin)

    private class Issued(val token: String, val credential: StoredCredential?, val sessionId: String?, val request: Long?)

    private val lock = Any()
    private var loaded = false
    private var unreadable = false
    private var active: StoredCredential? = null
    private var pending = ArrayList<PendingRevocation>()

    private val issued = HashMap<String, Issued>()
    private val committed = HashSet<String>()
    private val refs = HashMap<String, String>()
    private val tokens = HashMap<String, String>()

    // The gate.
    private var snapshot: JSONObject? = null
    private var revision = 0L
    private var generation = 0L
    private var revokedGeneration = -1L
    private var open: LeasedCredential? = null
    private var epoch = 0L
    private val listeners = ArrayList<(JSONObject) -> Unit>()

    // --- The store ----------------------------------------------------------------------------------------------

    private fun load() {
        if (loaded) return
        loaded = true
        unreadable = false
        active = null
        pending = ArrayList()
        if (!file.exists()) return
        try {
            require(file.length() <= MAX_FILE_BYTES)
            val plaintext = sealer.open(file.readBytes())
            try {
                val json = JSONObject(String(plaintext, Charsets.UTF_8))
                active = json.optJSONObject("active")?.let(::credentialOf)
                val list = json.optJSONArray("pending") ?: JSONArray()
                for (index in 0 until list.length()) {
                    val item = list.getJSONObject(index)
                    pending.add(PendingRevocation(item.getString("token"), item.getString("audience"),
                        item.optString("sessionId").takeIf { it.isNotEmpty() }))
                }
            } finally { plaintext.fill(0) }
        } catch (_: Exception) {
            unreadable = true
            active = null
            pending = ArrayList()
        }
    }

    private fun credentialOf(json: JSONObject) = StoredCredential(json.getString("token"), json.getString("audience"),
        json.getString("sessionId"), json.getString("userId"), json.getString("email"), json.getLong("expiresAtEpochSeconds"))

    /** Writes the store; a failure leaves memory as the file is (read again), and throws. */
    private fun save(nextActive: StoredCredential?, nextPending: List<PendingRevocation>) {
        val json = JSONObject()
        nextActive?.let {
            json.put("active", JSONObject().put("token", it.token).put("audience", it.audience)
                .put("sessionId", it.sessionId).put("userId", it.userId).put("email", it.email)
                .put("expiresAtEpochSeconds", it.expiresAtEpochSeconds))
        }
        json.put("pending", JSONArray().apply {
            for (item in nextPending) put(JSONObject().put("token", item.token).put("audience", item.audience)
                .apply { item.sessionId?.let { put("sessionId", it) } })
        })
        val plaintext = json.toString().toByteArray(Charsets.UTF_8)
        try {
            val parent = file.parentFile!!
            check(parent.isDirectory || parent.mkdirs())
            val temp = File(file.path + ".tmp")
            try {
                temp.outputStream().use { it.write(sealer.seal(plaintext)); it.fd.sync() }
                Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } finally { temp.delete() }
        } catch (e: Exception) {
            loaded = false
            throw e
        } finally { plaintext.fill(0) }
        active = nextActive
        pending = ArrayList(nextPending)
        unreadable = false
    }

    private fun queued(token: String) = pending.any { it.token == token }

    private fun view(): JSONObject {
        if (unreadable) return JSONObject().put("status", "indeterminate").put("problem", JSONObject()
            .put("code", "credential_store_unreadable").put("operation", "initialize")
            .put("recovery", "after_host_change").put("retryable", false))
        val out = JSONObject().put("status", "readable")
        out.put("active", active?.let {
            JSONObject().put("ref", refFor(it.token)).put("audience", it.audience).put("sessionId", it.sessionId)
                .put("userId", it.userId).put("email", it.email).put("expiresAtEpochSeconds", it.expiresAtEpochSeconds)
        } ?: JSONObject.NULL)
        out.put("pending", JSONArray().apply {
            for (item in pending) put(JSONObject().put("ref", refFor(item.token)).put("audience", item.audience)
                .apply { item.sessionId?.let { put("sessionId", it) } })
        })
        out.put("cleanup", if (pending.isEmpty()) JSONObject().put("revocation", "idle")
            else JSONObject().put("revocation", "pending").put("pendingCount", pending.size))
        return out
    }

    /** Whose credential is kept, if any: known before the server confirms its session, and offline. */
    fun identity(): StoredIdentity? = synchronized(lock) {
        load()
        active?.takeIf { it.audience == audience }?.let { StoredIdentity(it.userId, it.email, it.sessionId, it.expiresAtEpochSeconds) }
    }

    /**
     * A credential the app kept before it had this store (an earlier version's session file) becomes the active one.
     * Only when the store has no file yet; true when it was taken.
     */
    fun adoptEarlier(credential: StoredCredential): Boolean = synchronized(lock) {
        if (file.exists()) return false
        loaded = true
        save(credential, emptyList())
        true
    }

    /**
     * Credentials an earlier version queued to sign out: the core revokes them with its own. False when the store
     * cannot take them now (unreadable, or the write failed).
     */
    fun adoptRevocations(earlier: List<PendingRevocation>): Boolean = synchronized(lock) {
        if (earlier.isEmpty()) return true
        load()
        if (unreadable) return false
        runCatching { save(active, (pending + earlier).distinctBy { it.token }) }.isSuccess
    }

    /** The credential store, read again from its file: no bearer in it, each credential by reference. */
    fun vault(): JSONObject = synchronized(lock) {
        loaded = false
        load()
        view()
    }

    /**
     * A change of the store the core asks for, by reference (`BearerVaultChange`). `quarantine` and `release` answer
     * whether it is done; the others the store after the change, or null when it changed under the core.
     */
    fun change(change: JSONObject): Any? = synchronized(lock) {
        load()
        if (unreadable && change.optString("kind") != "release") return null
        when (change.optString("kind")) {
            "commit" -> {
                val ref = change.getString("issued")
                val credential = issued[ref]?.credential ?: return null
                val supersede = change.optJSONArray("supersede") ?: JSONArray()
                val retired = ArrayList<PendingRevocation>()
                active?.takeIf { it.token != credential.token }?.let {
                    retired.add(PendingRevocation(it.token, it.audience, it.sessionId))
                }
                for (index in 0 until supersede.length()) {
                    val other = supersede.getString(index)
                    val token = issued[other]?.token ?: continue
                    if (token != credential.token) retired.add(PendingRevocation(token, audience, issued[other]?.sessionId))
                }
                save(credential, (pending.filter { it.token != credential.token } + retired).distinctBy { it.token })
                issued.remove(ref)
                committed.add(ref)
                for (index in 0 until supersede.length()) issued.remove(supersede.getString(index))
                view()
            }
            "adopt" -> {
                val current = active ?: return null
                if (tokenFor(change.getString("active")) != current.token || current.audience != audience) return null
                val identity = change.getJSONObject("identity")
                save(StoredCredential(current.token, current.audience, identity.getString("sessionId"),
                    identity.getString("userId"), identity.getString("email"), identity.getLong("expiresAtEpochSeconds")), pending)
                view()
            }
            "invalidate" -> {
                val current = active ?: return null
                if (tokenFor(change.getString("active")) != current.token) return null
                save(null, pending)
                view()
            }
            "signOut" -> {
                val current = active
                if (current != null) save(null, (pending + PendingRevocation(current.token, current.audience, current.sessionId))
                    .distinctBy { it.token })
                view()
            }
            "quarantine" -> quarantine(change.getString("issued"))
            "release" -> {
                issued.remove(change.getString("issued"))
                true
            }
            "revoked" -> {
                val token = tokenFor(change.getString("pending"))
                if (token == null || !queued(token)) return null
                save(active, pending.filter { it.token != token })
                view()
            }
            "retainAudience" -> {
                closeGate()
                save(active?.takeIf { it.audience == audience }, pending.filter { it.audience == audience })
                view()
            }
            else -> null
        }
    }

    /**
     * Queues an issued bearer for revocation. The active credential of the session the core shows signed in stays
     * (a probe that reflected it); any other is queued.
     */
    private fun quarantine(ref: String): Boolean {
        val known = issued[ref]
        val token = known?.token ?: tokenFor(ref) ?: return false
        val current = active
        val shown = snapshot?.takeIf { it.optString("phase") == "signed_in" }?.optJSONObject("session")?.optString("sessionId")
        if (current != null && current.token == token && current.sessionId == shown) {
            issued.remove(ref)
            return true
        }
        // A credential the store already keeps, named by the core (a reflected bearer): nothing to queue.
        if (known == null && ref !in committed) return current?.token == token || queued(token)
        val sessionId = known?.sessionId ?: current?.takeIf { it.token == token }?.sessionId
        return try {
            // Queuing the active credential (a sign-in whose commit a newer one overtook) removes it from the store.
            save(current?.takeIf { it.token != token },
                (pending + PendingRevocation(token, audience, sessionId)).distinctBy { it.token })
            issued.remove(ref)
            committed.remove(ref)
            true
        } catch (_: Exception) { false }
    }

    /** The core never took the answer to request [request] (it gave the request up): what it carried is queued. */
    fun dropped(request: Long) = synchronized(lock) {
        load()
        for (ref in issued.filterValues { it.request == request }.keys) quarantine(ref)
    }

    /** The core went: every bearer it had not settled is queued for revocation. */
    fun coreExited() = synchronized(lock) {
        load()
        for (ref in issued.keys.toList()) quarantine(ref)
    }

    /** The bearer [ref] names, for an auth request the core asks the app to make. */
    fun tokenFor(ref: String): String? = synchronized(lock) { issued[ref]?.token ?: tokens[ref] }

    private fun refFor(token: String): String = refs.getOrPut(token) {
        "cred_${UUID.randomUUID()}".also { tokens[it] = token }
    }

    /**
     * Takes a bearer out of an auth answer: kept here, the core answered its reference (`credential`). [request] is
     * the core's request that carried it.
     */
    fun keepBearer(body: ByteArray, request: Long): ByteArray = synchronized(lock) {
        val value = try { JSONObject(String(body, Charsets.UTF_8)) } catch (_: Exception) { return body }
        if (!value.has("token")) return body
        val token = value.remove("token") as? String
        if (token.isNullOrEmpty()) return value.toString().toByteArray()
        load()
        // A bearer the store already keeps (a probe that reflected it) is named, not taken into custody again.
        if (active?.token == token || queued(token)) return value.put("credential", refFor(token)).toString().toByteArray()
        val user = value.optJSONObject("user")
        val sessionId = value.optString("session_id").takeIf { it.isNotEmpty() && it.length <= 256 }
        val expiresAt = value.optLong("expires_at")
        val userId = user?.optString("id").orEmpty()
        val email = user?.optString("email").orEmpty()
        val credential = if (sessionId != null && expiresAt > 0 && userId.isNotEmpty() && email.isNotEmpty())
            StoredCredential(token, audience, sessionId, userId, email, expiresAt) else null
        val ref = refFor(token)
        issued[ref] = Issued(token, credential, sessionId, request)
        value.put("credential", ref).toString().toByteArray()
    }

    // --- The gate -----------------------------------------------------------------------------------------------

    /**
     * Where the gate is: the authority a core that starts continues. The first core too: the gate follows only
     * snapshots of this authority, so a core left to name its own would never be given a bearer.
     */
    fun resume(): JSONObject = synchronized(lock) {
        JSONObject().put("authorityInstanceId", authorityInstanceId).put("generation", generation)
            .put("revision", revision).put("sessionId", open?.lease?.sessionId ?: JSONObject.NULL)
    }

    /**
     * The snapshot the core published and the lease it gives with it (null: shut), applied in the order told. A
     * snapshot of another authority, an older one, or one whose generation went back shuts the gate. A lease opens
     * only for the active credential when it names the lease's session and audience, at a generation no 401 closed.
     */
    fun gate(next: JSONObject, lease: SessionLease?) {
        val changed: List<(JSONObject) -> Unit>
        synchronized(lock) {
            load()
            val authority = next.optJSONObject("authority")?.optString("authorityInstanceId")
            val nextRevision = next.optLong("revision", -1)
            val nextGeneration = next.optLong("generation", -1)
            if (authority != authorityInstanceId || (snapshot != null && nextRevision <= revision) || nextGeneration < generation) {
                closeGate()
                return
            }
            val credential = active
            val session = next.optJSONObject("session")
            val opens = lease != null && next.optString("phase") == "signed_in" &&
                lease.authorityInstanceId == authorityInstanceId && lease.generation == nextGeneration &&
                lease.sessionId == session?.optString("sessionId") && lease.audience == audience &&
                lease.generation > revokedGeneration && credential != null &&
                credential.audience == lease.audience && credential.sessionId == lease.sessionId
            if (!opens) closeGate()
            else if (open?.lease != lease || open?.bearer() != credential!!.token) {
                closeGate()
                open = LeasedCredential(lease!!, credential!!.token, ++epoch)
            }
            snapshot = next
            revision = nextRevision
            generation = nextGeneration
            changed = listeners.toList()
        }
        for (listener in changed) listener(next)
    }

    /** Told each snapshot the gate took, after it took it. */
    fun onSnapshot(listener: (JSONObject) -> Unit) = synchronized(lock) { listeners.add(listener) }

    /** The bearer for [lease], when it is the open one. */
    fun acquire(lease: SessionLease): LeasedCredential? = synchronized(lock) { open?.takeIf { it.lease == lease } }

    fun isCurrent(leased: LeasedCredential): Boolean = synchronized(lock) { open?.epoch == leased.epoch }

    /** The lease open now, if any: what the app's own requests are made for. */
    fun current(): LeasedCredential? = synchronized(lock) { open }

    /** A 401 the app saw for [leased]: the gate shuts now, and that generation never opens again. */
    fun revoke(leased: LeasedCredential): Boolean = synchronized(lock) {
        if (open?.epoch != leased.epoch) return false
        revokedGeneration = maxOf(revokedGeneration, leased.lease.generation)
        closeGate()
        true
    }

    private fun closeGate() {
        open = null
    }

    companion object {
        private const val MAX_FILE_BYTES = 1_048_576L

        /** `scheme://host[:port]` with a default port left out, as the core names an audience. */
        fun canonicalAudience(origin: String): String {
            val url = java.net.URI(origin.trim())
            val scheme = url.scheme?.lowercase()
            require(scheme == "https" || scheme == "http") { "The session audience must be an HTTP(S) origin." }
            require(url.userInfo == null && !url.host.isNullOrEmpty())
            val port = url.port.takeUnless { it == -1 || (scheme == "https" && it == 443) || (scheme == "http" && it == 80) }
            return "$scheme://${url.host.lowercase()}${port?.let { ":$it" } ?: ""}"
        }
    }
}
