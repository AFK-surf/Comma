package surf.comma.android.performance

import android.view.Window
import surf.comma.android.chat.render.ChatTimelineView

object ConversationTelemetryFactory {
    fun create(window: Window, timeline: ChatTimelineView): ConversationTelemetry = NoTelemetry
}

private object NoTelemetry : ConversationTelemetry {
    override fun scenario(value: String) = Unit
    override fun beginReply() = Unit
    override fun endReply() = "complete"
    override fun close() = Unit
}
