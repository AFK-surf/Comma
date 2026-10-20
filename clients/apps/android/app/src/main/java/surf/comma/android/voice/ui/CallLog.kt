package surf.comma.android.voice.ui

import android.content.Context
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.live.rowId
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.voice.CallControllerState

/** One finished call in a conversation: when it ended (wall clock, ms) and how long it lasted. */
data class CallRecord(val callId: Long, val endedAtMillis: Long, val seconds: Long)

/**
 * The calls each conversation has had, kept on this device only: the backend has no event for a
 * call yet, so the record is not part of the conversation and other devices do not see it.
 */
class CallLogStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("voice_call_log", Context.MODE_PRIVATE)

    fun records(conversationId: String): List<CallRecord> {
        val raw = prefs.getString(conversationId, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                CallRecord(item.getLong("id"), item.getLong("ended_at"), item.getLong("seconds"))
            }
        }.getOrDefault(emptyList())
    }

    /** Adds [record] once; a call already recorded (the same id) is left as it is. */
    fun add(conversationId: String, record: CallRecord): Boolean {
        val existing = records(conversationId)
        if (existing.any { it.callId == record.callId }) return false
        val kept = (existing + record).sortedBy { it.endedAtMillis }.takeLast(MAX_PER_CONVERSATION)
        val array = JSONArray()
        kept.forEach { array.put(JSONObject().put("id", it.callId).put("ended_at", it.endedAtMillis).put("seconds", it.seconds)) }
        prefs.edit { putString(conversationId, array.toString()) }
        return true
    }

    private companion object { const val MAX_PER_CONVERSATION = 200 }
}

internal object CallLog {
    /**
     * The record for a call that has just finished, or null if there is nothing to log: it never
     * connected, or it is still going. [nowElapsed] and [nowMillis] place the end on the wall clock.
     */
    fun recordFor(state: CallControllerState, nowElapsed: Long, nowMillis: Long): CallRecord? {
        if (!CallPresentation.isTerminal(state) || state.id == 0L) return null
        val connected = state.connectedAtElapsedRealtime ?: return null
        val ended = state.endedAtElapsedRealtime ?: return null
        return CallRecord(state.id, nowMillis - (nowElapsed - ended), ((ended - connected) / 1000).coerceAtLeast(0))
    }

    /**
     * [rows] with each record placed by time: before the first message the user sent after the
     * call ended, otherwise at the end (ahead of a typing bubble, which belongs last).
     */
    fun withRecords(
        rows: List<ChatMessage>,
        records: List<CallRecord>,
        conversationId: String,
        label: (CallRecord) -> String,
    ): List<ChatMessage> {
        if (records.isEmpty()) return rows
        val out = ArrayList<ChatMessage>(rows.size + records.size)
        val pending = records.sortedBy { it.endedAtMillis }.toMutableList()
        fun row(record: CallRecord) = ChatMessage(id = rowId("call:${record.callId}"), conversationId = conversationId,
            turnId = "call:${record.callId}", role = ChatRole.USER, text = label(record), createdAt = record.endedAtMillis,
            cardKind = LiveRowKinds.CALL_LOG)
        for (message in rows) {
            val opensTurn = message.role == ChatRole.USER && message.cardKind == null
            while (opensTurn && pending.isNotEmpty() && message.createdAt > pending.first().endedAtMillis) {
                out += row(pending.removeAt(0))
            }
            out += message
        }
        val tail = out.size - out.takeLastWhile { it.cardKind == TimelineBlockKinds.LIVE_STATUS }.size
        out.addAll(tail, pending.map(::row))
        return out
    }
}
