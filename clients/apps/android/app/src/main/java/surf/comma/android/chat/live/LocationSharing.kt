package surf.comma.android.chat.live

import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.activity.ComponentActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.auth.AuthGraph
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue

/**
 * Settings › Share location: while it is on and the app is in front, this phone follows its position and gives each
 * reading to the core (`locationSharing.report`), which sends the newest with each message. Leaving the front gives
 * the core `null`, so no position outlives the time the phone could follow the person. Turning it on asks the
 * system's permission first and stays off when the person refuses. Runs on the main thread.
 */
internal class LocationSharing(
    private val context: Context,
    private val core: CoreApi?,
    private val scope: CoroutineScope,
) : LocationListener {
    /** The core's `locationSharing` value; null until it is read. */
    var enabled: Boolean? = null
        private set

    private var following: Job? = null
    private var foreground = false
    private var updating = false
    private val watchers = LinkedHashSet<() -> Unit>()

    /** Calls [changed] when [enabled] may have changed, until the returned function is called. */
    fun watch(changed: () -> Unit): () -> Unit {
        watchers += changed
        return { watchers -= changed }
    }

    fun setForeground(visible: Boolean) {
        foreground = visible
        val api = core
        if (visible && api != null && following?.isActive != true) {
            following = scope.launch {
                api.subscribe(JSONObject().put("topic", "locationSharing")) { (it as? JSONObject)?.optBoolean("enabled") }
                    .collect { value ->
                        if (value !is TopicValue.Value) return@collect
                        enabled = value.value == true
                        changed()
                        follow()
                    }
            }
        } else if (!visible) {
            following?.cancel()
            following = null
        }
        follow()
    }

    /** The person's switch. On asks the system first; [denied] is called and it stays off when they refuse. */
    fun set(activity: ComponentActivity, on: Boolean, denied: () -> Unit) {
        if (!on) return apply(false)
        DeviceLocation(activity).read { reading ->
            if (reading == DeviceLocation.Reading.Denied) denied() else apply(true)
        }
    }

    private fun apply(on: Boolean) {
        enabled = on
        changed()
        follow()
        scope.launch { call("locationSharing.set", JSONObject().put("enabled", on)) }
    }

    /** Follows the position exactly while sharing is on, the system allows it and the app is in front. */
    @Suppress("MissingPermission")
    private fun follow() {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = PROVIDERS.firstOrNull { manager.hasProvider(it) && manager.isProviderEnabled(it) }
        val want = foreground && enabled == true && DeviceLocation.allowed(context) && provider != null
        if (want == updating) return
        updating = want
        if (want) {
            manager.requestLocationUpdates(provider!!, MIN_TIME_MS, MIN_DISTANCE_M, this, Looper.getMainLooper())
        } else {
            manager.removeUpdates(this)
            report(null)
        }
    }

    override fun onLocationChanged(location: Location) {
        if (updating) report(location)
    }

    private fun report(location: Location?) {
        val position = location?.let {
            JSONObject().put("latitude", it.latitude).put("longitude", it.longitude).put("readAt", it.time)
                .apply { if (it.hasAccuracy()) put("accuracy", it.accuracy.toDouble()) }
        }
        scope.launch { call("locationSharing.report", JSONObject().put("position", position ?: JSONObject.NULL)) }
    }

    private suspend fun call(name: String, params: JSONObject) {
        try {
            core?.call(name, params)
        } catch (e: CancellationException) {
            throw e
        } catch (_: CoreError) {
            // Signed out meanwhile: there is no account to share for.
        }
    }

    private fun changed() = watchers.toList().forEach { it() }

    companion object {
        /** A neighbourhood is enough for "nearby"; the phone reads again as the person moves. */
        private const val MIN_TIME_MS = 60_000L
        private const val MIN_DISTANCE_M = 100f
        private val PROVIDERS = listOf(LocationManager.FUSED_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)

        @Volatile private var shared: LocationSharing? = null

        /** The process's one, shared by Settings and the app's foreground. */
        fun of(context: Context): LocationSharing = shared ?: synchronized(this) {
            shared ?: LocationSharing(
                context.applicationContext,
                AuthGraph.core(context),
                CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
            ).also { shared = it }
        }
    }
}
