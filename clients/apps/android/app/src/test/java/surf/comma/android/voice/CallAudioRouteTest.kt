package surf.comma.android.voice

import android.media.AudioDeviceInfo.*
import org.junit.Assert.*
import org.junit.Test

class CallAudioRouteTest {
    @Test fun automaticSelectionPrefersPersonalOutputsAndOtherwiseSpeaker() {
        assertEquals(TYPE_BUILTIN_SPEAKER, CallAudioRoute.preferredType(listOf(TYPE_BUILTIN_EARPIECE, TYPE_BUILTIN_SPEAKER)))
        for (personal in listOf(TYPE_BLE_HEADSET, TYPE_BLUETOOTH_SCO, TYPE_HEARING_AID,
            TYPE_USB_HEADSET, TYPE_USB_DEVICE, TYPE_WIRED_HEADSET, TYPE_WIRED_HEADPHONES, TYPE_BLE_SPEAKER)) {
            assertEquals(personal, CallAudioRoute.preferredType(listOf(TYPE_BUILTIN_SPEAKER, personal, TYPE_BUILTIN_EARPIECE)))
        }
        assertEquals(TYPE_BLE_HEADSET, CallAudioRoute.preferredType(listOf(TYPE_WIRED_HEADSET, TYPE_BLE_HEADSET)))
        assertEquals(TYPE_BUILTIN_EARPIECE, CallAudioRoute.preferredType(listOf(TYPE_BUILTIN_EARPIECE)))
        assertNull(CallAudioRoute.preferredType(listOf(TYPE_HDMI, TYPE_BUILTIN_MIC)))
    }

    @Test fun manualChoiceIncludesEarpieceAndNeverSubstitutesADifferentCategory() {
        val types = listOf(TYPE_BLUETOOTH_SCO, TYPE_USB_HEADSET, TYPE_BUILTIN_SPEAKER, TYPE_BUILTIN_EARPIECE)
        assertEquals(TYPE_BUILTIN_EARPIECE, CallAudioRoute.preferredType(types, CallAudioOutput.Phone))
        assertEquals(TYPE_BUILTIN_SPEAKER, CallAudioRoute.preferredType(types, CallAudioOutput.Speaker))
        assertEquals(TYPE_USB_HEADSET, CallAudioRoute.preferredType(types, CallAudioOutput.Headphones))
        assertEquals(TYPE_BLUETOOTH_SCO, CallAudioRoute.preferredType(types, CallAudioOutput.Bluetooth))
        assertNull(CallAudioRoute.preferredType(listOf(TYPE_BUILTIN_SPEAKER), CallAudioOutput.Bluetooth))
    }

    @Test fun pickerGroupsMultipleDevicesAndFiltersUnavailableOutputs() {
        assertEquals(listOf(CallAudioOutput.Headphones, CallAudioOutput.Bluetooth, CallAudioOutput.Speaker, CallAudioOutput.Phone),
            CallAudioRoute.available(listOf(TYPE_USB_HEADSET, TYPE_WIRED_HEADPHONES, TYPE_BLE_HEADSET,
                TYPE_BLUETOOTH_SCO, TYPE_BUILTIN_SPEAKER, TYPE_BUILTIN_EARPIECE, TYPE_HDMI)))
        assertEquals(listOf(CallAudioOutput.Speaker), CallAudioRoute.available(listOf(TYPE_BUILTIN_SPEAKER)))
        assertTrue(CallAudioRoute.available(emptyList()).isEmpty())
    }
}
