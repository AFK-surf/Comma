package surf.comma.android.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The gate, told snapshots as a core that started from [SessionCustody.resume] publishes them. */
class SessionCustodyTest {
    @get:Rule val folder = TemporaryFolder()

    private val plain = object : Sealer {
        override fun seal(plaintext: ByteArray) = plaintext.copyOf()
        override fun open(sealed: ByteArray) = sealed.copyOf()
    }

    private fun custody() = SessionCustody(folder.newFile("credentials.bin").also { it.delete() }, plain, ORIGIN).also {
        it.adoptEarlier(StoredCredential("bearer", it.audience, SESSION, "user-1", "user@example.com", 4_102_444_800))
    }

    private fun signedIn(authority: String, revision: Long, generation: Long) = JSONObject()
        .put("authority", JSONObject().put("authorityInstanceId", authority).put("kind", "android_keystore"))
        .put("phase", "signed_in").put("revision", revision).put("generation", generation)
        .put("session", JSONObject().put("sessionId", SESSION))

    @Test fun theFirstCoreContinuesTheAppsAuthorityAndItsLeaseOpens() {
        val custody = custody()
        // Before any snapshot: the app's authority, from the start.
        val resumed = custody.resume()
        assertEquals(custody.authorityInstanceId, resumed.getString("authorityInstanceId"))
        assertEquals(0, resumed.getLong("generation"))
        assertEquals(0, resumed.getLong("revision"))
        assertEquals(true, resumed.isNull("sessionId"))

        val authority = resumed.getString("authorityInstanceId")
        val lease = SessionLease(custody.audience, authority, 1, SESSION)
        custody.gate(signedIn(authority, revision = 1, generation = 1), lease)
        assertEquals("bearer", custody.acquire(lease)?.bearer())

        val next = custody.resume()
        assertEquals(authority, next.getString("authorityInstanceId"))
        assertEquals(1, next.getLong("generation"))
        assertEquals(1, next.getLong("revision"))
        assertEquals(SESSION, next.getString("sessionId"))
    }

    @Test fun aSnapshotOfAnotherAuthorityOpensNothing() {
        val custody = custody()
        val lease = SessionLease(custody.audience, "another", 1, SESSION)
        custody.gate(signedIn("another", revision = 1, generation = 1), lease)
        assertNull(custody.acquire(lease))
        assertNull(custody.current())
        assertNotNull(custody.identity())
    }

    @Test fun anotherAccountIsKeptOnDiskAndSwitchedToWithoutSigningInAgain() {
        val file = folder.newFile("accounts.bin").also { it.delete() }
        val custody = SessionCustody(file, plain, ORIGIN)
        custody.adoptEarlier(StoredCredential("bearer-1", custody.audience, SESSION, "user-1", "one@example.com", 4_102_444_800))
        val kept = custody.change(JSONObject().put("kind", "keep")) as JSONObject
        assertEquals(true, kept.isNull("active"))
        assertEquals("user-1", kept.getJSONArray("kept").getJSONObject(0).getString("userId"))

        // A sign-in's answer for user-2 is committed: user-1 stays kept.
        val answer = JSONObject().put("token", "bearer-2").put("session_id", "session-2").put("expires_at", 4_102_444_800)
            .put("user", JSONObject().put("id", "user-2").put("email", "two@example.com"))
        val issued = JSONObject(String(custody.keepBearer(answer.toString().toByteArray(), 1))).getString("credential")
        val committed = custody.change(JSONObject().put("kind", "commit").put("issued", issued)
            .put("supersede", org.json.JSONArray())) as JSONObject
        assertEquals("user-2", committed.getJSONObject("active").getString("userId"))
        assertEquals(0, committed.getJSONArray("pending").length())

        // Read again from the file: both accounts, and switching swaps them.
        val again = SessionCustody(file, plain, ORIGIN)
        val stored = again.vault()
        val ref = stored.getJSONArray("kept").getJSONObject(0).getString("ref")
        val switched = again.change(JSONObject().put("kind", "activate").put("kept", ref)) as JSONObject
        assertEquals("user-1", switched.getJSONObject("active").getString("userId"))
        assertEquals("user-2", switched.getJSONArray("kept").getJSONObject(0).getString("userId"))
        assertEquals("bearer-1", again.tokenFor(switched.getJSONObject("active").getString("ref")))

        // The kept one signs out of the device: queued for revocation.
        val other = switched.getJSONArray("kept").getJSONObject(0).getString("ref")
        val forgotten = again.change(JSONObject().put("kind", "forget").put("kept", other)) as JSONObject
        assertEquals(false, forgotten.has("kept"))
        assertEquals(1, forgotten.getJSONArray("pending").length())
    }

    private companion object {
        const val ORIGIN = "https://api.example.com"
        const val SESSION = "session-1"
    }
}
