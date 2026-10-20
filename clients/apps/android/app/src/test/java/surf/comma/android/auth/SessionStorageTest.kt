package surf.comma.android.auth

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import javax.crypto.KeyGenerator

class SessionStorageTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val cipher = SessionCipher { key }
    private val session = Session(SessionToken("a-private-token"), 1_900_000_000, "session-test",
        Account("account-test", "test@example.test", null, "active"))

    @Test fun encryptedSessionRoundTripsAndClearRemovesDiskState() {
        val file = File(temporary.root, "session.bin")
        val store = EncryptedSessionStore(file, cipher)
        store.write(session)
        assertFalse(file.readBytes().toString(Charsets.UTF_8).contains(session.token.value))
        val saved = EncryptedSessionStore(file, cipher).read()!!
        assertEquals(session.token.value, saved.token.value)
        assertEquals(session.user, saved.user)
        assertEquals(session.expiresAt, saved.expiresAt)
        assertEquals(session.sessionId, saved.sessionId)
        store.clear()
        assertNull(store.read())
        assertFalse(file.exists())
    }

    @Test fun eachEncryptionUsesADifferentNonceAndTamperingIsRejected() {
        val input = "private value".toByteArray()
        val first = cipher.encrypt(input)
        val second = cipher.encrypt(input)
        assertFalse(first.contentEquals(second))
        assertArrayEquals(input, cipher.decrypt(first))
        first[first.lastIndex] = (first.last().toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { cipher.decrypt(first) }
    }

    @Test fun corruptStorageHasNoPlaintextOrCauseInItsFailure() {
        val file = temporary.newFile("session.bin")
        file.writeText("a-private-token corrupted")
        val failure = assertThrows(StorageFailure::class.java) { EncryptedSessionStore(file, cipher).read() }
        assertFalse(failure.toString().contains(session.token.value))
        assertNull(failure.cause)
    }

    @Test fun earlierQueuedSignOutsAreReadOnceForTheCredentialStore() {
        val root = File(temporary.root, "no_backup/pending-logouts").apply { mkdirs() }
        val logoutCipher = SessionCipher("comma.pending-logout.v1") { key }
        fun record(id: String, token: String, logoutSession: Boolean) = File(root, "$id.bin").writeBytes(logoutCipher.encrypt(
            org.json.JSONObject().put("token", token).put("expires_at", session.expiresAt).put("attempts", 1)
                .put("next_attempt_at", 0).put("logout_session", logoutSession).toString().toByteArray()))
        val signOut = "00000000-0000-0000-0000-000000000001"
        val voiceOnly = "00000000-0000-0000-0000-000000000002"
        record(signOut, session.token.value, logoutSession = true)
        record(voiceOnly, "secret-voice-owner", logoutSession = false)
        File(root, "00000000-0000-0000-0000-000000000003.bin").writeText("${session.token.value} broken")

        val earlier = EarlierLogouts(root, logoutCipher)
        assertEquals(setOf(signOut, voiceOnly, "00000000-0000-0000-0000-000000000003"), earlier.ids().toSet())
        assertEquals(session.token.value to session.expiresAt, earlier.read(signOut))
        // A record that only deleted a voice key signs nothing out; a broken one is skipped.
        assertNull(earlier.read(voiceOnly))
        assertNull(earlier.read("00000000-0000-0000-0000-000000000003"))
        earlier.delete()
        assertFalse(root.exists())
    }
}
