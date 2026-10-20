package surf.comma.android.macrobenchmark

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.util.UUID

internal const val TARGET_PACKAGE = "surf.comma.android.dev"
private const val TIMEOUT_MS = 30_000L
private const val STREAM_TIMEOUT_MS = 180_000L

/** Return the actual target mode; never infer a baseline label from the test APK's revision. */
internal fun MacrobenchmarkScope.launchConversation(scene: String): String {
    startActivityAndWait(Intent(Intent.ACTION_MAIN).apply {
        setClassName(TARGET_PACKAGE, "surf.comma.android.MainActivity")
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        putExtra("scenario", scene)
        // blur (the default), fade or off: compares the frosted top band with its fallbacks.
        InstrumentationRegistry.getArguments().getString("comma.topBackdrop")?.let { putExtra("top_backdrop", it) }
    })
    val status = device.wait(Until.findObject(
        By.res(TARGET_PACKAGE, "conversation_status").descStartsWith("ready;stable_ids="),
    ), TIMEOUT_MS) ?: error("Conversation did not become interactive")
    val mode = when (status.contentDescription.substringAfter("stable_ids=")) {
        "true" -> "isolated"
        "false" -> "none"
        else -> error("Missing target stable-ID mode")
    }
    InstrumentationRegistry.getArguments().getString("comma.stableIdMode")?.let { expected ->
        check(mode == expected) { "Expected stable-ID mode $expected, but installed target uses $mode" }
    }
    device.waitForIdle()
    return mode
}

/** Fixed directions, velocity and gesture margin for comparisons between both target revisions. */
internal fun MacrobenchmarkScope.flingSequence() {
    val timeline = device.findObject(By.res(TARGET_PACKAGE, "conversation_timeline"))
        ?: error("Missing timeline")
    timeline.setGestureMargin(device.displayWidth / 8)
    listOf(Direction.UP, Direction.UP, Direction.UP, Direction.UP,
        Direction.DOWN, Direction.DOWN, Direction.UP, Direction.UP).forEach {
        timeline.fling(it, 9_000)
        device.waitForIdle()
    }
}

/** Partial is the primary result; None is a separately named reference, never pooled with it. */
@RunWith(Parameterized::class)
class ConversationBenchmarks(private val compilation: String) {
    @get:Rule val benchmark = MacrobenchmarkRule()
    private val runId = UUID.randomUUID().toString()
    private var viewportSample = 0
    private var stableIdMode = "unknown"
    private val failedViewportSamples = mutableListOf<String>()
    private val compilationMode: CompilationMode
        get() = when (compilation) {
            "partial" -> CompilationMode.Partial() // Default BaselineProfileMode.UseIfAvailable.
            "none" -> CompilationMode.None()
            else -> error("Unknown compilation mode: $compilation")
        }

    @Test fun coldStart() = benchmark.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = listOf(StartupTimingMetric(), FrameTimingMetric()),
        compilationMode = compilationMode,
        startupMode = StartupMode.COLD,
        iterations = 5,
        setupBlock = { pressHome(); stableIdMode = "unknown" },
        measureBlock = {
            measurementWindow("cold_start") { stableIdMode = launchConversation("cold_start") }
        },
    )

    @Test fun longConversationFling() = benchmark.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = listOf(FrameTimingMetric()),
        compilationMode = compilationMode,
        iterations = 5,
        setupBlock = { killProcess(); stableIdMode = launchConversation("long_fling") },
        measureBlock = { measurementWindow("long_fling") { flingSequence() } },
    )

    @Test fun streamingWhileReadingHistory() {
        benchmark.measureRepeated(
            packageName = TARGET_PACKAGE,
            metrics = listOf(FrameTimingMetric()),
            compilationMode = compilationMode,
            iterations = 5,
            setupBlock = {
                killProcess()
                stableIdMode = launchConversation("streaming_history")
                // Enter reading-history mode, keeping the growing reply near the visible viewport.
                val timeline = device.findObject(By.res(TARGET_PACKAGE, "conversation_timeline"))
                    ?: error("Missing timeline")
                timeline.setGestureMargin(device.displayWidth / 8)
                timeline.scroll(Direction.UP, 0.12f, 500)
                device.waitForIdle()
            },
            measureBlock = { measurementWindow("streaming_history") { replayAndRecordViewport("streaming_history", it) } },
        )
        check(failedViewportSamples.isEmpty()) {
            "Viewport failed in ${failedViewportSamples.size} iteration(s): $failedViewportSamples"
        }
    }

    @Test fun streamingWhileFollowingBottom() {
        benchmark.measureRepeated(
            packageName = TARGET_PACKAGE,
            metrics = listOf(FrameTimingMetric()),
            compilationMode = compilationMode,
            iterations = 5,
            setupBlock = { killProcess(); stableIdMode = launchConversation("streaming_bottom") },
            measureBlock = { measurementWindow("streaming_bottom") { replayAndRecordViewport("streaming_bottom", it) } },
        )
        check(failedViewportSamples.isEmpty()) {
            "Viewport failed in ${failedViewportSamples.size} iteration(s): $failedViewportSamples"
        }
    }

    /**
     * The waiting row on screen for a few seconds, then the reply's first text in its place.
     * The anchor samples record whether the rows above moved during the switch.
     */
    @Test fun waitingForReply() = benchmark.measureRepeated(
        packageName = TARGET_PACKAGE,
        metrics = listOf(FrameTimingMetric()),
        compilationMode = compilationMode,
        iterations = 5,
        setupBlock = { killProcess(); stableIdMode = launchConversation("waiting_reply") },
        measureBlock = {
            measurementWindow("waiting_reply") {
                device.findObject(By.res(TARGET_PACKAGE, "replay_reply")).click()
                val status = device.wait(
                    Until.findObject(By.res(TARGET_PACKAGE, "conversation_status").descStartsWith("complete;")),
                    STREAM_TIMEOUT_MS,
                ) ?: error("The reply did not finish")
                Log.i("COMMA_BENCHMARK", JSONObject(status.contentDescription.substringAfter("complete;"))
                    .put("run_id", runId).put("window_id", it).put("compilation_mode", compilation).toString())
            }
        },
    )

    /** Monotonic timestamps exclude setup/teardown from raw per-frame log analysis. */
    private fun MacrobenchmarkScope.measurementWindow(scene: String, action: MacrobenchmarkScope.(String) -> Unit) {
        val windowId = UUID.randomUUID().toString()
        fun mark(phase: String) {
            Log.i("COMMA_BENCHMARK", JSONObject().put("type", "window").put("run_id", runId)
                .put("window_id", windowId).put("scenario", scene).put("compilation_mode", compilation)
                .put("stable_id_mode", stableIdMode).put("phase", phase).put("time_ns", System.nanoTime()).toString())
        }
        mark("begin")
        try { action(windowId) } finally { mark("end") }
    }

    private fun MacrobenchmarkScope.replayAndRecordViewport(scene: String, windowId: String) {
        device.findObject(By.res(TARGET_PACKAGE, "replay_reply")).click()
        val status = device.wait(
            Until.findObject(By.res(TARGET_PACKAGE, "conversation_status").descStartsWith("complete;")),
            STREAM_TIMEOUT_MS,
        ) ?: error("Streaming did not finish")
        val result = JSONObject(status.contentDescription.substringAfter("complete;"))
            .put("run_id", runId).put("window_id", windowId)
            .put("compilation_mode", compilation).put("iteration", viewportSample++)
        val json = result.toString()
        // Persist even a failed sample, including transient offscreen anchors that reappeared.
        Log.i("COMMA_BENCHMARK", json)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.sendStatus(0, Bundle().apply { putString("comma.viewport", json) })
        val outputDirectory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
            ?.let(::File) ?: instrumentation.context.getExternalFilesDir(null)
            ?: error("No benchmark output directory")
        check(outputDirectory.exists() || outputDirectory.mkdirs())
        File(outputDirectory, "comma-viewport-$compilation-$stableIdMode-$runId.jsonl").appendText("$json\n")
        check(result.getString("scenario") == scene && result.getString("stable_id_mode") == stableIdMode)
        check(result.getInt("samples") > 1) { "Missing per-frame viewport samples: $json" }
        if (result.getBoolean("failed")) {
            // Preserve all five traces and FrameTimingMetric results, then fail the test.
            failedViewportSamples += json
            return
        }
        if (scene == "streaming_history") {
            check(result.getBoolean("started_reading_history")) { "Scenario c did not start in reading-history mode: $json" }
            check(!result.isNull("delta_px")) { "Missing final displacement: $json" }
        } else {
            check(result.getBoolean("started_pinned")) { "Scenario d did not start pinned to bottom: $json" }
        }
        // P1 records real drift (including always_pinned=false); no threshold assertion or correction.
    }

    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun compilationModes(): List<String> = listOf("partial", "none")
    }
}
