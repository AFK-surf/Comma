package surf.comma.android.chat.math

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import io.ratex.RaTeXEngine
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Lays out formulas, in a process of its own.
 *
 * The layout engine is native code fed with text a model wrote, and a fault in it ends its
 * process. So it runs here: an isolated process (no permissions, no files, no network), started
 * when a message first has a formula and stopped when no formula has been asked for a while
 * ([MathEngineClient]). If it dies, the app shows that formula's source and carries on.
 *
 * The protocol is one call ([LAYOUT]): the formula and whether it is a display formula in; a
 * status and either a [MathLayout] or a reason out.
 */
class MathLayoutService : Service() {
    private val watchdog = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "math-watchdog").apply { isDaemon = true }
    }

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != LAYOUT) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(DESCRIPTOR)
            val latex = data.readString().orEmpty()
            val display = data.readInt() == 1
            // A layout that does not finish is ended with the process: the caller sees it die.
            val stop = watchdog.schedule({ Process.killProcess(Process.myPid()) }, CALL_BUDGET_MS, TimeUnit.MILLISECONDS)
            val result = try {
                layout(latex, display)
            } finally {
                stop.cancel(false)
            }
            reply ?: return true
            when (result) {
                is MathLayout -> {
                    reply.writeInt(STATUS_OK)
                    result.writeTo(reply)
                }
                else -> {
                    reply.writeInt(STATUS_FAILED)
                    reply.writeString(result as String)
                }
            }
            return true
        }
    }

    /** A [MathLayout], or why there is none. */
    private fun layout(latex: String, display: Boolean): Any {
        if (latex.length > MathLimits.MAX_SOURCE_CHARS) return "too long"
        return try {
            val laid = MathLayout.from(RaTeXEngine.parseBlocking(latex, display, android.graphics.Color.BLACK))
            if (MathLimits.accepts(laid)) laid else "too large"
        } catch (error: Exception) {
            error.message?.take(MAX_REASON_CHARS) ?: "failed"
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        watchdog.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val DESCRIPTOR = "surf.comma.android.chat.math.MathLayoutService"
        const val LAYOUT = IBinder.FIRST_CALL_TRANSACTION
        const val STATUS_OK = 0
        const val STATUS_FAILED = 1

        /** A formula takes well under 10 ms; this is for one that never ends. */
        const val CALL_BUDGET_MS = 2_000L
        private const val MAX_REASON_CHARS = 200
    }
}
