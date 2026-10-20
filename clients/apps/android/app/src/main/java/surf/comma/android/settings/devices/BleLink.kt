package surf.comma.android.settings.devices

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.ParcelUuid
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

internal sealed interface LinkEvent {
    class Notification(val characteristic: UUID, val value: ByteArray) : LinkEvent
    data object Disconnected : LinkEvent
}

/** The GATT connection to one device during setup. */
internal interface DeviceLink {
    val events: SharedFlow<LinkEvent>
    /** Connects, asks for the large MTU and finds the setup service. */
    suspend fun connect()
    /** Reads `info`, which needs the link paired (the system asks for the code), then subscribes to `status` and `wifi_scan`. */
    suspend fun pair(): TCircleInfo
    /** Write with response; returns the ATT status, 0 when accepted. */
    suspend fun write(characteristic: UUID, value: ByteArray): Int
    /** Releases the link and its listeners, even if connecting failed. */
    fun close()
}

internal interface DeviceScanner {
    fun start(onFound: (FoundDevice) -> Unit, onFailed: () -> Unit)
    fun stop()
}

internal class PairingFailure : IOException("Pairing failed")

/** Scans for the setup service only; other devices never reach the app. */
@SuppressLint("MissingPermission") // The page holds BLUETOOTH_SCAN before it starts the flow.
internal class AndroidDeviceScanner(context: Context) : DeviceScanner {
    private val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var callback: ScanCallback? = null

    override fun start(onFound: (FoundDevice) -> Unit, onFailed: () -> Unit) {
        stop()
        val scanner = adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner ?: return onFailed()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                // The name is in the scan response; until it arrives the address stands in.
                val name = result.scanRecord?.deviceName?.takeIf { it.isNotBlank() } ?: return
                val advertisement = NearbyAdvertisement.parse(NearbyAdvertisement.COMPANY_ID,
                    result.scanRecord?.getManufacturerSpecificData(NearbyAdvertisement.COMPANY_ID))
                onFound(FoundDevice(result.device.address, name, result.rssi, advertisement))
            }
            override fun onScanFailed(errorCode: Int) = onFailed()
        }
        this.callback = callback
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(TCircleGatt.SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try { scanner.startScan(listOf(filter), settings, callback) } catch (_: Exception) { onFailed() }
    }

    override fun stop() {
        val callback = callback ?: return
        this.callback = null
        try { adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner?.stopScan(callback) } catch (_: Exception) {}
    }
}

/**
 * One GATT operation at a time, each waiting for its callback. Notifications and the link going
 * down arrive on [events]. Nothing read or written here is logged.
 */
@SuppressLint("MissingPermission") // The page holds BLUETOOTH_CONNECT before it starts the flow.
internal class AndroidDeviceLink(private val context: Context, address: String) : DeviceLink {
    private class Result(val status: Int, val value: ByteArray? = null)

    private val adapter = context.getSystemService(BluetoothManager::class.java)!!.adapter
    private val device: BluetoothDevice = adapter.getRemoteDevice(address)
    private val mutableEvents = MutableSharedFlow<LinkEvent>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val events: SharedFlow<LinkEvent> = mutableEvents.asSharedFlow()
    private val operations = Mutex()
    @Volatile private var pending: CompletableDeferred<Result>? = null
    @Volatile private var gatt: BluetoothGatt? = null
    private val linked = CompletableDeferred<Unit>()
    @Volatile private var closed = false
    private val disconnectReported = AtomicBoolean(false)

    private val adapterState = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> disconnected()
            }
        }
    }

    init {
        // Turning Bluetooth off can stop the service without a GATT disconnect callback.
        context.registerReceiver(adapterState, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED)
    }

    private fun disconnected() {
        if (closed || !disconnectReported.compareAndSet(false, true)) return
        linked.completeExceptionally(IOException("Not connected"))
        pending?.completeExceptionally(IOException("Disconnected"))
        mutableEvents.tryEmit(LinkEvent.Disconnected)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                linked.complete(Unit)
                return
            }
            if (newState != BluetoothProfile.STATE_DISCONNECTED) return
            disconnected()
        }
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) { pending?.complete(Result(status)) }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) { pending?.complete(Result(status)) }
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            pending?.complete(Result(status, value))
        }
        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            pending?.complete(Result(status))
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            pending?.complete(Result(status))
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            mutableEvents.tryEmit(LinkEvent.Notification(characteristic.uuid, value))
        }
    }

    override suspend fun connect() {
        if (closed || !adapter.isEnabled) throw IOException("Not connected")
        // The device asks for pairing as soon as the link is up. Android shows that request as a
        // dialog over the app only if the phone looked for devices moments ago, and otherwise as a
        // notification the person may never see before the device gives up (30 s). A discovery
        // that is stopped right away counts.
        runCatching { if (adapter.startDiscovery()) adapter.cancelDiscovery() }
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) ?: throw IOException("No GATT")
        if (closed) close().also { throw IOException("Closed") }
        linked.await()
        // The device splits its scan list to whatever is agreed; a smaller MTU still works.
        runCatching { operation { it.requestMtu(TCircleGatt.MTU) } }
        val found = operation { it.discoverServices() }
        if (found.status != BluetoothGatt.GATT_SUCCESS || service() == null) throw IOException("No setup service")
    }

    override suspend fun pair(): TCircleInfo {
        // Bonding at the app's request, while it is in front, gets the system's code dialog; bonding
        // that a protected read starts can come up only as a notification.
        if (device.bondState == BluetoothDevice.BOND_NONE) awaitBond()
        repeat(PAIR_ATTEMPTS) {
            val read = operation(PAIR_TIMEOUT_MS) { it.readCharacteristic(characteristic(TCircleGatt.INFO)) }
            if (read.status == BluetoothGatt.GATT_SUCCESS) {
                val info = read.value?.let(TCircleInfo::parse) ?: throw IOException("Unreadable info")
                subscribe(TCircleGatt.STATUS)
                subscribe(TCircleGatt.WIFI_SCAN)
                return info
            }
            if (WriteRejection.of(read.status) != WriteRejection.NOT_PAIRED && read.status != GATT_AUTH_FAIL) throw IOException("Read failed")
            awaitBond()
        }
        throw PairingFailure()
    }

    override suspend fun write(characteristic: UUID, value: ByteArray): Int {
        val target = characteristic(characteristic)
        return operation { gatt ->
            gatt.writeCharacteristic(target, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
        }.status
    }

    override fun close() {
        closed = true
        runCatching { context.unregisterReceiver(adapterState) }
        linked.completeExceptionally(IOException("Closed"))
        pending?.completeExceptionally(IOException("Closed"))
        val gatt = gatt ?: return
        this.gatt = null
        try { gatt.disconnect() } catch (_: Exception) {}
        try { gatt.close() } catch (_: Exception) {}
    }

    private suspend fun subscribe(uuid: UUID) {
        val target = characteristic(uuid)
        val ok = operation { gatt ->
            gatt.setCharacteristicNotification(target, true) && target.getDescriptor(TCircleGatt.CLIENT_CONFIG)?.let {
                gatt.writeDescriptor(it, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
            } == true
        }
        if (ok.status != BluetoothGatt.GATT_SUCCESS) throw IOException("Subscribe failed")
    }

    /** Waits for the system pairing (the person types the code shown on the device) to end. */
    private suspend fun awaitBond() {
        val done = CompletableDeferred<Boolean>()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val changed = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                if (changed?.address != device.address) return
                when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                    BluetoothDevice.BOND_BONDED -> done.complete(true)
                    BluetoothDevice.BOND_NONE -> done.complete(false)
                }
            }
        }
        context.registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED), Context.RECEIVER_EXPORTED)
        try {
            when (device.bondState) {
                BluetoothDevice.BOND_BONDED -> return
                BluetoothDevice.BOND_NONE -> if (!device.createBond()) throw PairingFailure()
            }
            if (!withTimeout(PAIR_TIMEOUT_MS) { done.await() }) throw PairingFailure()
        } finally {
            runCatching { context.unregisterReceiver(receiver) }
        }
    }

    private suspend fun operation(timeoutMillis: Long = OPERATION_TIMEOUT_MS, start: (BluetoothGatt) -> Boolean): Result =
        operations.withLock {
            val gatt = gatt ?: throw IOException("Not connected")
            val result = CompletableDeferred<Result>()
            pending = result
            try {
                if (!start(gatt)) throw IOException("Not started")
                withTimeout(timeoutMillis) { result.await() }
            } finally {
                pending = null
            }
        }

    private fun service() = gatt?.getService(TCircleGatt.SERVICE)

    private fun characteristic(uuid: UUID): BluetoothGattCharacteristic =
        service()?.getCharacteristic(uuid) ?: throw IOException("Missing characteristic")

    private companion object {
        const val OPERATION_TIMEOUT_MS = 10_000L
        /** A read that triggers pairing waits for the person to type the code. */
        const val PAIR_TIMEOUT_MS = 115_000L
        const val PAIR_ATTEMPTS = 3
        /** GATT_AUTH_FAIL: pairing was refused or the code was wrong. */
        const val GATT_AUTH_FAIL = 0x89
    }
}
