package surf.comma.android.performance

import android.view.Window
import surf.comma.android.chat.render.ChatTimelineView

object ConversationTelemetryFactory {
    fun create(window: Window, timeline: ChatTimelineView): ConversationTelemetry = FrameTelemetry(window, timeline)
}
