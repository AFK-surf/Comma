package surf.comma.android.settings.devices

import android.Manifest
import android.app.Activity
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.core.CoreError
import surf.comma.android.settings.SettingsGraph
import java.io.File
import java.util.UUID

/** Foreground discovery only. There is no worker, service, or repeating scan. */
internal class NearbyDevices private constructor(private val app: Application) : Application.ActivityLifecycleCallbacks {
    private val auth = AuthGraph.get(app)
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val core = AuthGraph.core(app)
    private val preferences = app.getSharedPreferences("nearby.devices", Context.MODE_PRIVATE)
    // Kept out of Android backup so a second phone cannot inherit the Connect button.
    val reporterId: String = installationId(File(app.noBackupFilesDir, "nearby-reporter-id"))
    private val scanner = NearbyScanController(AndroidDeviceScanner(app), work, object : NearbyReportHistory {
        private fun key(target: NearbyReportTarget) = "reports:${target.scope.accountId}:${target.workspaceId}"
        private fun read(target: NearbyReportTarget) = runCatching {
            JSONObject(preferences.getString(key(target), "{}")!!)
        }.getOrElse { JSONObject() }
        override fun lastReported(target: NearbyReportTarget, shortId: String): Long? =
            read(target).optLong(shortId).takeIf { it > 0 }
        override fun remember(target: NearbyReportTarget, shortId: String, now: Long) {
            val recent = read(target)
            recent.keys().asSequence().toList().filter { now - recent.optLong(it) >= NearbyScanController.DEDUPE_MILLIS }
                .forEach(recent::remove)
            recent.put(shortId, now)
            preferences.edit().putString(key(target), recent.toString()).apply()
        }
    }, report = { target, requestId, device ->
        val ad = requireNotNull(device.advertisement)
        core?.call("devices.reportNearby", JSONObject().put("workspace", target.workspaceId).put("reporter", target.reporterId)
            .put("request", requestId).put("device", JSONObject().put("name", device.name).put("model", ad.model)
                .put("state", ad.state).put("shortId", ad.shortId).put("rssi", device.rssi))) == true
    })
    private var startedActivities = 0
    private var foreground = false

    init {
        app.registerActivityLifecycleCallbacks(this)
        app.registerReceiver(object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = refresh()
        }, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED)
        work.launch {
            combine(auth.state, auth.conversationScope, SettingsGraph.addDeviceOpen) { _, _, _ -> }
                .collect { refresh() }
        }
    }

    fun shouldAskPermission(): Boolean = auth.state.value is AuthState.Connected &&
        auth.conversationScope.value != null && !SettingsGraph.addDeviceOpen.value &&
        !scanGranted() && !preferences.getBoolean("permission.asked", false) &&
        !app.getSharedPreferences("settings.permissions", Context.MODE_PRIVATE).getBoolean("bluetooth.asked", false)

    fun permissionAsked() { preferences.edit().putBoolean("permission.asked", true).apply() }

    fun refresh() {
        val connected = auth.state.value as? AuthState.Connected
        val scope = auth.conversationScope.value
        val target = if (connected != null && scope != null && reporterId.isNotEmpty())
            NearbyReportTarget(scope, connected.selection.workspace.id, reporterId) else null
        val allowed = scanGranted() && runCatching {
            app.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
        }.getOrDefault(false)
        scanner.update(foreground, target, allowed, SettingsGraph.addDeviceOpen.value)
    }

    private fun scanGranted() = app.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

    fun currentOwner(): DeviceOwner? = SettingsGraph.devices(app).currentOwner()

    /** Starts or dismisses [offer]; answers the offer as it is now (one that already moved on, as it is). */
    suspend fun action(owner: DeviceOwner, offer: DeviceSetupOffer, action: String): DeviceSetupOffer =
        actOnOffer(owner, offer, JSONObject().put("action", action))

    fun isCurrent(owner: DeviceOwner): Boolean = auth.conversationScope.value === owner.scope

    /** The device was set up, but its setup offer in the chat could not be told so. */
    fun offerNotUpdated(owner: DeviceOwner) {
        work.launch {
            if (isCurrent(owner)) Toast.makeText(app, "Setup can continue. The chat card could not be updated.", Toast.LENGTH_LONG).show()
        }
    }

    private suspend fun actOnOffer(owner: DeviceOwner, offer: DeviceSetupOffer, params: JSONObject): DeviceSetupOffer {
        val answer = checkNotNull(core) { "No client core." }
            .call("devices.actOnSetupOffer", params.put("workspace", owner.workspaceId).put("offer", offer.offerId))
        return (answer as? JSONObject)?.let(DeviceSetupOffer::parse) ?: throw CoreError("bad_response", "The offer is not one.")
    }

    override fun onActivityStarted(activity: Activity) {
        startedActivities++
        foreground = true
        refresh()
    }
    override fun onActivityStopped(activity: Activity) {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        if (startedActivities == 0 && !activity.isChangingConfigurations) {
            foreground = false
            refresh()
        }
    }
    override fun onActivityResumed(activity: Activity) = refresh()
    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

    companion object {
        @Volatile private var instance: NearbyDevices? = null
        fun get(context: Context): NearbyDevices = instance ?: synchronized(this) {
            instance ?: NearbyDevices(context.applicationContext as Application).also { instance = it }
        }

        private fun installationId(file: File): String = runCatching {
            if (file.exists()) UUID.fromString(file.readText()).toString() else UUID.randomUUID().toString().also {
                file.writeText(it)
            }
        }.getOrDefault("")
    }
}
