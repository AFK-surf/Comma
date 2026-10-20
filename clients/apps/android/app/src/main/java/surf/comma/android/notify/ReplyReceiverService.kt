package surf.comma.android.notify

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import surf.comma.android.platform.logging.AppLog

/**
 * Keeps the process running while a hidden chat waits for a reply, so the conversation layer's
 * own stream keeps receiving it. The service holds no data and opens no connection itself.
 *
 * A `dataSync` foreground service: a plain started service is stopped about a minute after the app
 * leaves the foreground and its process is then frozen, and a `shortService` ends after three
 * minutes; a reply can take longer. Its notification is deferred by the system, so a hold that
 * ends within a few seconds shows nothing, and it sits in a silent minimum-importance channel
 * otherwise. A partial wake lock, bounded by the hold's window, keeps the CPU up with the screen off.
 * It stops as soon as [ReplyNotifications.serviceWanted] turns false.
 */
class ReplyReceiverService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForeground(ReplyNotifier.RECEIVING_ID, ReplyNotifier(this).receiving(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } catch (e: RuntimeException) {
            AppLog.warn(TAG, e, "Background receiving could not start")
            stopSelf()
            return START_NOT_STICKY
        }
        val controller = ReplyNotifications.current
        if (controller == null || !controller.serviceWanted.value) {
            stop()
            return START_NOT_STICKY
        }
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
                .apply { setReferenceCounted(false); acquire(ReplyWatch.WINDOW_MILLIS) }
            AppLog.info(TAG, "Background receiving started")
            scope.launch {
                controller.serviceWanted.first { !it }
                stop()
            }
        }
        return START_NOT_STICKY
    }

    /** The system's daily limit for this service type ran out. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        ReplyNotifications.current?.serviceTimedOut()
        stop()
    }

    private fun stop() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        AppLog.info(TAG, "Background receiving stopped")
        super.onDestroy()
    }

    companion object {
        private const val TAG = "ReplyReceiver"
        private const val WAKE_LOCK_TAG = "comma:reply-receiver"

        fun start(context: Context) {
            try {
                context.startForegroundService(Intent(context, ReplyReceiverService::class.java))
            } catch (e: IllegalStateException) {
                // Includes ForegroundServiceStartNotAllowedException. The hold still lasts while
                // the process does; only the keep-alive is missing.
                AppLog.warn(TAG, e, "Background receiving not allowed")
            }
        }
    }
}
