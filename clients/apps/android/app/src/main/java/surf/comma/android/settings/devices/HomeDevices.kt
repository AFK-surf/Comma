package surf.comma.android.settings.devices

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ConversationSessions
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.settings.HomeDevice
import surf.comma.android.settings.SettingsProblem
import java.util.UUID

/** What the device settings ask of the client core, bound to one signed-in session and workspace. */
internal interface HomeDeviceBackend {
    /**
     * The workspace's devices, kept current while collected (the core reads them again every 15 s while shown): each
     * read that settled, or why it failed.
     */
    fun devices(): Flow<Result<List<HomeDevice>>>
    /** Reads the devices of a collected [devices] again now. */
    suspend fun reload()
    suspend fun device(id: String): HomeDevice?
    suspend fun rename(id: String, name: String)
    suspend fun remove(id: String)
    /** Returns whether the device now allows operations, as the device itself answered. */
    suspend fun setAccess(id: String, allow: Boolean): Boolean
    /**
     * A new device's two credentials, all or nothing (`connector.provisionDevice`); [offer] is the setup offer it
     * answers. Started requests finish even when the caller is cancelled, so a credential is never lost unrevoked.
     */
    suspend fun provision(name: String, offer: String?): ProvisionedDevice
    /** Revokes a device's credentials: the token when this phone kept it, the voice key by id or by its name. */
    suspend fun unprovision(deviceId: String, connectorToken: String?, voiceKeyId: String?)
}

/** What [HomeDeviceBackend.provision] gave: the device's credentials, and whether its setup offer heard of it. */
internal class ProvisionedDevice(val credentials: DeviceCredentials, val offerUpdated: Boolean)

/** Who a flow or a removal acts for. It keeps acting for them even if the account changes meanwhile. */
internal class DeviceOwner(val scope: ConversationScope, val workspaceId: String, val backend: HomeDeviceBackend) {
    val accountId: String get() = scope.accountId
}

/** [HomeDeviceBackend] through the client core: its `devices` and `voice` topics and calls, and its Connector calls. */
private class CoreHomeDeviceBackend(
    private val core: CoreApi,
    private val lease: () -> JSONObject?,
    private val workspaceId: String,
) : HomeDeviceBackend {
    private fun params() = JSONObject().put("workspace", workspaceId)

    /** The first settled value of [topic]; the topic is let go once it is read. */
    private suspend fun <T> read(topic: JSONObject, settled: (JSONObject) -> T?): T =
        when (val value = core.subscribe(topic) { it as? JSONObject }.first {
            it is TopicValue.Failed || (it as TopicValue.Value).value?.let(settled) != null
        }) {
            is TopicValue.Failed -> throw value.error
            is TopicValue.Value -> settled(value.value!!)!!
        }

    override fun devices(): Flow<Result<List<HomeDevice>>> =
        // Each collection is a visit of its own: the core checks stale Agent runtimes once per visit.
        core.subscribe(JSONObject().put("topic", "devices").put("prefer", workspaceId).put("visit", UUID.randomUUID().toString())) { value ->
            val json = value as? JSONObject
            when {
                json == null || json.optBoolean("loading") -> null
                json.optBoolean("failed") -> Result.failure(CoreError("unavailable", "The devices could not be read."))
                else -> Result.success(objects(json.optJSONArray("devices")).mapNotNull(::homeDevice).distinctBy { it.id })
            }
        }.mapNotNull { value ->
            when (value) {
                is TopicValue.Failed -> Result.failure(value.error)
                is TopicValue.Value -> value.value
            }
        }

    override suspend fun reload() {
        core.call("devices.refresh")
    }

    override suspend fun device(id: String): HomeDevice? =
        (core.call("devices.get", params().put("device", id)) as? JSONObject)?.let(::homeDevice)

    override suspend fun rename(id: String, name: String) {
        core.call("devices.rename", params().put("device", id).put("name", name))
    }

    override suspend fun remove(id: String) = ignoreMissing { core.call("devices.remove", params().put("device", id)) }

    override suspend fun setAccess(id: String, allow: Boolean): Boolean =
        core.call("devices.setAccess", params().put("device", id).put("allow", allow)) as? Boolean
            ?: throw CoreError("bad_response", "The device did not say.")

    override suspend fun provision(name: String, offer: String?): ProvisionedDevice = withContext(NonCancellable) {
        val json = core.call("connector.provisionDevice", JSONObject().put("workspaceId", workspaceId).put("name", name)
            .apply { offer?.let { put("offer", it) } }.put("lease", lease() ?: throw CoreError("session_changed", "Signed out.")))
            as? JSONObject ?: throw badResponse()
        ProvisionedDevice(DeviceCredentials(json.getString("deviceId"), json.getString("connectorToken"),
            json.getString("connectUrl"), json.getString("voiceKeyId"), json.getString("voiceKey"),
            json.getString("voiceServer"), json.getString("voiceGroup")), json.optBoolean("offerUpdated"))
    }

    override suspend fun unprovision(deviceId: String, connectorToken: String?, voiceKeyId: String?) {
        withContext(NonCancellable) {
            core.call("connector.unprovisionDevice", JSONObject().put("workspaceId", workspaceId).put("deviceId", deviceId)
                .apply { connectorToken?.let { put("connectorToken", it) }; voiceKeyId?.let { put("voiceKeyId", it) } }
                .put("lease", lease() ?: throw CoreError("session_changed", "Signed out.")))
        }
    }

    private fun homeDevice(json: JSONObject): HomeDevice? {
        val id = json.string("device_id") ?: return null
        return HomeDevice(id, json.string("name") ?: id, json.optString("status") == "connected",
            json.optJSONObject("system_info")?.string("client_source"),
            json.optLong("disconnected_at").takeIf { it > 0 }, json.optBoolean("allows_operations"))
    }

    private suspend fun ignoreMissing(block: suspend () -> Unit) {
        try { block() } catch (e: CoreError) { if (e.status != 404) throw e }
    }

    private fun badResponse() = CoreError("bad_response", "The answer is not one.")

    private fun objects(array: JSONArray?): List<JSONObject> =
        if (array == null) emptyList() else (0 until array.length()).mapNotNull(array::optJSONObject)

    private fun JSONObject.string(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }
}

internal object DeviceCredentialRules {
    /** Unconfirmed credentials older than this, for a device that never connected, are revoked. */
    const val PENDING_GRACE_MILLIS = 15 * 60 * 1000L
}

data class HomeDevicesState(
    val devices: List<HomeDevice>? = null,
    val loading: Boolean = false,
    val problem: SettingsProblem? = null,
    val removing: Set<String> = emptySet(),
    /** Access changes on their way to a device: the value asked for, shown until the device answers. */
    val accessPending: Map<String, Boolean> = emptyMap(),
    /** Why the last access change of a device did not go through. */
    val accessProblems: Map<String, AccessProblem> = emptyMap(),
) {
    /** What the device's switch shows: the change on its way, else the device's own state. */
    fun allowsOperations(device: HomeDevice): Boolean = accessPending[device.id] ?: device.allowsOperations
}

internal enum class HomeDeviceNotice { LOAD_FAILED, REMOVE_FAILED, REMOVED }

/** Why an access change did not go through. */
enum class AccessProblem {
    /** The device did not confirm the change (`device_access_unavailable`). */
    UNCONFIRMED,
    OFFLINE,
    TIMEOUT,
    FORBIDDEN,
    NOT_FOUND,
    NETWORK,
    SERVER,
    ;

    companion object {
        fun of(e: Exception): AccessProblem = when {
            e !is CoreError -> NETWORK
            e.code == "device_access_unavailable" -> UNCONFIRMED
            e.code == "disconnected" -> OFFLINE
            e.code == "timeout" -> TIMEOUT
            e.status == 403 -> FORBIDDEN
            e.status == 404 -> NOT_FOUND
            e.status == null -> NETWORK
            else -> SERVER
        }
    }
}

/**
 * The workspace's Connector devices for the settings, and this phone's record of the Comma devices
 * it set up. Removing a device revokes its connector token (when this phone set it up) and voice
 * key, then deletes it; the device itself has to be reset by hand.
 */
internal class HomeDevices(
    private val sessions: ConversationSessions,
    private val workspaceId: () -> String?,
    val store: PairedDeviceStore,
    private val owner: CoroutineScope,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val backendFor: (ConversationScope, String) -> HomeDeviceBackend?,
) {
    /** The app's: the client core's, with the session's lease for the Connector calls. */
    constructor(sessions: ConversationSessions, core: CoreApi?, lease: () -> JSONObject?, workspaceId: () -> String?,
        store: PairedDeviceStore, owner: CoroutineScope) :
        this(sessions, workspaceId, store, owner, backendFor = { _, ws -> core?.let { CoreHomeDeviceBackend(it, lease, ws) } })

    private val mutableState = MutableStateFlow(HomeDevicesState())
    val state: StateFlow<HomeDevicesState> = mutableState.asStateFlow()
    private val mutableNotices = MutableSharedFlow<HomeDeviceNotice>(extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val notices: SharedFlow<HomeDeviceNotice> = mutableNotices.asSharedFlow()
    private val storeLock = Mutex()
    private var bound: ConversationScope? = null

    fun start() {
        synchronized(this) { bound = sessions.scopes.value }
        owner.launch {
            sessions.scopes.collect { scope ->
                synchronized(this@HomeDevices) {
                    if (scope === bound) return@collect
                    bound = scope
                    watching?.cancel()
                    watching = null
                    mutableState.value = HomeDevicesState()
                }
            }
        }
    }

    /** The signed-in account and workspace, or null while signed out. */
    fun currentOwner(): DeviceOwner? {
        val scope = sessions.scopes.value ?: return null
        val workspace = workspaceId() ?: return null
        return DeviceOwner(scope, workspace, backendFor(scope, workspace) ?: return null)
    }

    private var watching: Job? = null

    /**
     * Follows the list while a page shows it ([visible]): the core reads it again every 15 s meanwhile, as a device's
     * status changes while nobody touches the app (a Connector drops).
     */
    fun show(visible: Boolean) {
        synchronized(this) {
            watching?.cancel()
            watching = null
            if (!visible) return
            val owner = currentOwner() ?: return
            edit(owner) { it.copy(loading = true, problem = null) }
            watching = this.owner.launch { owner.backend.devices().collect { listed(owner, it) } }
        }
    }

    /** Reads the list again now: the one shown, or once for a page that does not follow it. */
    fun refresh() {
        val owner = currentOwner() ?: return
        val shown = synchronized(this) { watching?.takeIf { it.isActive } }
        this.owner.launch {
            if (!edit(owner) { it.copy(loading = true, problem = null) }) return@launch
            if (shown != null) runCatching { owner.backend.reload() }
            else listed(owner, owner.backend.devices().first())
        }
    }

    private suspend fun listed(owner: DeviceOwner, read: Result<List<HomeDevice>>) {
        read.onSuccess { devices ->
            reconcile(owner, devices)
            edit(owner) { it.copy(devices = devices.filterNot { device -> device.id in it.removing }, loading = false, problem = null) }
        }.onFailure { e ->
            if (e is CancellationException) throw e
            if (edit(owner) { it.copy(loading = false, problem = problem(e as? Exception ?: Exception(e))) })
                mutableNotices.tryEmit(HomeDeviceNotice.LOAD_FAILED)
        }
    }

    /** Reloads one device, for its page. A device that is gone leaves the list. */
    fun refresh(deviceId: String) {
        val owner = currentOwner() ?: return
        this.owner.launch {
            try {
                val device = owner.backend.device(deviceId)
                edit(owner) { state ->
                    val devices = state.devices ?: return@edit state
                    state.copy(devices = when {
                        device == null -> devices.filterNot { it.id == deviceId }
                        devices.any { it.id == deviceId } -> devices.map { if (it.id == deviceId) device else it }
                        else -> devices + device
                    })
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                // The page keeps what the list showed.
            }
        }
    }

    /**
     * Asks the device to allow or stop operations. The switch shows [allow] until the device
     * answers; on failure it goes back and the reason is kept for the page.
     */
    fun setAccess(device: HomeDevice, allow: Boolean) {
        val owner = currentOwner() ?: return
        var started = false
        edit(owner) {
            if (device.id in it.accessPending) return@edit it
            started = true
            it.copy(accessPending = it.accessPending + (device.id to allow), accessProblems = it.accessProblems - device.id)
        }
        if (!started) return
        this.owner.launch {
            try {
                val allows = owner.backend.setAccess(device.id, allow)
                edit(owner) { state ->
                    state.copy(
                        devices = state.devices?.map { if (it.id == device.id) it.copy(allowsOperations = allows) else it },
                        accessPending = state.accessPending - device.id,
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) {
                    edit(owner) { it.copy(accessPending = it.accessPending - device.id) }
                    throw e
                }
                val problem = AccessProblem.of(e)
                edit(owner) { state ->
                    state.copy(
                        // The server found the device offline: show it so, which also disables the switch.
                        devices = if (problem != AccessProblem.OFFLINE) state.devices
                        else state.devices?.map { if (it.id == device.id) it.copy(online = false) else it },
                        accessPending = state.accessPending - device.id,
                        accessProblems = state.accessProblems + (device.id to problem),
                    )
                }
            }
        }
    }

    /** Revokes the device's credentials, then removes it. On failure nothing is removed. */
    fun remove(device: HomeDevice) {
        val owner = currentOwner() ?: return
        var started = false
        edit(owner) {
            if (device.id in it.removing) return@edit it
            started = true
            it.copy(removing = it.removing + device.id)
        }
        if (!started) return
        this.owner.launch {
            try {
                val record = storeLock.withLock { record(owner, device.id) }
                owner.backend.unprovision(device.id, record?.connectorToken, record?.voiceKeyId)
                owner.backend.remove(device.id)
                storeLock.withLock { store.remove(device.id) }
                edit(owner) { state ->
                    state.copy(devices = state.devices?.filterNot { it.id == device.id }, removing = state.removing - device.id)
                }
                mutableNotices.tryEmit(HomeDeviceNotice.REMOVED)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                edit(owner) { it.copy(removing = it.removing - device.id) }
                mutableNotices.tryEmit(HomeDeviceNotice.REMOVE_FAILED)
            }
        }
    }

    /** Whether this phone set up [deviceId] and can therefore revoke its connector token. */
    fun setUpHere(deviceId: String): Boolean {
        val owner = currentOwner() ?: return false
        return runCatching { record(owner, deviceId) != null }.getOrDefault(false)
    }

    suspend fun remember(owner: DeviceOwner, credentials: DeviceCredentials, name: String) = storeLock.withLock {
        store.put(PairedDevice(owner.accountId, owner.workspaceId, credentials.deviceId, credentials.voiceKeyId,
            credentials.connectorToken, name, nowMillis(), confirmed = false))
    }

    suspend fun confirm(owner: DeviceOwner, deviceId: String) = storeLock.withLock {
        record(owner, deviceId)?.let { store.put(it.confirmed()) }
    }

    /** Revokes credentials the device never confirmed. Kept for a later try if the backend cannot be reached. */
    suspend fun revoke(owner: DeviceOwner, credentials: DeviceCredentials) {
        try {
            owner.backend.unprovision(credentials.deviceId, credentials.connectorToken, credentials.voiceKeyId)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            // remember() may not have run yet; make sure there is a record to retry from. When storage
            // fails too there is nothing more this phone can do.
            storeLock.withLock {
                runCatching {
                    if (record(owner, credentials.deviceId) == null) {
                        store.put(PairedDevice(owner.accountId, owner.workspaceId, credentials.deviceId, credentials.voiceKeyId,
                            credentials.connectorToken, credentials.deviceId, 0L, confirmed = false))
                    }
                }
            }
            return
        }
        // Revoked; a record left behind only repeats the revocation later.
        storeLock.withLock { runCatching { store.remove(credentials.deviceId) } }
    }

    /**
     * Unconfirmed setups: a device that has connected keeps its credentials; one that never did
     * within the grace period has them revoked. Connected means online now, or its host facts
     * (`system_info`), which only a connected device reports. `connected_at` is no evidence: the
     * server fills it in for a device that has never connected.
     */
    private suspend fun reconcile(owner: DeviceOwner, devices: List<HomeDevice>) {
        val pending = storeLock.withLock {
            runCatching { store.all() }.getOrDefault(emptyList())
                .filter { it.accountId == owner.accountId && it.workspaceId == owner.workspaceId && !it.confirmed }
        }
        for (record in pending) {
            val device = devices.firstOrNull { it.id == record.deviceId }
            when {
                device != null && (device.online || device.clientSource != null) ->
                    storeLock.withLock { runCatching { store.put(record.confirmed()) } }
                nowMillis() - record.createdAtMillis > DeviceCredentialRules.PENDING_GRACE_MILLIS -> try {
                    owner.backend.unprovision(record.deviceId, record.connectorToken, record.voiceKeyId)
                    storeLock.withLock { runCatching { store.remove(record.deviceId) } }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                }
            }
        }
    }

    private fun record(owner: DeviceOwner, deviceId: String): PairedDevice? = store.all().firstOrNull {
        it.deviceId == deviceId && it.accountId == owner.accountId && it.workspaceId == owner.workspaceId
    }

    private fun edit(owner: DeviceOwner, change: (HomeDevicesState) -> HomeDevicesState): Boolean = synchronized(this) {
        if (bound !== owner.scope || !sessions.isCurrent(owner.scope)) return false
        mutableState.update(change)
        true
    }

    private fun problem(e: Exception): SettingsProblem = when {
        e is CoreError && e.status == 403 -> SettingsProblem.FORBIDDEN
        e is CoreError && (e.status != null || e.code == "bad_response") -> SettingsProblem.SERVER
        else -> SettingsProblem.NETWORK
    }
}
