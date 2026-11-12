package surf.comma.android.voice

import android.app.Notification
import android.app.NotificationManager
import android.app.Person
import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import surf.comma.android.MainActivity
import surf.comma.android.R

@RunWith(RobolectricTestRunner::class)
// The default resources are Chinese: a hardcoded English string cannot match them.
@Config(sdk = [35], qualifiers = "zh-rCN")
class CallNotifierTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Test fun ongoingCallHasBrandPersonImmediateNotificationAndDirectHangup() {
        val notifier = CallNotifier(context)
        notifier.createChannel()
        val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CallNotifier.CHANNEL)
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, channel.importance)
        assertEquals(context.getString(R.string.call_channel), channel.name)
        val notification = notifier.build(CallControllerState(id = 17, busy = true,
            call = CallState(phase = CallPhase.Calling)))
        assertEquals(context.getString(R.string.call_calling), notification.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        val person = notification.extras.getParcelable(Notification.EXTRA_CALL_PERSON, Person::class.java)!!
        assertEquals("Comma", person.name)
        assertNotNull(person.icon)
        val end = notification.actions.single().actionIntent
        val command = shadowOf(end).savedIntent
        assertEquals(CallService::class.java.name, command.component!!.className)
        assertEquals(CallService.ACTION_HANG_UP, command.action)
        assertEquals(17L, command.getLongExtra(CallService.EXTRA_ID, 0))
        val open = shadowOf(notification.contentIntent).savedIntent
        assertEquals(MainActivity::class.java.name, open.component!!.className)
        assertTrue(open.getBooleanExtra(CallController.EXTRA_EXPAND_CALL, false))
    }

    @Test fun newerCallsHaveDifferentHangupIntentsAndTerminalNoticesHaveNoHangup() {
        val notifier = CallNotifier(context)
        fun active(id: Long) = notifier.build(CallControllerState(id = id, busy = true,
            call = CallState(phase = CallPhase.Connected)))
        assertNotEquals(active(1).actions.single().actionIntent, active(2).actions.single().actionIntent)
        assertEquals(context.getString(R.string.call_active), active(1).extras.getCharSequence(Notification.EXTRA_TEXT))
        val failed = notifier.build(CallControllerState(id = 2,
            call = CallState(phase = CallPhase.Failed, result = CallResult.Interrupted)))
        assertEquals(context.getString(R.string.call_interrupted), failed.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertEquals(0, failed.flags and Notification.FLAG_ONGOING_EVENT)
        assertTrue(failed.actions.isNullOrEmpty())
        assertEquals(4_000, failed.timeoutAfter)
        val ended = notifier.build(CallControllerState(id = 2,
            call = CallState(phase = CallPhase.Ended, result = CallResult.Ended)))
        assertEquals(1_500, ended.timeoutAfter)
    }

    @Test fun serviceNoticesUseTheAppsWordsWhereItHasThem() {
        val notifier = CallNotifier(context)
        val revoked = notifier.build(CallControllerState(id = 3,
            call = CallState(phase = CallPhase.Failed, result = CallResult.Interrupted), notice = MICROPHONE_ACCESS_MESSAGE))
        assertEquals(context.getString(R.string.call_microphone_settings), revoked.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertEquals("Something new.", notifier.notice("Something new."))
    }
}
