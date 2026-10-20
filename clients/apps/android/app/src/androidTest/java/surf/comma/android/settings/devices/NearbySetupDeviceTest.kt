package surf.comma.android.settings.devices

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.CueMessage
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.latestSetupOffers
import surf.comma.android.conversation.withSetupOffers
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File

/** Real timeline and taps on a phone, with an invented Home message and a scripted BLE result. */
class NearbySetupDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(300); instrumentation.waitForIdleSync() }
    private val offer = DeviceSetupOffer("dso_fixture", "Comma-5D28", "t-circle-s3", "5D28", "fixture-phone", "open",
        System.currentTimeMillis() + 30 * 60 * 1000)
    private fun message(seq: Long, actor: String, content: JSONArray) = JSONObject().put("message_id", "fixture-$seq")
        .put("seq", seq).put("actor_type", actor).put("content", content)

    @Test fun offerCardConnectAndLatestHomeState() {
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var timeline: ChatTimelineView
            scenario.onActivity { activity ->
                timeline = ChatTimelineView(activity)
                activity.setContentView(timeline)
            }
            settle()
            val original = CueMessage.parse(message(1, "agent", JSONArray()
                .put(JSONObject().put("type", "text").put("text", "I found a Comma device nearby (Comma-5D28). Want to set it up?"))
                .put(offer.json())))!!
            fun show(updates: List<CueMessage> = emptyList()) {
                val display = original.display!!.withSetupOffers(latestSetupOffers(updates))
                val rows = mapConversation(ConversationState(conversationId = "fixture-home",
                    timeline = listOf(TimelineEntry.Message("fixture-1", display)))).rows
                var width = 0
                main { width = timeline.width }
                val prepared = runBlocking { MessageLayoutPrecomputer().prepare(rows, width,
                    instrumentation.targetContext.resources.displayMetrics.density, 1f, false) }
                main { timeline.submitPrepared(prepared) }
                settle()
            }
            fun findCard(): DeviceSetupOfferCard {
                fun find(view: View): DeviceSetupOfferCard? {
                    if (view is DeviceSetupOfferCard) return view
                    if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index))?.let { return it }
                    return null
                }
                return requireNotNull(find(timeline))
            }
            show()
            val flow = AddDeviceFlow(offer.bluetoothName)
            main {
                val card = findCard()
                card.localReporter = { "fixture-phone" }
                card.show(offer)
                card.onAction = { selected, action ->
                    assertEquals("started", action)
                    assertEquals("Comma-5D28", selected.bluetoothName)
                    flow.start()
                    flow.handle(AddDeviceEvent.Found(FoundDevice("new-random-address", "Comma-5D28", -58)))
                }
                assertEquals(View.VISIBLE, card.connect.visibility)
                assertTrue(card.connect.performClick())
                assertTrue(flow.step is AddDeviceStep.Pairing)
            }
            screenshot("nearby-offer-open.png")
            fun update(seq: Long, status: String) = CueMessage.parse(message(seq, "system", JSONArray())
                .put("kind", "app_event").put("metadata", JSONObject().put("event_type", DeviceSetupOffer.UPDATED)
                    .put("offer", offer.copy(status = status).json())))!!
            val done = update(9, "done")
            show(listOf(done, update(5, "started")))
            main {
                assertEquals(View.GONE, findCard().connect.visibility)
                assertEquals(View.GONE, findCard().dismiss.visibility)
            }
            screenshot("nearby-offer-done.png")
        }
    }

    private fun screenshot(name: String) {
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return
        File(instrumentation.targetContext.getExternalFilesDir(null), name).outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }
}
