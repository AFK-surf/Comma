package surf.comma.android.ui

import android.content.Context
import surf.comma.android.R
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * 会话列表右下角的时间戳。
 *
 * 「今天 / 昨天 + 时刻」比一串完整日期好读，而超过一天的会话时刻已经不重要了——
 * 那时候用户找的是「哪天聊的」。
 */
internal object ConversationTimeFormatter {

    /** 时间标签的形态。渲染成什么文案由资源决定，这里只判定落在哪一档。 */
    internal enum class Bucket { TODAY, YESTERDAY, THIS_YEAR, OLDER }

    private val timeOfDay = DateTimeFormatter.ofPattern("HH:mm")
    private val dayInYear = DateTimeFormatter.ofPattern("M/d")
    private val fullDay = DateTimeFormatter.ofPattern("yyyy/M/d")

    fun format(
        context: Context,
        timestamp: Long,
        now: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val bucket = bucket(timestamp, now, zone)
        val moment = Instant.ofEpochMilli(timestamp).atZone(zone)
        return when (bucket) {
            Bucket.TODAY -> context.getString(R.string.time_today, timeOfDay.format(moment))
            Bucket.YESTERDAY -> context.getString(R.string.time_yesterday, timeOfDay.format(moment))
            Bucket.THIS_YEAR -> dayInYear.format(moment)
            Bucket.OLDER -> fullDay.format(moment)
        }
    }

    internal fun bucket(timestamp: Long, now: Long, zone: ZoneId): Bucket {
        val day = Instant.ofEpochMilli(timestamp).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return when {
            day == today -> Bucket.TODAY
            day == today.minusDays(1) -> Bucket.YESTERDAY
            day.year == today.year -> Bucket.THIS_YEAR
            else -> Bucket.OLDER
        }
    }
}
