package surf.comma.android.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import androidx.core.net.toUri
import surf.comma.android.MainActivity
import surf.comma.android.R

internal class CallNotifier(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    fun createChannel() {
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Voice calls",
            NotificationManager.IMPORTANCE_DEFAULT).apply { setShowBadge(false) })
    }

    fun build(state: CallControllerState): Notification {
        val text = callNotificationText(state.call, state.notice)
        val open = PendingIntent.getActivity(context, ID,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(CallController.EXTRA_EXPAND_CALL, true),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_cue_mark)
            .setContentTitle("Comma")
            .setContentText(text.text)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(text.ongoing)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (text.ongoing) {
            // Unique data prevents an old notification's action from ending a newer call.
            val hangUp = PendingIntent.getService(context, ID,
                Intent(context, CallService::class.java).setAction(CallService.ACTION_HANG_UP)
                    .setData("comma-call:/${state.id}".toUri())
                    .putExtra(CallService.EXTRA_ID, state.id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val person = Person.Builder().setName("Comma")
                .setIcon(IconCompat.createWithResource(context, R.drawable.ic_cue_mark)).setImportant(true).build()
            builder.setStyle(NotificationCompat.CallStyle.forOngoingCall(person, hangUp))
        } else {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(text.text))
                .setTimeoutAfter(if (state.call.phase == CallPhase.Failed) CallStopTimer.FAILED_MILLIS else CallStopTimer.ENDED_MILLIS)
        }
        return builder.build()
    }

    fun post(state: CallControllerState) {
        // Foreground promotion itself is allowed without POST_NOTIFICATIONS; updates are best effort.
        if (context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        manager.notify(ID, build(state))
    }

    companion object {
        const val ID = 3
        const val CHANNEL = "voice_calls"
    }
}
