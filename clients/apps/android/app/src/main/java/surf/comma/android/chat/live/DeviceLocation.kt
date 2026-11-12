package surf.comma.android.chat.live

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import java.util.concurrent.atomic.AtomicInteger

/**
 * This device's position, read once: when the person chooses to share it, which asks the system's location permission
 * first, or for [AgentLocationAnswers] once the system allows it. The person may grant only an approximate position.
 * A read ends within [TIMEOUT_MS]; nothing here keeps a position.
 */
internal class DeviceLocation(private val activity: ComponentActivity) {
    sealed interface Reading {
        data class At(val latitude: Double, val longitude: Double, val accuracy: Float?) : Reading
        data object Denied : Reading
        data object Unavailable : Reading
    }

    /** Asks if needed, then reads; [done] is called once on the main thread. */
    fun read(done: (Reading) -> Unit) {
        if (allowed(activity)) {
            readGranted(activity, done)
            return
        }
        // Not registerForActivityResult: this screen can start after the activity has resumed.
        val launcher = arrayOfNulls<androidx.activity.result.ActivityResultLauncher<Array<String>>>(1)
        launcher[0] = activity.activityResultRegistry.register(
            "agent-request-location-${NEXT_KEY.incrementAndGet()}",
            ActivityResultContracts.RequestMultiplePermissions(),
        ) { granted ->
            launcher[0]?.unregister()
            if (granted.values.any { it }) readGranted(activity, done) else done(Reading.Denied)
        }
        launcher[0]!!.launch(PERMISSIONS)
    }

    companion object {
        private const val TIMEOUT_MS = 15_000L
        private val PERMISSIONS = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        private val PROVIDERS = listOf(LocationManager.FUSED_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
        private val NEXT_KEY = AtomicInteger()

        /** Whether the system lets this app read a position, so a read asks nothing. */
        fun allowed(context: Context): Boolean =
            PERMISSIONS.any { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

        /** Reads now, without asking: the caller checked [allowed]. [done] is called once on the main thread. */
        @Suppress("MissingPermission")
        fun readGranted(context: Context, done: (Reading) -> Unit) {
            val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val provider = PROVIDERS.firstOrNull { manager.hasProvider(it) && manager.isProviderEnabled(it) }
            if (provider == null) {
                done(Reading.Unavailable)
                return
            }
            val main = Handler(Looper.getMainLooper())
            val signal = CancellationSignal()
            var ended = false
            fun end(location: Location?) {
                if (ended) return
                ended = true
                main.removeCallbacksAndMessages(signal)
                done(location?.let { Reading.At(it.latitude, it.longitude, it.takeIf(Location::hasAccuracy)?.accuracy) }
                    ?: Reading.Unavailable)
            }
            main.postDelayed({
                signal.cancel()
                end(manager.getLastKnownLocation(provider))
            }, signal, TIMEOUT_MS)
            manager.getCurrentLocation(provider, signal, context.mainExecutor) { end(it) }
        }
    }
}
