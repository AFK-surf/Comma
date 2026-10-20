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

    private companion object {
        const val ORIGIN = "https://api.example.com"
        const val SESSION = "session-1"
    }
}
