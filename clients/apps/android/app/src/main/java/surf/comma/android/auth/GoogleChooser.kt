package surf.comma.android.auth

import kotlinx.coroutines.runBlocking
import surf.comma.android.core.GoogleIdTokens
import java.util.concurrent.atomic.AtomicReference

/**
 * Google's account chooser for the client core's sign-in. The core asks for an ID token in the middle of its Google
 * sign-in ([request], on one of the core host's threads); the chooser needs the Activity the person is in, so the
 * sign-in page lends its [GoogleCredentialSource] for as long as its sign-in runs ([during]). What the chooser gave is
 * kept for the page to word a failure by: the core only learns that no token came.
 */
internal class GoogleChooser : GoogleIdTokens {
    private class Lent(val source: GoogleCredentialSource) {
        val outcome = AtomicReference<GoogleCredential?>()
    }

    class Chosen<T>(val result: T, val outcome: GoogleCredential?)

    private val lent = AtomicReference<Lent?>()

    suspend fun <T> during(source: GoogleCredentialSource, block: suspend () -> T): Chosen<T> {
        val mine = Lent(source)
        lent.set(mine)
        return try {
            Chosen(block(), mine.outcome.get())
        } finally {
            lent.compareAndSet(mine, null)
        }
    }

    override fun request(clientId: String, nonce: String): String? {
        val now = lent.get() ?: return null
        val credential = runBlocking { now.source.request(clientId, nonce) }
        now.outcome.set(credential)
        return (credential as? GoogleCredential.Token)?.idToken
    }
}
