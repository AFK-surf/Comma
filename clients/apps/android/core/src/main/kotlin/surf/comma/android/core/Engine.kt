package surf.comma.android.core

import com.facebook.soloader.nativeloader.NativeLoader
import com.facebook.soloader.nativeloader.SystemDelegate
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * What a running core asks of the app, called on the core's own thread. [call] returns at once and answers later
 * through [Engine.complete]; [callSync] answers before it returns.
 */
interface EngineHost {
    fun call(id: Long, op: String, json: ByteArray, bytes: ByteArray?)
    fun callSync(op: String, json: ByteArray): ByteArray
    /** What the core says to the app's UI, as UTF-8 JSON. */
    fun emit(json: ByteArray)
    /** The core cannot go on; nothing else comes from it. */
    fun fatal(reason: ByteArray)
}

/** One running core. Tests put a fake in its place. */
interface Engine {
    /** What the app's UI says, as JSON. */
    fun receive(json: String)
    /** The server refused a request the app made for [lease] (JSON) with [status] (401 or 409). */
    fun rejected(lease: String, status: Int)
    /** The answer to [EngineHost.call] number [id]: [error] when it failed. */
    fun complete(id: Long, json: String?, error: String?, bytes: ByteArray?)
    /** Stops this core and waits for its thread to end. */
    fun close()
}

/** Starts an engine that asks [host] for what it needs; [config] is the JSON the core's script starts with. */
fun interface EngineFactory {
    fun start(config: String, host: EngineHost): Engine
}

/** The engine's JNI (src/main/cpp/jni.cpp, over the engine the iOS app shares: packages/core/native/engine.cpp). */
internal object HermesNative {
    init {
        // Hermes's Intl enters fbjni's ThreadScopeSupport, which loads fbjni through NativeLoader. React Native's
        // SoLoader sets the loader up; without it, the core's first Intl call aborts the app.
        NativeLoader.initIfUninitialized(SystemDelegate())
        // fbjni first: Hermes finds its platform classes (Intl, Unicode) through it.
        System.loadLibrary("fbjni")
        System.loadLibrary("comma_core")
    }

    external fun create(script: ByteArray, url: ByteArray, config: ByteArray, host: EngineHost): Long
    external fun run(handle: Long)
    external fun receive(handle: Long, json: ByteArray)
    external fun rejected(handle: Long, lease: ByteArray, status: Int)
    external fun complete(handle: Long, id: Long, json: ByteArray?, error: ByteArray?, bytes: ByteArray?)
    external fun stop(handle: Long)
    external fun destroy(handle: Long)
}

/** The core's script as the app carries it: Hermes bytecode, compiled by the `bundleCore` task. */
const val CORE_SCRIPT = "core.hbc"

/**
 * The core in Hermes, on a thread of its own. Hermes's parser and interpreter want more native stack than a thread
 * gets by default. The thread is started here, in Java, so Java classes resolve on it as anywhere in the app.
 */
class HermesEngine(script: ByteArray, config: String, host: EngineHost) : Engine {
    private val gate = ReentrantReadWriteLock()
    private var handle = HermesNative.create(script, CORE_SCRIPT.toByteArray(), config.toByteArray(), host)
    private val thread = Thread(null, { HermesNative.run(handle) }, "comma-core", STACK_BYTES).apply { start() }

    /** Runs [block] with the engine unless it is closed: nothing reaches a destroyed engine. */
    private inline fun open(block: (Long) -> Unit) = gate.read { if (handle != 0L) block(handle) }

    override fun receive(json: String) = open { HermesNative.receive(it, json.toByteArray()) }

    override fun rejected(lease: String, status: Int) = open { HermesNative.rejected(it, lease.toByteArray(), status) }

    override fun complete(id: Long, json: String?, error: String?, bytes: ByteArray?) = open {
        HermesNative.complete(it, id, json?.toByteArray(), error?.toByteArray(), bytes)
    }

    override fun close() {
        open { HermesNative.stop(it) }
        if (Thread.currentThread() !== thread) thread.join()
        gate.write {
            if (handle == 0L) return
            // Closed from the core's own thread (a host call that ends it): the loop has not returned yet, so the
            // engine is left to the process rather than freed under it.
            if (Thread.currentThread() !== thread) HermesNative.destroy(handle)
            handle = 0L
        }
    }

    private companion object {
        const val STACK_BYTES = 8L * 1024 * 1024
    }
}
