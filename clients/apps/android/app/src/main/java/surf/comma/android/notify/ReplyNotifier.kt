package surf.comma.android.notify

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import surf.comma.android.R

/** The two notification channels and the reply notifications posted in them. */
internal class ReplyNotifier(context: Context) : ReplyPoster {
    private val app = context.applicationContext
    private val manager = app.getSystemService(NotificationManager::class.java)

    fun createChannels() {
        manager.createNotificationChannels(listOf(
            NotificationChannel(CHANNEL_REPLIES, app.getString(R.string.notify_channel_replies),
                NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = app.getString(R.string.notify_channel_replies_description)
            },
            // Only seen while a hold outlives the system's delay before showing it; never alerts.
            NotificationChannel(CHANNEL_RECEIVING, app.getString(R.string.notify_channel_receiving),
                NotificationManager.IMPORTANCE_MIN).apply {
                description = app.getString(R.string.notify_channel_receiving_description)
                setShowBadge(false)
            },
        ))
    }

    /** Whether a reply notification would reach the user at all. */
    override fun canPost(): Boolean = permissionGranted() && manager.areNotificationsEnabled() &&
        manager.getNotificationChannel(CHANNEL_REPLIES)?.importance != NotificationManager.IMPORTANCE_NONE

    override fun permissionGranted(): Boolean =
        app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /** Posts or replaces the conversation's reply notification. */
    override fun post(notice: ReplyNotice) {
        if (!permissionGranted()) return
        val link = ReplyLink.of(notice)
        val tag = replyTag(link.accountTag, notice.conversationId)
        // The core words it: who speaks and what they said.
        val title = notice.title
        val text = notice.body
        val open = PendingIntent.getActivity(app, tag.hashCode(), link.intent(app),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        // The lock screen shows that a reply came, not what it says.
        val public = Notification.Builder(app, CHANNEL_REPLIES)
            .setSmallIcon(R.drawable.ic_cue_mark)
            .setContentTitle(app.getString(R.string.app_name))
            .setContentText(app.getString(R.string.notify_reply_public))
            .build()
        val notification = Notification.Builder(app, CHANNEL_REPLIES)
            .setSmallIcon(R.drawable.ic_cue_mark)
            .setColor(app.getColor(R.color.token_bg_brand_solid))
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setShowWhen(true)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try {
            manager.notify(tag, REPLY_ID, notification)
        } catch (_: SecurityException) {
            // Permission revoked between the check and the post.
        }
    }

    override fun cancel(accountTag: String, conversationId: String) = manager.cancel(replyTag(accountTag, conversationId), REPLY_ID)

    /** Every reply notification, or only those of accounts other than [keepAccountTag]. */
    override fun cancelReplies(keepAccountTag: String?) {
        manager.activeNotifications.forEach {
            val account = replyTagAccount(it.tag) ?: return@forEach
            if (account != keepAccountTag) manager.cancel(it.tag, it.id)
        }
    }

    /** The quiet notification a background hold's service runs under. */
    fun receiving(): Notification = Notification.Builder(app, CHANNEL_RECEIVING)
        .setSmallIcon(R.drawable.ic_cue_mark)
        .setContentTitle(app.getString(R.string.notify_receiving_title))
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setShowWhen(false)
        .setCategory(Notification.CATEGORY_PROGRESS)
        .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_DEFERRED)
        .setContentIntent(PendingIntent.getActivity(app, 0,
            app.packageManager.getLaunchIntentForPackage(app.packageName), PendingIntent.FLAG_IMMUTABLE))
        .build()

    companion object {
        const val CHANNEL_REPLIES = "replies"
        const val CHANNEL_RECEIVING = "receiving"
        const val REPLY_ID = 1
        const val RECEIVING_ID = 2
    }
}
