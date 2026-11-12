package surf.comma.android.settings.devices

import android.view.View
import surf.comma.android.R
import androidx.activity.ComponentActivity
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.TimelineEntry

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DeviceSetupOfferTest {
    private val offer = DeviceSetupOffer("dso_test", "Comma-5D28", "t-circle-s3", "5D28", "phone-one", "open", Long.MAX_VALUE)

    @Test fun `only the reporting phone can connect and resolved cards have no actions`() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val card = DeviceSetupOfferCard(activity.get()).apply { localReporter = { "phone-one" } }
            val actions = mutableListOf<String>()
            card.onAction = { value, action -> assertEquals(offer.offerId, value.offerId); actions += action }
            card.show(offer)
            assertEquals(View.VISIBLE, card.connect.visibility)
            card.connect.performClick()
            card.dismiss.performClick()
            assertEquals(listOf("started", "dismiss"), actions)
            card.localReporter = { "phone-two" }
            card.show(offer)
            assertEquals(View.GONE, card.connect.visibility)
            card.localReporter = { "phone-one" }
            card.show(offer.copy(status = "started"))
            assertEquals(View.VISIBLE, card.connect.visibility)
            for (state in listOf("done", "expired", "dismissed")) {
                card.show(offer.copy(status = state))
                assertEquals(View.GONE, card.connect.visibility)
                assertEquals(View.GONE, card.dismiss.visibility)
            }
            assertFalse(offer.copy(expiresAt = 100).presentation("phone-one", 100).connect)
        } finally { activity.pause().stop().destroy() }
    }

    @Test @Config(qualifiers = "zh-rCN")
    fun cardUsesChineseResources() = assertLocalizedCard()

    @Test @Config(qualifiers = "en")
    fun cardUsesEnglishResources() = assertLocalizedCard()

    private fun assertLocalizedCard() {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val activity = controller.get()
            val card = DeviceSetupOfferCard(activity).apply { localReporter = { "phone-one" } }
            fun texts(view: View): List<String> = when (view) {
                is android.widget.TextView -> listOf(view.text.toString())
                is android.view.ViewGroup -> (0 until view.childCount).flatMap { texts(view.getChildAt(it)) }
                else -> emptyList()
            }
            card.show(offer)
            assertEquals(activity.getString(R.string.devices_offer_connect), card.connect.text.toString())
            assertEquals(activity.getString(R.string.devices_nearby_permission_not_now), card.dismiss.text.toString())
            assertEquals(card.connect.text, card.connect.contentDescription)
            assertEquals(card.dismiss.text, card.dismiss.contentDescription)
            for ((state, resource) in listOf("open" to R.string.devices_offer_ready,
                "started" to R.string.devices_offer_started, "done" to R.string.devices_offer_done,
                "dismissed" to R.string.devices_offer_dismissed, "expired" to R.string.devices_offer_expired,
                "unknown" to R.string.devices_offer_unavailable)) {
                card.show(offer.copy(status = state))
                assertTrue("$state shows its localized status", activity.getString(resource) in texts(card))
            }
            card.localReporter = { "phone-two" }
            card.show(offer)
            assertTrue(activity.getString(R.string.devices_offer_nearby_phone) in texts(card))
        } finally { controller.pause().stop().destroy() }
    }

    @Test fun `a message's offer is a card row after its text`() {
        val message = display(JSONObject().put("message_id", "m1").put("seq", 1).put("actor_type", "agent").put("content", JSONArray()
            .put(JSONObject().put("type", "text").put("text", "I found a Comma device nearby."))
            .put(JSONObject().put("type", "device_setup_offer").put("offer_id", offer.offerId).put("name", offer.name)
                .put("model", offer.model).put("short_id", offer.shortId).put("reporter_device_id", offer.reporterDeviceId)
                .put("status", "done").put("expires_at", offer.expiresAt).put("revision", 2))))!!
        val rows = mapConversation(ConversationState(timeline = listOf(TimelineEntry.Message("m1", message)))).rows
        assertEquals(2, rows.size)
        assertEquals("I found a Comma device nearby.", rows.first().text)
        assertEquals(DeviceSetupOffer.TYPE, rows.last().cardKind)
        assertEquals(offer.copy(status = "done", revision = 2), DeviceSetupOffer.parse(rows.last().cardPayload))
    }

    @Test fun `revision survives serialization and an older Home state does not replace an action response`() {
        val started = offer.copy(status = "started", revision = 2)
        assertEquals(started, DeviceSetupOffer.parse(started.json()))
        assertEquals(offer, DeviceSetupOffer.parse(offer.json()))
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val card = DeviceSetupOfferCard(activity.get()).apply { localReporter = { "phone-one" } }
            card.show(offer.copy(status = "done", revision = 3))
            card.show(started)
            assertEquals(View.GONE, card.connect.visibility)
            card.show(started.copy(revision = 4))
            assertEquals(View.VISIBLE, card.connect.visibility)
            card.show(offer.copy(offerId = "dso_other", status = "done", revision = 9))
            card.show(offer.copy(offerId = "dso_other_2", revision = 1))
            assertEquals(View.VISIBLE, card.connect.visibility)
        } finally { activity.pause().stop().destroy() }
    }
}
