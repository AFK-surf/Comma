package surf.comma.android.auth

import android.util.Log

internal object NetworkDiagnostics {
    fun record(failure: NetworkFailure) { Log.d("NetworkFailure", failure.summary) }
}
