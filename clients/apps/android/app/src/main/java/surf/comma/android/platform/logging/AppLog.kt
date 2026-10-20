package surf.comma.android.platform.logging

import android.util.Log

/** Lightweight operational logging boundary: every failure carries a stable tag and throwable. */
object AppLog {
    fun info(tag: String, message: String) {
        emit { Log.i(tag, message) }
    }

    fun warn(tag: String, throwable: Throwable, message: String = "Operation failed") {
        emit { Log.w(tag, message, throwable) }
    }

    /** A warning that is a decision, not a failure: nothing threw, something was refused. */
    fun warn(tag: String, message: String) {
        emit { Log.w(tag, message) }
    }

    fun debug(tag: String, throwable: Throwable, message: String = "Best-effort operation failed") {
        emit { Log.d(tag, message, throwable) }
    }

    private inline fun emit(write: () -> Unit) {
        try {
            write()
        } catch (unavailableAndroidLog: RuntimeException) {
            // android.util.Log is an exception-throwing stub in plain JVM tests. Logging is an
            // observation boundary and must never replace the operation's real result/failure.
        }
    }
}
