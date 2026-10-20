package surf.comma.android.core

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.CompletableFuture

/** Runs a script in the Hermes the app carries, so it checks the native libraries and how they load together. */
class HermesEngineIntlTest {
    @Test fun theCoreFormatsWithIntlOnItsThread() {
        val emitted = CompletableFuture<String>()
        val host = object : EngineHost {
            override fun call(id: Long, op: String, json: ByteArray, bytes: ByteArray?) = Unit
            override fun callSync(op: String, json: ByteArray) = ByteArray(0)
            override fun emit(json: ByteArray) { emitted.complete(String(json)) }
            override fun fatal(reason: ByteArray) { emitted.completeExceptionally(IllegalStateException(String(reason))) }
        }
        val script = """
            globalThis.commaCore = { start() {
              commaNative.emit(new Intl.DateTimeFormat('en-US', { timeZone: 'UTC' }).format(0));
            } };
        """.trimIndent()
        val engine = HermesEngine(script.toByteArray(), "{}", host)
        try {
            assertEquals("1/1/1970", emitted.get())
        } finally {
            engine.close()
        }
    }
}
