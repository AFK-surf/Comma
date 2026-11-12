package surf.comma.android.voice

import org.junit.Assert.assertEquals
import org.junit.Test

class CallMicrophoneTest {
    @Test fun aCallStartsOnlyWithTheMicrophone() {
        // Granted, also when only notifications were denied.
        assertEquals(CallMicrophone.START_CALL, callMicrophone(granted = true, showsRationale = false))
        // Denied: no call, and the system shows its dialog again on the next tap.
        assertEquals(CallMicrophone.NONE, callMicrophone(granted = false, showsRationale = true))
        // Denied for good: the system answers without its dialog, and only the app's settings can grant it.
        assertEquals(CallMicrophone.OPEN_SETTINGS, callMicrophone(granted = false, showsRationale = false))
    }
}
