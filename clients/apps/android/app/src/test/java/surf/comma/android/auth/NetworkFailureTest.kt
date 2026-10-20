package surf.comma.android.auth

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

class NetworkFailureTest {
    @Test fun transportDiagnosticsClassifyFailuresWithoutTheirMessagesOrCauses() {
        val secret = "https://private.test/request?token=private-credential"
        listOf(
            SocketTimeoutException(secret) to "TIMEOUT",
            UnknownHostException(secret) to "DNS",
            ConnectException(secret) to "CONNECTION",
            IOException(secret, UnknownHostException(secret)) to "DNS",
            IOException(secret) to "CONNECTION",
        ).forEach { (error, expected) ->
            val failure = NetworkFailure.transport(error)
            assertEquals(expected, failure.summary)
            assertFalse(failure.toString().contains(secret))
        }
    }
}
