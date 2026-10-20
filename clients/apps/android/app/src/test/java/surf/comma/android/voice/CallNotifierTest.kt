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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CallNotifierTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Test fun ongoingCallHasBrandPersonImmediateNotificationAndDirectHangup() {
        val notifier = CallNotifier(context)
        notifier.createChannel()
        val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CallNotifier.CHANNEL)
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, channel.importance)
        val notification = notifier.build(CallControllerState(id = 17, busy = true,
            call = CallState(phase = CallPhase.Calling)))
        assertEquals("Calling…", notification.extras.getCharSequence(Notification.EXTRA_TEXT))
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
        val failed = notifier.build(CallControllerState(id = 2,
            call = CallState(phase = CallPhase.Failed, result = CallResult.Interrupted)))
        assertEquals("Call interrupted", failed.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertEquals(0, failed.flags and Notification.FLAG_ONGOING_EVENT)
        assertTrue(failed.actions.isNullOrEmpty())
        assertEquals(4_000, failed.timeoutAfter)
        val ended = notifier.build(CallControllerState(id = 2,
            call = CallState(phase = CallPhase.Ended, result = CallResult.Ended)))
        assertEquals(1_500, ended.timeoutAfter)
    }
}
