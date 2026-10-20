package surf.comma.android.chat.math

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel
import android.os.RemoteException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Lays out one formula. Blocking; never called on the main thread. */
fun interface MathEngine {
    fun layout(latex: String, display: Boolean): MathResult
}

sealed interface MathResult {
    class Laid(val layout: MathLayout) : MathResult

    /** This formula cannot be drawn (bad input, too large, or it brought the engine down). */
    data class Failed(val reason: String) : MathResult

    /** The engine could not be reached; the same formula may work later. */
    data object Unavailable : MathResult
}

/**
 * The app's side of [MathLayoutService]: binds it when a formula first needs it, calls it from
 * the thread that is laying out a message, and lets it go after [IDLE_MS] without a formula so
 * its process does not stay around for a chat with no math.
 *
 * A formula during which the service died is reported as [MathResult.Failed], so it is not tried
 * again; after [MAX_DEATHS] deaths the engine stops being started at all for this run.
 *
 * Every binder the system delivers gets a generation, and a call remembers the generation it was
 * made on. A death is counted once per generation, for as long as the client lives: several calls
 * failing on one dead service, a failure that comes in after a newer service has died too, or
 * a disconnect callback that cleared the binder first all count it once.
 */
class MathEngineClient internal constructor(private val binding: Binding) : MathEngine {
    constructor(context: Context) : this(ContextBinding(context.applicationContext))

    /** How the service is bound; tests stand in for the system here. */
    internal interface Binding {
        fun bind(executor: Executor, connection: ServiceConnection): Boolean
        fun unbind(connection: ServiceConnection)
    }

    private class ContextBinding(private val app: Context) : Binding {
        override fun bind(executor: Executor, connection: ServiceConnection): Boolean =
            app.bindService(Intent(app, MathLayoutService::class.java), Context.BIND_AUTO_CREATE, executor, connection)

        override fun unbind(connection: ServiceConnection) = app.unbindService(connection)
    }

    private val lock = Object()
    private val callbacks = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "math-engine").apply { isDaemon = true }
    }
    private var binder: IBinder? = null
    /** The generation of [binder]. */
    private var binderGeneration = 0
    /**
     * The generation the current connection delivered last; kept when a disconnect clears
     * [binder], and 0 when there is no connection.
     */
    private var deliveredGeneration = 0
    private var generations = 0
    private var connection: ServiceConnection? = null
    private var connected: CountDownLatch? = null
    private var idle: ScheduledFuture<*>? = null
    private var calls = 0
    private var deaths = 0
    /** Every generation counted as dead. At most a few: the engine stops after [MAX_DEATHS]. */
    private val dead = HashSet<Int>()

    /** A binder and the generation it belongs to. */
    private class Lease(val binder: IBinder, val generation: Int)

    override fun layout(latex: String, display: Boolean): MathResult {
        val lease = acquire() ?: return MathResult.Unavailable
        val remote = lease.binder
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(MathLayoutService.DESCRIPTOR)
            data.writeString(latex)
            data.writeInt(if (display) 1 else 0)
            remote.transact(MathLayoutService.LAYOUT, data, reply, 0)
            return when (reply.readInt()) {
                MathLayoutService.STATUS_OK -> MathLayout.read(reply)?.let(MathResult::Laid)
                    ?: MathResult.Failed("unreadable layout")
                else -> MathResult.Failed(reply.readString().orEmpty())
            }
        } catch (_: RemoteException) {
            died(lease.generation)
            return MathResult.Failed("engine stopped")
        } catch (_: RuntimeException) {
            return MathResult.Failed("unreadable layout")
        } finally {
            data.recycle()
            reply.recycle()
            release()
        }
    }

    /** The bound service, binding it first if needed; null if it cannot be reached in time. */
    private fun acquire(): Lease? {
        val latch: CountDownLatch
        synchronized(lock) {
            if (deaths >= MAX_DEATHS) return null
            calls++
            idle?.cancel(false)
            idle = null
            binder?.let { return Lease(it, binderGeneration) }
            latch = connected ?: bind() ?: run { calls--; return null }
        }
        latch.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        synchronized(lock) {
            binder?.let { return Lease(it, binderGeneration) }
            calls--
            scheduleUnbind()
            return null
        }
    }

    private fun release() = synchronized(lock) {
        calls--
        scheduleUnbind()
    }

    /** Starts binding; the caller holds [lock]. */
    private fun bind(): CountDownLatch? {
        val latch = CountDownLatch(1)
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder) {
                synchronized(lock) {
                    if (connection !== this) return
                    binder = service
                    binderGeneration = ++generations
                    deliveredGeneration = binderGeneration
                }
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                synchronized(lock) { if (connection === this) binder = null }
            }

            override fun onBindingDied(name: ComponentName?) {
                synchronized(lock) { if (connection === this) unbind() }
                latch.countDown()
            }

            override fun onNullBinding(name: ComponentName?) = onBindingDied(name)
        }
        val bound = try {
            binding.bind(callbacks, conn)
        } catch (_: RuntimeException) {
            false
        }
        if (!bound) {
            runCatching { binding.unbind(conn) }
            return null
        }
        connection = conn
        connected = latch
        return latch
    }

    private fun died(generation: Int) = synchronized(lock) {
        if (dead.add(generation)) deaths++
        // The connection that delivered it is let go (bound, the system would start the service
        // again by itself); one made since, by another caller, is left alone.
        if (deliveredGeneration == generation) unbind()
    }

    /** Lets the service go once nothing has asked for a formula for [IDLE_MS]; holds [lock]. */
    private fun scheduleUnbind() {
        if (calls > 0 || connection == null) return
        idle?.cancel(false)
        idle = callbacks.schedule({ synchronized(lock) { if (calls == 0) unbind() } }, IDLE_MS, TimeUnit.MILLISECONDS)
    }

    /** Holds [lock]. */
    private fun unbind() {
        idle?.cancel(false)
        idle = null
        connection?.let { runCatching { binding.unbind(it) } }
        connection = null
        connected = null
        binder = null
        deliveredGeneration = 0
    }

    private companion object {
        /** Starting the process and loading the engine; a first formula waits at most this long. */
        const val CONNECT_TIMEOUT_MS = 5_000L
        const val IDLE_MS = 30_000L
        const val MAX_DEATHS = 3
    }
}
