package surf.comma.android.miniapps

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.CompletableDeferred
import surf.comma.android.R

/**
 * The run screen's device effects for host operations. The core authorized each one, and links, Task proposals and
 * capability grants were confirmed in [MiniAppHostDialog] first. A draft goes to the signed-in app's chat composer and
 * is never sent. Must be created before the activity starts, as it registers the notification permission request.
 */
internal class MiniAppDevice(private val activity: ComponentActivity) : MiniAppDeviceHost {
    private var permission: CompletableDeferred<Boolean>? = null
    private val ask = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permission?.complete(granted)
        permission = null
    }

    override fun draft(text: String): Boolean {
        val target = MiniAppRuntimes.draftTarget ?: return false
        target(text)
        return true
    }

    override fun copy(text: String) {
        val clipboard = activity.getSystemService(ClipboardManager::class.java) ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText(null, text))
    }

    override fun open(url: String): Boolean {
        if (!MiniAppSession.isOpenableLink(url)) return false
        return try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    override suspend fun notify(title: String, body: String): Boolean {
        if (!granted()) {
            if (permission != null) return false
            val reply = CompletableDeferred<Boolean>().also { permission = it }
            ask.launch(Manifest.permission.POST_NOTIFICATIONS)
            if (!reply.await()) return false
        }
        val manager = activity.getSystemService(NotificationManager::class.java) ?: return false
        manager.createNotificationChannel(NotificationChannel(CHANNEL, activity.getString(R.string.mini_app_notify_channel),
            NotificationManager.IMPORTANCE_DEFAULT))
        if (!manager.areNotificationsEnabled()) return false
        val notification = Notification.Builder(activity, CHANNEL)
            .setSmallIcon(R.drawable.ic_cue_mark)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .build()
        return try {
            manager.notify("mini-app", (System.nanoTime() and 0x7fffffff).toInt(), notification)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    /** The screen closed: a pending permission prompt answers no. */
    fun release() {
        permission?.complete(false)
        permission = null
    }

    private fun granted() = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private companion object {
        const val CHANNEL = "mini_apps"
    }
}
