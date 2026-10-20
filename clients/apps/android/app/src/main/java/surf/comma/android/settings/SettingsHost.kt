package surf.comma.android.settings

import android.Manifest
import android.app.NotificationManager
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.media.AndroidImagePreprocessor
import surf.comma.android.media.UploadImageFormat
import surf.comma.android.notify.ReplyNotifications
import surf.comma.android.notify.ReplyNotifier
import surf.comma.android.settings.devices.HomeDeviceNotice
import surf.comma.android.settings.devices.HomeDevices
import java.io.File

/**
 * The settings pages and what they need from the app, for the Settings tab and for the settings activity.
 * Build it while [activity] is being created: it registers the activity's result launchers. [embedded] is the
 * tab: its root page stays, has no back button, and back pops only what is pushed over it.
 */
internal class SettingsHost(
    override val activity: ComponentActivity,
    private val embedded: Boolean,
    /** Shows a short notice; `true` marks a failure. */
    toast: (String, Boolean) -> Unit,
    onEmpty: () -> Unit = {},
) : SettingsContext {
    private val showToast = toast
    private val authRepository = AuthGraph.get(activity)
    override val account: SettingsRepository by lazy { SettingsGraph.account(activity) }
    override val local: LocalSettings by lazy { SettingsGraph.local(activity) }
    override val auth: AuthState get() = authRepository.state.value
    override val devices: HomeDevices by lazy { SettingsGraph.devices(activity) }
    override val workspaces get() = surf.comma.android.workspace.WorkspaceGraph.get(activity).tasks.state.value.workspaces

    val host = PageHost(activity, onEmpty).apply { keepsRoot = embedded }
    /** Whether the Settings tab is the one shown; a hidden tab leaves back to the tab that is. */
    var active: Boolean
        get() = host.active
        set(value) {
            host.active = value
        }
    private var insetTop = 0
    private var insetBottom = 0
    /** Room the page keeps at its foot, over the tab bar. */
    var bottomReserve = 0
        set(value) {
            field = value
            host.pages().forEach(::inset)
        }

    private val pickImage = activity.registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) prepareAvatar(uri)
    }
    private val notificationPermission = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        renderAll()
    }
    private val bluetoothPermission = activity.registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        renderAll()
    }
    private val bluetoothOn = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        renderAll()
    }

    override val replyNotifications = object : ReplyNotificationSetting {
        private val controller by lazy { ReplyNotifications.get(activity) }

        override val state get() = when {
            !controller.enabled.value -> ReplyNotificationState.OFF
            !controller.canPost() -> ReplyNotificationState.BLOCKED
            else -> ReplyNotificationState.ON
        }

        override fun set(enabled: Boolean) {
            controller.setEnabled(enabled)
            if (enabled && !controller.canPost()) {
                val permission = Manifest.permission.POST_NOTIFICATIONS
                val manager = activity.getSystemService(NotificationManager::class.java)
                val unblock = notificationUnblock(
                    permissionGranted = controller.permissionGranted(),
                    askedBefore = controller.permissionAskedBefore(),
                    showsRationale = activity.shouldShowRequestPermissionRationale(permission),
                    appEnabled = manager.areNotificationsEnabled(),
                    channelEnabled = manager.getNotificationChannel(ReplyNotifier.CHANNEL_REPLIES)
                        ?.importance != NotificationManager.IMPORTANCE_NONE,
                )
                when (unblock) {
                    NotificationUnblock.REQUEST_PERMISSION -> {
                        controller.permissionAsked()
                        notificationPermission.launch(permission)
                    }
                    // Only the system can turn these back on; resuming redraws on the way back.
                    NotificationUnblock.APP_SETTINGS -> activity.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
                    NotificationUnblock.CHANNEL_SETTINGS -> activity.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        .putExtra(Settings.EXTRA_CHANNEL_ID, ReplyNotifier.CHANNEL_REPLIES))
                    NotificationUnblock.NONE -> Unit
                }
            }
            renderAll()
        }
    }

    init {
        ViewCompat.setOnApplyWindowInsetsListener(host) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            insetTop = bars.top
            insetBottom = bars.bottom
            host.pages().forEach(::inset)
            insets
        }
        activity.onBackPressedDispatcher.addCallback(activity, host.backCallback)
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    combine(account.state, local.state, authRepository.state, devices.state, surf.comma.android.workspace.WorkspaceGraph.get(activity).tasks.state) { _, _, _, _, _ -> }
                        .collect { renderAll() }
                }
                launch { merge(account.notices, local.notices).collect(::showNotice) }
                launch { devices.notices.collect(::showDeviceNotice) }
            }
        }
    }

    /** Whether this is the Settings tab, whose root has no back button. */
    val isTab: Boolean get() = embedded

    override fun open(page: SettingsPage) {
        inset(page)
        host.push(page)
    }

    fun restore(page: SettingsPage) {
        inset(page)
        host.push(page, animate = false)
    }

    override fun back() = host.pop()

    override fun onRender(page: SettingsPage, render: () -> Unit) = host.onRender(page, render)

    override fun toast(text: String, failure: Boolean) = showToast(text, failure)

    override fun requestBluetoothPermission() {
        val prefs = activity.getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE)
        val asked = prefs.getBoolean(BLUETOOTH_ASKED, false)
        val rationale = BLUETOOTH_PERMISSIONS.any(activity::shouldShowRequestPermissionRationale)
        if (!asked || rationale) {
            prefs.edit().putBoolean(BLUETOOTH_ASKED, true).apply()
            bluetoothPermission.launch(BLUETOOTH_PERMISSIONS)
        } else {
            // Denied for good: only the app's settings can grant it now; resuming redraws on the way back.
            activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", activity.packageName, null)))
        }
    }

    override fun requestBluetoothOn() {
        bluetoothOn.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
    }

    override fun pickAvatar() {
        pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }

    override fun signOut() {
        // The existing logout: requests of this session end with it, then the sign-in page opens.
        AuthGraph.scope.launch { authRepository.logout() }
    }

    /** Resizes and strips the picked image with the media pipeline, then hands it to the account. */
    private fun prepareAvatar(uri: android.net.Uri) {
        val directory = File(activity.cacheDir, "avatar-upload")
        activity.lifecycleScope.launch {
            try {
                val prepared = AndroidImagePreprocessor(activity.contentResolver, directory, targetBytes = AVATAR_TARGET_BYTES).prepare(uri)
                if (prepared.format == UploadImageFormat.GIF) {
                    prepared.close()
                    showNotice(SettingsNotice(SettingsAction.CHANGE_AVATAR, SettingsProblem.AVATAR_TYPE))
                    return@launch
                }
                account.changeAvatar(prepared.file, prepared.format.mime)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                showNotice(SettingsNotice(SettingsAction.CHANGE_AVATAR, SettingsProblem.AVATAR_TYPE))
            }
        }
    }

    fun renderAll() = host.render()

    private fun showNotice(notice: SettingsNotice) {
        toast(SettingsMessages.text(activity, notice), true)
    }

    private fun showDeviceNotice(notice: HomeDeviceNotice) {
        toast(activity.getString(when (notice) {
            HomeDeviceNotice.LOAD_FAILED -> R.string.devices_failed
            HomeDeviceNotice.REMOVE_FAILED -> R.string.devices_remove_failed
            HomeDeviceNotice.REMOVED -> R.string.devices_removed
        }), notice != HomeDeviceNotice.REMOVED)
    }

    private fun inset(page: SettingsPage) {
        (page.view as? SettingsPageLayout)?.applyInsets(insetTop, insetBottom + bottomReserve)
    }

    private companion object {
        const val PERMISSION_PREFS = "settings.permissions"
        const val BLUETOOTH_ASKED = "bluetooth.asked"
        /** Under the server's 100 KB limit with some margin. */
        const val AVATAR_TARGET_BYTES = 96L * 1024
    }
}
