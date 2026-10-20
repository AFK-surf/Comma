package surf.comma.android.performance

import kotlin.math.abs

/** Pure accumulation rules, shared by the per-pre-draw probe and host-side regression tests. */
internal class AnchorSamples(val messageId: Long?, val beforeTopPx: Int?) {
    var samples = 0
        private set
    var afterTopPx: Int? = beforeTopPx
        private set
    var maxAbsDeltaPx = 0
        private set
    var failed = messageId == null || beforeTopPx == null
        private set
    val deltaPx: Int? get() = afterTopPx?.let { top -> beforeTopPx?.let { top - it } }

    fun sample(topPx: Int?) {
        samples++
        afterTopPx = topPx
        if (topPx == null || beforeTopPx == null) {
            failed = true // Sticky: leaving and later re-entering the viewport is still a failure.
        } else {
            maxAbsDeltaPx = maxOf(maxAbsDeltaPx, abs(topPx - beforeTopPx))
        }
    }
}

internal class BottomSamples {
    var samples = 0
        private set
    var maxBottomDeviationPx = 0
        private set
    var startedPinned = false
        private set
    var beforeOffsetPx: Int? = null
        private set
    var afterOffsetPx: Int? = null
        private set
    var alwaysPinned = true
        private set
    var failed = false
        private set

    fun sample(offsetPx: Int?, following: Boolean) {
        if (samples == 0) {
            startedPinned = following && offsetPx == 0
            beforeOffsetPx = offsetPx
        }
        afterOffsetPx = offsetPx
        samples++
        if (offsetPx == null) {
            failed = true
            alwaysPinned = false
        } else {
            maxBottomDeviationPx = maxOf(maxBottomDeviationPx, abs(offsetPx))
            alwaysPinned = alwaysPinned && following && offsetPx == 0
        }
    }
}
