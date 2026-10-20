package surf.comma.android.settings.devices

import android.view.View
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
            assertEquals("Set up from the phone near it", offer.presentation("phone-two", 0).label)
            card.localReporter = { "phone-one" }
            card.show(offer.copy(status = "started"))
            assertEquals(View.VISIBLE, card.connect.visibility)
            for ((state, label) in listOf("done" to "Set up", "expired" to "Expired", "dismissed" to "Dismissed")) {
                card.show(offer.copy(status = state))
                assertEquals(View.GONE, card.connect.visibility)
                assertEquals(View.GONE, card.dismiss.visibility)
                assertEquals(label, offer.copy(status = state).presentation("phone-one", 0).label)
            }
            assertFalse(offer.copy(expiresAt = 100).presentation("phone-one", 100).connect)
            assertEquals("Dismissed", offer.copy(status = "dismissed", expiresAt = 100).presentation("phone-one", 200).label)
        } finally { activity.pause().stop().destroy() }
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
