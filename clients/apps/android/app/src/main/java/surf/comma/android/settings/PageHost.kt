package surf.comma.android.settings

import android.animation.ValueAnimator
import android.content.Context
import android.os.SystemClock
import android.view.View
import android.widget.FrameLayout
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedCallback
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/** One screen of the settings stack. [key] restores the stack after the activity is recreated. */
internal interface SettingsPage {
    val key: String
    val view: View
    /** The page left the stack; stop its work. */
    fun onRemoved() {}
    /** A page was pushed over this one ([top] false), or the one over it was popped ([top] true). */
    fun onTopChanged(top: Boolean) {}
}

/**
 * The stack of settings pages. A pushed page slides in from the right on the spatial spring and the
 * page below shifts a little the other way; the dimming between them fades with the dialog timings.
 * The system back gesture drags the top page with the finger and, when committed, hands the
 * finger's speed to the spring that takes it off screen. Popping the last page calls [onEmpty].
 */
internal class PageHost(context: Context, private val onEmpty: () -> Unit) : FrameLayout(context) {
    private class Entry(val page: SettingsPage, val spring: DesignSpring<View>) {
        var onSettled: (() -> Unit)? = null
    }

    private val entries = mutableListOf<Entry>()
    private val renderers = mutableListOf<Pair<SettingsPage, () -> Unit>>()
    private val scrim = View(context).apply {
        setBackgroundColor(context.color(R.color.token_bg_overlay))
        alpha = 0f
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private var scrimAnimator: ValueAnimator? = null
    private var gestureStartedAt = 0L
    private var lastProgress = 0f
    private var lastProgressAt = 0L
    private var velocity = 0f
    private var closing = false

    /**
     * The first page stays: a tab's root, which back never pops. Back then belongs to the stack only while a page
     * is pushed over the root.
     */
    var keepsRoot = false
        set(value) {
            field = value
            updateBack()
        }

    /**
     * Whether the stack is on screen. A tab hidden behind another keeps its pages but must not take back from the
     * tab that is shown.
     */
    var active = true
        set(value) {
            field = value
            updateBack()
        }

    val keys: List<String> get() = entries.map { it.page.key }
    val top: SettingsPage? get() = entries.lastOrNull()?.page
    fun pages(): List<SettingsPage> = entries.map { it.page }

    fun onRender(page: SettingsPage, render: () -> Unit) {
        renderers += page to render
        render()
    }

    fun render() {
        // A page registers during construction and must receive updates before push.
        renderers.toList().forEach { it.second() }
    }

    init {
        addView(scrim, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    /** Keeps the back gesture with the settings stack for as long as it has pages. */
    val backCallback = object : OnBackPressedCallback(true) {
        override fun handleOnBackStarted(backEvent: BackEventCompat) {
            val entry = entries.lastOrNull() ?: return
            entry.spring.cancel()
            below(entry)?.spring?.cancel()
            scrimAnimator?.cancel()
            gestureStartedAt = SystemClock.uptimeMillis()
            lastProgress = 0f
            lastProgressAt = gestureStartedAt
            velocity = 0f
        }

        override fun handleOnBackProgressed(backEvent: BackEventCompat) {
            val entry = entries.lastOrNull() ?: return
            val now = SystemClock.uptimeMillis()
            val progress = backEvent.progress
            if (now > lastProgressAt) velocity = (progress - lastProgress) * width * 1000f / (now - lastProgressAt)
            lastProgress = progress
            lastProgressAt = now
            // Driven by the finger, not animated.
            entry.page.view.translationX = progress * width
            below(entry)?.page?.view?.translationX = -PARALLAX * width * (1 - progress)
            scrim.alpha = SCRIM_ALPHA * (1 - progress)
        }

        override fun handleOnBackPressed() {
            val fling = if (SystemClock.uptimeMillis() - lastProgressAt < VELOCITY_WINDOW_MS) velocity.coerceAtLeast(0f) else 0f
            velocity = 0f
            pop(fling)
        }

        override fun handleOnBackCancelled() {
            val entry = entries.lastOrNull() ?: return
            entry.spring.animateTo(0f)
            below(entry)?.spring?.animateTo(-PARALLAX * width)
            fadeScrim(SCRIM_ALPHA, entering = true)
        }
    }

    /** Adds [page] on top; [animate] is false when restoring the stack. */
    fun push(page: SettingsPage, animate: Boolean = true) {
        if (closing) {
            release(page)
            return
        }
        val view = page.view
        val entry = Entry(page, DesignSpring(view, DynamicAnimation.TRANSLATION_X, DesignMotion.springSpatial))
        entry.spring.animation.addEndListener { _, canceled, _, _ -> if (!canceled) settle(entry) }
        val below = entries.lastOrNull()
        entries += entry
        updateBack()
        // The scrim sits between the new page and the one below it.
        removeView(scrim)
        addView(scrim, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        below?.page?.view?.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        below?.page?.onTopChanged(false)
        if (!animate) {
            below?.page?.view?.translationX = 0f
            scrim.alpha = 0f
            return
        }
        whenLaidOut {
            view.translationX = width.toFloat()
            entry.spring.animateTo(0f)
            below?.spring?.animateTo(-PARALLAX * width)
            below?.onSettled = null
            fadeScrim(SCRIM_ALPHA, entering = true)
            // Once in place the page below needs no dimming or offset; they are restored when popping.
            entry.onSettled = {
                below?.page?.view?.translationX = 0f
                below?.spring?.cancel()
                scrimAnimator?.cancel()
                scrim.alpha = 0f
            }
            if (!entry.spring.isRunning) settle(entry)
        }
    }

    /** Takes the top page off with [velocity] px/s; the last page closes the host. */
    fun pop(velocity: Float = 0f) {
        val entry = entries.lastOrNull() ?: return
        val below = below(entry)
        if (below == null && keepsRoot) return
        if (below == null) closing = true
        // From rest, put the dimming and the page below back where the slide starts.
        if (entry.page.view.translationX == 0f) {
            scrim.alpha = SCRIM_ALPHA
            if (below != null && below.page.view.translationX == 0f) below.page.view.translationX = -PARALLAX * width
        }
        entry.onSettled = { remove(entry) }
        entry.spring.animateTo(width.toFloat(), velocity)
        below?.spring?.animateTo(0f)
        fadeScrim(0f, entering = false)
        if (!entry.spring.isRunning) settle(entry)
    }

    /** Takes every page over the root off at once, as tapping the selected tab again does. */
    fun popToRoot() {
        while (entries.size > 1) {
            val entry = entries.last()
            entry.spring.cancel()
            remove(entry)
        }
        // The root may still be sliding aside from the last push; its spring would carry it off again.
        entries.firstOrNull()?.let {
            it.spring.cancel()
            it.onSettled = null
            it.page.view.translationX = 0f
        }
    }

    /** Removes everything at once, for example when the account signs out. */
    fun clear() {
        entries.toList().forEach {
            it.spring.cancel()
            removeView(it.page.view)
            release(it.page)
        }
        entries.clear()
    }

    private fun updateBack() {
        backCallback.isEnabled = active && (!keepsRoot || entries.size > 1)
    }

    private fun remove(entry: Entry) {
        entries -= entry
        updateBack()
        removeView(entry.page.view)
        release(entry.page)
        val top = entries.lastOrNull()
        if (top == null) {
            onEmpty()
            return
        }
        top.page.view.translationX = 0f
        top.page.view.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        top.page.onTopChanged(true)
        removeView(scrim)
        addView(scrim, indexOfChild(top.page.view), LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        scrimAnimator?.cancel()
        scrim.alpha = 0f
    }

    private fun release(page: SettingsPage) {
        renderers.removeAll { it.first === page }
        page.onRemoved()
    }

    private fun settle(entry: Entry) {
        val action = entry.onSettled ?: return
        entry.onSettled = null
        action()
    }

    private fun below(entry: Entry): Entry? = entries.getOrNull(entries.indexOf(entry) - 1)

    /** Opacity uses the dialog timings and curves, not a spring. */
    private fun fadeScrim(target: Float, entering: Boolean) {
        scrimAnimator?.cancel()
        scrimAnimator = ValueAnimator.ofFloat(scrim.alpha, target).apply {
            duration = DesignMotion.durationMillis(if (entering) DesignMotion.dialogEnter else DesignMotion.dialogExit)
            interpolator = if (entering) DesignMotion.smoothOut else DesignMotion.softInOut
            addUpdateListener { scrim.alpha = it.animatedValue as Float }
            start()
        }
    }

    private fun whenLaidOut(action: () -> Unit) {
        if (isLaidOut && width > 0) action() else addOnLayoutChangeListener(object : OnLayoutChangeListener {
            override fun onLayoutChange(v: View, l: Int, t: Int, r: Int, b: Int, ol: Int, ot: Int, or: Int, ob: Int) {
                if (width == 0) return
                removeOnLayoutChangeListener(this)
                action()
            }
        })
    }

    private companion object {
        const val PARALLAX = 0.25f
        const val SCRIM_ALPHA = 0.24f
        const val VELOCITY_WINDOW_MS = 100L
    }
}
