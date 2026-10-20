package surf.comma.android.auth

import java.io.InterruptedIOException
import java.net.UnknownHostException

/** Diagnostic values contain only a closed category and, for HTTP, the numeric status. */
internal enum class NetworkFailureKind { TIMEOUT, DNS, CONNECTION, HTTP }
internal data class NetworkFailure(val kind: NetworkFailureKind, val status: Int? = null) {
    val summary: String get() = if (kind == NetworkFailureKind.HTTP) "HTTP $status" else kind.name

    companion object {
        fun transport(error: Throwable): NetworkFailure {
            val causes = generateSequence(error) { it.cause }.take(8).toList()
            val kind = when {
                causes.any { it is InterruptedIOException } -> NetworkFailureKind.TIMEOUT
                causes.any { it is UnknownHostException } -> NetworkFailureKind.DNS
                else -> NetworkFailureKind.CONNECTION
            }
            return NetworkFailure(kind)
        }
    }
}
