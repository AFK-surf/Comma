package surf.comma.android.performance

import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.FrameMetrics
import android.view.Window
import android.view.ViewTreeObserver
import org.json.JSONObject
import surf.comma.android.chat.render.ChatTimelineView
import androidx.metrics.performance.JankStats
import androidx.metrics.performance.PerformanceMetricsState

/** Per-frame timings on the metrics thread; never log conversation text or credentials. */
class FrameTelemetry(
    private val window: Window,
    private val timeline: ChatTimelineView,
) : ConversationTelemetry {
    private val thread = HandlerThread("comma-frame-metrics").apply { start() }
    @Volatile private var scenario = "cold_start"
    private val state = PerformanceMetricsState.getHolderForHierarchy(window.decorView)
    private val jankStats = JankStats.createAndTrack(window) { frame ->
        // FrameData is reused by JankStats, so consume its values inside this callback.
        val scene = frame.states.firstOrNull { it.key == "scenario" }?.value ?: scenario
        Log.i(TAG, "{\"type\":\"jank\",\"scenario\":\"$scene\",\"start_ns\":${frame.frameStartNanos}," +
            "\"ui_ns\":${frame.frameDurationUiNanos},\"jank\":${frame.isJank}}")
    }
    private val listener = Window.OnFrameMetricsAvailableListener { _, frame, dropped ->
        Log.i(TAG, "{\"type\":\"frame\",\"scenario\":\"$scenario\"," +
            "\"start_ns\":${frame.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP)}," +
            "\"total_ns\":${frame.getMetric(FrameMetrics.TOTAL_DURATION)}," +
            "\"layout_ns\":${frame.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION)}," +
            "\"draw_ns\":${frame.getMetric(FrameMetrics.DRAW_DURATION)}," +
            "\"deadline_ns\":${frame.getMetric(FrameMetrics.DEADLINE)},\"dropped_callbacks\":$dropped}")
    }

    init {
        state.state?.putState("scenario", scenario)
        window.addOnFrameMetricsAvailableListener(listener, Handler(thread.looper))
    }

    override fun scenario(value: String) {
        scenario = value
        state.state?.putState("scenario", value)
        Log.i(TAG, "{\"type\":\"scene\",\"scenario\":\"$value\"}")
    }

    private var anchorSamples: AnchorSamples? = null
    private var bottomSamples: BottomSamples? = null
    private var startedReadingHistory = false
    private val preDrawListener = ViewTreeObserver.OnPreDrawListener {
        sampleViewport()
        true
    }

    override fun beginReply() {
        stopViewportProbe()
        startedReadingHistory = !timeline.isPinnedToEnd()
        if (scenario == "streaming_bottom") {
            bottomSamples = BottomSamples()
            anchorSamples = null
        } else {
            val anchor = timeline.visibleAnchor()
            anchorSamples = AnchorSamples(anchor?.messageId, anchor?.topPx)
            bottomSamples = null
        }
        timeline.viewTreeObserver.addOnPreDrawListener(preDrawListener)
        sampleViewport()
    }

    /** Every pre-draw, plus explicit start/end samples; duplicates cannot hide transient drift. */
    private fun sampleViewport() {
        val sampledAt = System.nanoTime()
        anchorSamples?.let { samples ->
            val top = samples.messageId?.let(timeline::messageTopOnScreen)
            samples.sample(top)
            Log.i(TAG, "{\"type\":\"anchor_frame\",\"scenario\":\"$scenario\",\"sample_ns\":$sampledAt," +
                "\"message_id\":${samples.messageId},\"top_px\":$top,\"delta_px\":${samples.deltaPx}," +
                "\"max_abs_delta_px\":${samples.maxAbsDeltaPx},\"failed\":${samples.failed}}")
        }
        bottomSamples?.let { samples ->
            val offset = timeline.bottomOffsetPx()
            val following = timeline.isPinnedToEnd()
            samples.sample(offset, following)
            Log.i(TAG, "{\"type\":\"bottom_frame\",\"scenario\":\"$scenario\",\"sample_ns\":$sampledAt," +
                "\"bottom_offset_px\":$offset,\"following\":$following," +
                "\"max_bottom_deviation_px\":${samples.maxBottomDeviationPx}," +
                "\"always_pinned\":${samples.alwaysPinned},\"failed\":${samples.failed}}")
        }
    }

    override fun endReply(): String {
        sampleViewport()
        stopViewportProbe()
        val result = JSONObject().put("scenario", scenario)
            .put("stable_id_mode", if (timeline.adapter?.hasStableIds() == true) "isolated" else "none")
        anchorSamples?.let { samples ->
            result.put("type", "anchor").put("message_id", samples.messageId ?: JSONObject.NULL)
                .put("started_reading_history", startedReadingHistory)
                .put("before_top_px", samples.beforeTopPx ?: JSONObject.NULL)
                .put("after_top_px", samples.afterTopPx ?: JSONObject.NULL)
                .put("delta_px", samples.deltaPx ?: JSONObject.NULL)
                .put("max_abs_delta_px", samples.maxAbsDeltaPx)
                .put("samples", samples.samples).put("failed", samples.failed)
        }
        bottomSamples?.let { samples ->
            result.put("type", "bottom").put("samples", samples.samples).put("failed", samples.failed)
                .put("before_bottom_offset_px", samples.beforeOffsetPx ?: JSONObject.NULL)
                .put("after_bottom_offset_px", samples.afterOffsetPx ?: JSONObject.NULL)
                .put("started_pinned", samples.startedPinned).put("always_pinned", samples.alwaysPinned)
                .put("max_bottom_deviation_px", samples.maxBottomDeviationPx)
        }
        Log.i(TAG, result.toString())
        anchorSamples = null
        bottomSamples = null
        return "complete;$result"
    }

    private fun stopViewportProbe() {
        if (timeline.viewTreeObserver.isAlive) {
            timeline.viewTreeObserver.removeOnPreDrawListener(preDrawListener)
        }
    }

    override fun close() {
        stopViewportProbe()
        jankStats.isTrackingEnabled = false
        window.removeOnFrameMetricsAvailableListener(listener)
        thread.quitSafely()
    }

    companion object { const val TAG = "COMMA_PERF" }
}
