package surf.comma.android.ui.connection

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged

/** Observes the system's default internet connection. It never sends a request or probes a host. */
internal fun connectionAvailability(context: Context) = callbackFlow<Boolean?> {
    val manager = context.getSystemService(ConnectivityManager::class.java)
    fun available() = manager.getNetworkCapabilities(manager.activeNetwork)?.let(::hasInternet) ?: false
    val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            trySend(hasInternet(capabilities))
        }
        override fun onLost(network: Network) { trySend(available()) }
    }
    manager.registerDefaultNetworkCallback(callback)
    trySend(available())
    awaitClose { manager.unregisterNetworkCallback(callback) }
}.distinctUntilChanged()

// System validation endpoints can be blocked even when the app's server is reachable.
// Let the existing request classify reachability; do not strand retry on validation.
private fun hasInternet(capabilities: NetworkCapabilities) =
    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
