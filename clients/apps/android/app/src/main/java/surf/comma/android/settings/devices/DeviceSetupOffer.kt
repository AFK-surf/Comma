package surf.comma.android.settings.devices

import org.json.JSONObject

/**
 * A projection of the server-owned offer. The highest [revision] wins; [revision] is null only on
 * cards from before the server sent one, and then the later Home message wins.
 */
data class DeviceSetupOffer(
    val offerId: String,
    val name: String,
    val model: String,
    val shortId: String,
    val reporterDeviceId: String,
    val status: String,
    val expiresAt: Long,
    val revision: Long? = null,
) {
    val bluetoothName: String get() = "Comma-$shortId"

    fun presentation(localDeviceId: String, now: Long): OfferPresentation = when {
        status == "done" -> OfferPresentation("Set up")
        status == "dismissed" -> OfferPresentation("Dismissed")
        status == "expired" || now >= expiresAt -> OfferPresentation("Expired")
        status !in setOf("open", "started") -> OfferPresentation("Unavailable")
        reporterDeviceId != localDeviceId -> OfferPresentation("Set up from the phone near it", dismiss = true)
        else -> OfferPresentation(if (status == "started") "Setup started" else "Ready to set up", connect = true, dismiss = true)
    }

    /** As the client core says an offer (`ChatDeviceSetupOffer`): what [parse] reads. */
    fun json(): JSONObject = JSONObject().put("offerId", offerId).put("name", name).put("model", model)
        .put("shortId", shortId).put("reporterDeviceId", reporterDeviceId).put("status", status)
        .put("expiresAt", expiresAt).apply { revision?.let { put("revision", it) } }

    /** Whether [candidate], seen after this, replaces it. Equal revisions keep this one. */
    fun replacedBy(candidate: DeviceSetupOffer): Boolean {
        val current = revision
        val next = candidate.revision
        return if (current == null || next == null) true else next > current
    }

    companion object {
        /** The chat card kind of an offer. */
        const val TYPE = "device_setup_offer"
        fun parse(raw: String?): DeviceSetupOffer? = raw?.let { runCatching { parse(JSONObject(it)) }.getOrNull() }
        /** An offer as the client core says it; null when it is not one. */
        fun parse(json: JSONObject): DeviceSetupOffer? {
            fun field(key: String) = (json.opt(key) as? String)?.takeIf { it.isNotBlank() }
            val shortId = field("shortId")?.uppercase()?.takeIf { it.matches(Regex("[0-9A-F]{4}")) } ?: return null
            return DeviceSetupOffer(field("offerId") ?: return null, field("name") ?: return null,
                field("model") ?: return null, shortId, field("reporterDeviceId") ?: return null,
                field("status") ?: return null, (json.opt("expiresAt") as? Number)?.toLong()?.takeIf { it > 0 } ?: return null,
                (json.opt("revision") as? Number)?.toLong()?.takeIf { it > 0 })
        }
    }
}

data class OfferPresentation(val label: String, val connect: Boolean = false, val dismiss: Boolean = false)
