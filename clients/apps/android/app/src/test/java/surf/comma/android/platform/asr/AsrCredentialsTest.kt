package surf.comma.android.platform.asr

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AsrCredentialsTest {
    @Test
    fun `no key means voice is unavailable, not a crash`() = runBlocking {
        val provider = DebugLocalAsrCredentialProvider(apiKey = "", resourceId = "")
        assertFalse(provider.isAvailable)
        assertNull(provider.credentials())

        val blank = DebugLocalAsrCredentialProvider(apiKey = "   ", resourceId = "res")
        assertFalse(blank.isAvailable)
        assertNull(blank.credentials())
    }

    @Test
    fun `a key without a resource id falls back to the default model`() = runBlocking {
        val credentials = DebugLocalAsrCredentialProvider(apiKey = "k-123", resourceId = "").credentials()!!
        assertEquals("k-123", credentials.apiKey)
        assertEquals("volc.bigasr.sauc.duration", credentials.resourceId)
    }

    @Test
    fun `the key never appears in string forms`() = runBlocking {
        val secret = "sk-local-secret-value"
        val provider = DebugLocalAsrCredentialProvider(apiKey = secret, resourceId = "res")
        assertTrue(provider.isAvailable)
        val credentials = provider.credentials()!!
        assertFalse(credentials.toString().contains(secret))
        assertFalse(provider.toString().contains(secret))
    }
}
