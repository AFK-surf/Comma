package surf.comma.android.auth

import android.app.Activity
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialProviderConfigurationException
import androidx.credentials.exceptions.GetCredentialUnsupportedException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import kotlinx.coroutines.CancellationException

/** What the Google account chooser gave back. */
sealed interface GoogleCredential {
    /** The ID token goes straight to the backend; it is never stored or logged. */
    class Token(val idToken: String) : GoogleCredential {
        override fun toString() = "Token([redacted])"
    }
    /** The person closed the chooser. */
    data object Cancelled : GoogleCredential
    /** The device has no Google account to offer. */
    data object NoAccount : GoogleCredential
    /** No Google Play services, or no credential provider on this device. */
    data object Unavailable : GoogleCredential
    /** Anything else; nothing more specific is shown. */
    data object Failed : GoogleCredential
}

/** Asks Google for an ID token for the backend's [clientId], bound to the attempt's [nonce]. */
fun interface GoogleCredentialSource {
    suspend fun request(clientId: String, nonce: String): GoogleCredential
}

/** The system account chooser, styled as the "Sign in with Google" button flow. */
internal class CredentialManagerGoogle(private val activity: Activity) : GoogleCredentialSource {
    override suspend fun request(clientId: String, nonce: String): GoogleCredential {
        val option = GetSignInWithGoogleOption.Builder(clientId).setNonce(nonce).build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        return try {
            val credential = CredentialManager.create(activity).getCredential(activity, request).credential
            if (credential is CustomCredential && credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                GoogleCredential.Token(GoogleIdTokenCredential.createFrom(credential.data).idToken)
            } else GoogleCredential.Failed
        } catch (e: CancellationException) {
            throw e
        } catch (_: GetCredentialCancellationException) {
            GoogleCredential.Cancelled
        } catch (_: NoCredentialException) {
            GoogleCredential.NoAccount
        } catch (_: GetCredentialProviderConfigurationException) {
            GoogleCredential.Unavailable
        } catch (_: GetCredentialUnsupportedException) {
            GoogleCredential.Unavailable
        } catch (_: GetCredentialException) {
            GoogleCredential.Failed
        } catch (_: Exception) {
            // Includes a token that does not parse; its contents are never surfaced.
            GoogleCredential.Failed
        }
    }
}
