package surf.comma.android.settings.devices

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Intent
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AndroidDeviceLinkTest {
    private val context = RuntimeEnvironment.getApplication()
    private val adapter = context.getSystemService(BluetoothManager::class.java).adapter
    private val address = "C0:00:00:00:00:01"

    private fun bluetoothOff(state: Int = BluetoothAdapter.STATE_TURNING_OFF) {
        context.sendBroadcast(Intent(BluetoothAdapter.ACTION_STATE_CHANGED)
            .putExtra(BluetoothAdapter.EXTRA_STATE, state))
        ShadowLooper.idleMainLooper()
    }

    @Test fun bluetoothOffReportsLinkLossWithoutAGattDisconnectCallback() = runTest {
        shadowOf(adapter).setState(BluetoothAdapter.STATE_ON)
        val link = AndroidDeviceLink(context, address)
        val events = mutableListOf<LinkEvent>()
        val collector = backgroundScope.launch { link.events.collect { events += it } }
        try {
            val connecting = async { link.connect() }
            runCurrent()
            val device = shadowOf(adapter.getRemoteDevice(address))
            val gatt = shadowOf(device.bluetoothGatts.single())
            gatt.addDiscoverableService(BluetoothGattService(TCircleGatt.SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY))
            device.simulateGattConnectionChange(BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            runCurrent()
            connecting.await()

            bluetoothOff()
            runCurrent()
            assertEquals(listOf(LinkEvent.Disconnected), events)
            bluetoothOff(BluetoothAdapter.STATE_OFF)
            device.simulateGattConnectionChange(BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
            runCurrent()
            assertEquals("one link loss across adapter and GATT callbacks", listOf(LinkEvent.Disconnected), events)

            link.close()
            events.clear()
            bluetoothOff()
            device.simulateGattConnectionChange(BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
            runCurrent()
            assertTrue(events.isEmpty())
            assertTrue(gatt.isClosed)
        } finally {
            link.close()
            collector.cancel()
        }
    }

    @Test fun bluetoothOffEndsAPendingConnectionWithoutAGattCallback() = runTest {
        shadowOf(adapter).setState(BluetoothAdapter.STATE_ON)
        val link = AndroidDeviceLink(context, address)
        try {
            val connecting = backgroundScope.async { runCatching { link.connect() } }
            runCurrent()
            bluetoothOff()
            runCurrent()
            assertTrue("The connection must stop when Bluetooth turns off", connecting.isCompleted)
            assertTrue(connecting.await().exceptionOrNull() is IOException)
        } finally {
            link.close()
        }
    }
}
