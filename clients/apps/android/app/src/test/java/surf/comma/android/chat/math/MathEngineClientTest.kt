package surf.comma.android.chat.math

import android.content.ComponentName
import android.content.ServiceConnection
import android.os.DeadObjectException
import android.os.IBinder
import android.os.IInterface
import android.os.Parcel
import java.io.FileDescriptor
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The client's bookkeeping around a service that dies, with the system stood in for. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MathEngineClientTest {
    private val binds = AtomicInteger()
    private val unbinds = AtomicInteger()
    private val transacts = AtomicInteger()
    @Volatile private var current: ServiceConnection? = null

    /** What the n-th service the system starts does with a call. */
    private var services: (Int) -> IBinder = { DyingService() }

    private abstract inner class FakeService : IBinder {
        override fun getInterfaceDescriptor() = MathLayoutService.DESCRIPTOR
        override fun pingBinder() = true
        override fun isBinderAlive() = true
        override fun queryLocalInterface(descriptor: String): IInterface? = null
        override fun dump(fd: FileDescriptor, args: Array<out String>?) = Unit
        override fun dumpAsync(fd: FileDescriptor, args: Array<out String>?) = Unit
        override fun linkToDeath(recipient: IBinder.DeathRecipient, flags: Int) = Unit
        override fun unlinkToDeath(recipient: IBinder.DeathRecipient, flags: Int) = true

        /** The process ends: as on a device, the disconnect can reach the client before the call fails. */
        fun die(): Nothing {
            current?.onServiceDisconnected(NAME)
            throw DeadObjectException()
        }
    }

    private inner class DyingService : FakeService() {
        override fun transact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            transacts.incrementAndGet()
            die()
        }
    }

    private inner class HealthyService : FakeService() {
        override fun transact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            transacts.incrementAndGet()
            reply!!.writeInt(MathLayoutService.STATUS_OK)
            MathLayout(0f, 0f, 0f, FloatArray(0), IntArray(0), IntArray(0), IntArray(0), FloatArray(0), IntArray(0),
                emptyList(), ByteArray(0)).writeTo(reply)
            reply.setDataPosition(0)
            return true
        }
    }

    /** Its first call hangs until [release]; when it ends, the service has long been dead. */
    private inner class SlowDyingService : FakeService() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        private val count = AtomicInteger()
        override fun transact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            transacts.incrementAndGet()
            if (count.incrementAndGet() == 1) {
                entered.countDown()
                release.await()
                throw DeadObjectException()
            }
            die()
        }
    }

    private val binding = object : MathEngineClient.Binding {
        override fun bind(executor: Executor, connection: ServiceConnection): Boolean {
            val n = binds.incrementAndGet()
            current = connection
            // A new process each time, connected a moment later on the callback thread.
            executor.execute { connection.onServiceConnected(NAME, services(n)) }
            return true
        }

        override fun unbind(connection: ServiceConnection) {
            unbinds.incrementAndGet()
            if (current === connection) current = null
        }
    }

    @Test fun `three deaths stop the engine, even when the disconnect arrives first`() {
        val client = MathEngineClient(binding)
        repeat(3) { assertTrue(client.layout("x", display = false) is MathResult.Failed) }
        assertEquals(3, transacts.get())
        // The fourth formula does not start the service again.
        assertEquals(MathResult.Unavailable, client.layout("y", display = false))
        assertEquals(3, transacts.get())
        assertEquals(3, binds.get())
        assertEquals("every dead connection was let go", 3, unbinds.get())
    }

    @Test fun `a late failure from an old service neither counts again nor lets go of the new one`() {
        val first = SlowDyingService()
        services = { n -> if (n == 1) first else if (n == 2) DyingService() else HealthyService() }
        val client = MathEngineClient(binding)
        // A call is still out on the first service...
        var late: MathResult? = null
        val slow = Thread { late = client.layout("slow", display = false) }.apply { start() }
        first.entered.await()
        // ...when another call finds it dead (death 1), and the next service dies too (death 2).
        assertTrue(client.layout("a", display = false) is MathResult.Failed)
        assertTrue(client.layout("b", display = false) is MathResult.Failed)
        // The third service works.
        assertTrue(client.layout("c", display = false) is MathResult.Laid)
        assertEquals(3, binds.get())
        val unbound = unbinds.get()
        // Now the first service's old call fails. That service was counted already, and the
        // connection in use now is not its own.
        first.release.countDown()
        slow.join()
        assertTrue(late is MathResult.Failed)
        assertEquals(unbound, unbinds.get())
        // Two deaths, not three: the engine still runs, on the same connection.
        assertTrue(client.layout("d", display = false) is MathResult.Laid)
        assertEquals(3, binds.get())
    }

    private companion object {
        val NAME = ComponentName("surf.comma.android", MathLayoutService::class.java.name)
    }
}
