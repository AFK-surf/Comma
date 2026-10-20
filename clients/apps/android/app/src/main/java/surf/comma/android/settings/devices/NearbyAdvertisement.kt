package surf.comma.android.settings.devices

/**
 * Android strips the two-byte company id before returning manufacturer-specific data.
 * Every Comma board sends the same advertisement, so [model] is the setup family, not the board;
 * `info` names the board after pairing, and the UI shows only [name] before then.
 */
internal data class NearbyAdvertisement(val model: String, val state: String, val shortId: String) {
    val name: String get() = "Comma-$shortId"

    companion object {
        const val COMPANY_ID = 0xFFFF

        /** The family value the backend accepts for a scanned device (`device_setup_offers` `@models`). */
        const val SETUP_FAMILY_MODEL = "t-circle-s3"

        fun parse(companyId: Int, payload: ByteArray?): NearbyAdvertisement? {
            if (companyId != COMPANY_ID || payload == null || payload.size < 5) return null
            if (payload[0].toInt() != 1 || payload[1].toInt() != 1) return null
            val state = when (payload[2].toInt()) {
                0 -> "unprovisioned"
                1 -> "pairing"
                else -> return null
            }
            val shortId = "%02X%02X".format(payload[3].toInt() and 255, payload[4].toInt() and 255)
            return NearbyAdvertisement(SETUP_FAMILY_MODEL, state, shortId)
        }
    }
}
