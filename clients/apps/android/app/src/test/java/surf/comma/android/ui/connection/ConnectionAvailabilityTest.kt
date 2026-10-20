package surf.comma.android.ui.connection

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkCapabilities
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ConnectionAvailabilityTest {
    @Test fun `internet availability retries even without system validation and unregisters on cancellation`() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val shadow = shadowOf(manager)
        shadow.clearAllNetworks()
        shadow.setActiveNetworkInfo(null)
        val availability = mutableListOf<Boolean?>()
        val collection = launch { connectionAvailability(context).collect { availability += it } }
        runCurrent()
        assertEquals(listOf(false), availability)
        val callback = shadow.networkCallbacks.single()
        val network = ShadowNetwork.newInstance(123)
        val capabilities = ShadowNetworkCapabilities.newInstance()
        callback.onCapabilitiesChanged(network, capabilities)
        runCurrent()
        assertEquals("a network without internet capability stays offline", listOf(false), availability)
        shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        callback.onCapabilitiesChanged(network, capabilities)
        runCurrent()
        assertEquals("blocked validation endpoints must not strand recovery", listOf(false, true), availability)
        shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        callback.onCapabilitiesChanged(network, capabilities)
        callback.onCapabilitiesChanged(network, capabilities)
        runCurrent()
        assertEquals(listOf(false, true), availability)
        callback.onLost(network)
        runCurrent()
        assertEquals(listOf(false, true, false), availability)
        collection.cancel()
        runCurrent()
        assertTrue(shadow.networkCallbacks.isEmpty())
    }
}
