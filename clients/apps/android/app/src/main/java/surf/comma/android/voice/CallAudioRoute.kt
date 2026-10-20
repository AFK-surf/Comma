package surf.comma.android.voice

import android.media.AudioDeviceInfo

enum class CallAudioOutput { Headphones, Bluetooth, Speaker, Phone }

/** Only communication-capable devices supplied by AudioManager are candidates. */
internal object CallAudioRoute {
    private val preference = listOf(
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
    )

    fun output(type: Int): CallAudioOutput? = when (type) {
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_HEARING_AID, AudioDeviceInfo.TYPE_BLE_SPEAKER -> CallAudioOutput.Bluetooth
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> CallAudioOutput.Headphones
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> CallAudioOutput.Speaker
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> CallAudioOutput.Phone
        else -> null
    }

    fun preferredType(types: List<Int>, manual: CallAudioOutput? = null): Int? =
        preference.firstOrNull { it in types && (manual == null || output(it) == manual) }

    fun available(types: List<Int>): List<CallAudioOutput> =
        CallAudioOutput.entries.filter { choice -> types.any { output(it) == choice } }
}
