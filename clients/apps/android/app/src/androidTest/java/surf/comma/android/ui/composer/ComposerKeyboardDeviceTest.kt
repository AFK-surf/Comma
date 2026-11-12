package surf.comma.android.ui.composer

import android.graphics.Rect
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.EditText
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.util.concurrent.CountDownLatch

/** Exercises the first tap and real IME on the shared composer, without a server. */
class ComposerKeyboardDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    @Test fun firstTapOpensKeyboardAndDismissedDraftCanBeOpenedAgain() {
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var composer: ComposerView
            lateinit var input: EditText
            lateinit var events: ComposerEvents
            scenario.onActivity {
                composer = it.findViewById(R.id.comma_composer)
                input = descendants(composer).filterIsInstance<EditText>().single()
                events = ComposerEvents(composer)
            }
            events.use {
                events.await { composer.hasWindowFocus() && !input.hasFocus() && !imeVisible(composer) }
                tap(input)
                events.await { input.hasFocus() && imeVisible(composer) }
                main { input.setText("Keep this draft") }
                instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                events.await { !input.hasFocus() && !imeVisible(composer) }
                tap(input)
                events.await { input.hasFocus() && imeVisible(composer) }
                main { assertEquals("Keep this draft", input.text.toString()) }
            }
        }
    }

    @Test fun expandedComposerKeepsSixteenDpAboveKeyboard() {
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var composer: ComposerView
            lateinit var events: ComposerEvents
            scenario.onActivity {
                composer = it.findViewById(R.id.comma_composer)
                events = ComposerEvents(composer)
            }
            events.use {
                events.await { composer.hasWindowFocus() }
                main { composer.focusInput() }
                events.await { imeVisible(composer) }
                main {
                    val ime = ViewCompat.getRootWindowInsets(composer)!!.getInsets(WindowInsetsCompat.Type.ime()).bottom
                    val pill = composer.getChildAt(0)
                    val position = IntArray(2).also(pill::getLocationInWindow)
                    val gap = composer.rootView.height - ime - position[1] - pill.height
                    assertEquals("composer leaves 16 dp above the keyboard",
                        composer.resources.getDimensionPixelSize(R.dimen.spacing_xl), gap)
                }
            }
        }
    }

    private fun imeVisible(view: View) =
        ViewCompat.getRootWindowInsets(view)?.isVisible(WindowInsetsCompat.Type.ime()) == true

    private fun tap(view: View) {
        instrumentation.waitForIdleSync()
        instrumentation.setInTouchMode(true)
        main {
            val bounds = Rect()
            assertTrue(view.getGlobalVisibleRect(bounds))
            val root = view.rootView
            val origin = IntArray(2).also(root::getLocationOnScreen)
            // Dispatch through the window's view tree. System injection rejects old fixed timestamps.
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(1L, if (action == MotionEvent.ACTION_DOWN) 1L else 2L,
                    action, bounds.exactCenterX() - origin[0], bounds.exactCenterY() - origin[1], 0)
                try {
                    assertTrue(root.dispatchTouchEvent(event))
                } finally {
                    event.recycle()
                }
            }
        }
    }

    /** A sibling observes insets without replacing the composer's production listeners. */
    private inner class ComposerEvents(private val composer: ComposerView) : AutoCloseable {
        private val parent = composer.parent as ViewGroup
        private val probe = View(composer.context)
        private val tree = composer.viewTreeObserver
        private var imeAnimating = false
        private var pending: (() -> Unit)? = null
        private val focus = ViewTreeObserver.OnGlobalFocusChangeListener { _, _ -> changed() }
        private val windowFocus = ViewTreeObserver.OnWindowFocusChangeListener { changed() }
        private val layout = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> changed() }

        init {
            tree.addOnGlobalFocusChangeListener(focus)
            tree.addOnWindowFocusChangeListener(windowFocus)
            composer.addOnLayoutChangeListener(layout)
            ViewCompat.setOnApplyWindowInsetsListener(probe) { _, insets -> changed(); insets }
            ViewCompat.setWindowInsetsAnimationCallback(probe,
                object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_STOP) {
                    override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                        if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) imeAnimating = true
                    }

                    override fun onProgress(insets: WindowInsetsCompat, runningAnimations: List<WindowInsetsAnimationCompat>) = insets

                    override fun onEnd(animation: WindowInsetsAnimationCompat) {
                        if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) {
                            imeAnimating = false
                            changed()
                        }
                    }
                })
            parent.addView(probe, ViewGroup.LayoutParams(0, 0))
            ViewCompat.requestApplyInsets(probe)
        }

        private fun changed() {
            if (!imeAnimating) pending?.invoke()
        }

        fun await(condition: () -> Boolean) {
            val ready = CountDownLatch(1)
            main {
                pending = { if (condition()) ready.countDown() }
                changed()
            }
            try {
                ready.await()
            } finally {
                main { pending = null }
            }
        }

        override fun close() = main {
            tree.removeOnGlobalFocusChangeListener(focus)
            tree.removeOnWindowFocusChangeListener(windowFocus)
            composer.removeOnLayoutChangeListener(layout)
            parent.removeView(probe)
        }
    }

    private fun descendants(view: View): Sequence<View> = sequence {
        yield(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) yieldAll(descendants(view.getChildAt(index)))
    }
}
