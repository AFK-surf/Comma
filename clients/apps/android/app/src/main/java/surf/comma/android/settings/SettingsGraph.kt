package surf.comma.android.settings

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.settings.devices.AddDeviceSession
import surf.comma.android.settings.devices.AndroidDeviceLink
import surf.comma.android.settings.devices.AndroidDeviceScanner
import surf.comma.android.settings.devices.EncryptedPairedDeviceStore
import surf.comma.android.settings.devices.HomeDevices
import surf.comma.android.settings.devices.DeviceSetupOffer
import surf.comma.android.settings.devices.NearbyDevices
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File

/** Process-owned settings state, shared by the settings screens and the chat's account button. */
object SettingsGraph {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var repository: SettingsRepository? = null
    @Volatile private var local: LocalSettings? = null

    fun account(context: Context): SettingsRepository = repository ?: synchronized(this) {
        repository ?: SettingsRepository(AuthConversationSessions(AuthGraph.get(context)), AuthGraph.core(context), scope)
            .also { it.start(); repository = it }
    }

    @Volatile private var devices: HomeDevices? = null
    /** The add-device flow in progress, kept across the settings page being recreated. */
    @Volatile internal var addDevice: AddDeviceSession? = null
        private set
    internal val addDeviceOpen = MutableStateFlow(false)

    internal fun devices(context: Context): HomeDevices = devices ?: synchronized(this) {
        devices ?: createDevices(context.applicationContext).also { it.start(); devices = it }
    }

    /** Starts a flow for the signed-in workspace, ending any earlier one; null while signed out. */
    @Synchronized
    internal fun startAddDevice(context: Context, offer: DeviceSetupOffer? = null): AddDeviceSession? {
        addDevice?.close()
        val app = context.applicationContext
        val devices = devices(app)
        val owner = devices.currentOwner() ?: return null
        return AddDeviceSession(owner, devices, AndroidDeviceScanner(app), { AndroidDeviceLink(app, it.address) }, scope,
            preferredName = offer?.bluetoothName,
            offer = offer?.offerId, onOfferNotUpdated = { NearbyDevices.get(app).offerNotUpdated(owner) })
            .also { addDevice = it }
    }

    @Synchronized
    internal fun endAddDevice(session: AddDeviceSession) {
        session.close()
        if (addDevice === session) addDevice = null
    }

    private fun createDevices(context: Context): HomeDevices {
        val auth = AuthGraph.get(context)
        val store = EncryptedPairedDeviceStore(File(context.noBackupFilesDir, "comma-devices.bin"), AuthGraph.cipher("comma.devices.v1"))
        return HomeDevices(AuthConversationSessions(auth), AuthGraph.core(context), auth::productLease,
            { (auth.state.value as? AuthState.Connected)?.selection?.workspace?.id }, store, scope)
    }

    fun local(context: Context): LocalSettings = local ?: synchronized(this) {
        local ?: LocalSettings(AndroidLocalSettings(context)).also { local = it }
    }
}
