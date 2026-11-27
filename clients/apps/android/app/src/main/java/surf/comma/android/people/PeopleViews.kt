package surf.comma.android.people

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreBytes
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.clipToRoundedBackground
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * Another person's face: their photo where the core has one for them ([source], a `files.read` source), else their
 * initials on a tint taken from their name, so one person keeps one colour on every list.
 */
internal class PersonAvatarView(context: Context, private val sizeDp: Int) : FrameLayout(context) {
    private val letters = context.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
        setTextColor(Color.WHITE)
        textSize = sizeDp * 0.4f
        gravity = Gravity.CENTER
        includeFontPadding = false
    }
    private val photo = ImageView(context).apply { scaleType = ImageView.ScaleType.CENTER_CROP; isVisible = false }
    private var loading: Job? = null
    private var shownSource: String? = null

    init {
        clipToOutline = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(letters, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(photo, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun show(name: String, source: JSONObject? = null, core: CoreApi? = null) {
        background = roundRect(tint(name), context.dp(sizeDp) / 2f)
        letters.text = initials(name)
        val key = source?.let(::canonicalKey)
        if (key == shownSource) return
        shownSource = key
        loading?.cancel()
        photo.isVisible = false
        if (source == null || key == null) return
        cache.get(key)?.let { cached ->
            photo.setImageBitmap(cached)
            photo.isVisible = true
            return
        }
        if (core == null) return
        val owner = context as? LifecycleOwner ?: return
        loading = owner.lifecycleScope.launch {
            val bitmap = runCatching {
                val answer = core.call("files.read", JSONObject(source.toString())) as? JSONObject
                val bytes = CoreBytes.read(answer?.opt("bytes")) ?: return@runCatching null
                withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
            }.getOrNull() ?: return@launch
            cache.put(key, bitmap)
            if (shownSource == key) {
                photo.setImageBitmap(bitmap)
                photo.isVisible = true
            }
        }
    }

    private fun tint(name: String): Int = tint(context, name)

    companion object {
        /** The colour behind [name]'s initials, the same for one person on every list. */
        fun tint(context: Context, name: String): Int {
            val tints = listOf(R.color.token_label_brand, R.color.token_label_indigo, R.color.token_label_blue,
                R.color.token_label_orange, R.color.token_label_pink, R.color.token_label_success, R.color.token_label_purple)
            val sum = name.fold(0) { acc, c -> (acc * 31 + c.code) and 0xFFFF }
            return context.color(tints[sum % tints.size])
        }

        private val reading = HashSet<String>()

        /**
         * The photo read from [source], from the same cache as the lists' faces; null until it is read. A first ask
         * reads it once in [scope] and calls [ready] when it is there, so a canvas can draw it without a new layout.
         */
        fun photo(source: JSONObject, core: CoreApi?, scope: kotlinx.coroutines.CoroutineScope, ready: () -> Unit): android.graphics.Bitmap? {
            val key = canonicalKey(source)
            cache.get(key)?.let { return it }
            if (core == null || !reading.add(key)) return null
            scope.launch {
                try {
                    val bitmap = runCatching {
                        val answer = core.call("files.read", JSONObject(source.toString())) as? JSONObject
                        val bytes = CoreBytes.read(answer?.opt("bytes")) ?: return@runCatching null
                        withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
                    }.getOrNull() ?: return@launch
                    cache.put(key, bitmap)
                    ready()
                } finally {
                    reading.remove(key)
                }
            }
            return null
        }

        /** Decoded photos by source, bounded by their size in memory rather than their count: a photo may be large. */
        private val cache = object : android.util.LruCache<String, android.graphics.Bitmap>(CACHE_BYTES) {
            override fun sizeOf(key: String, value: android.graphics.Bitmap) = value.allocationByteCount
        }
        private const val CACHE_BYTES = 16 * 1024 * 1024

        internal fun clearCache() { cache.evictAll() }

        private fun canonicalKey(source: JSONObject): String =
            source.keys().asSequence().toList().sorted().joinToString(prefix = "{", postfix = "}") { k ->
                val v = source.opt(k)
                val encoded = if (v is JSONObject) canonicalKey(v) else JSONObject.quote(v?.toString().orEmpty())
                "${JSONObject.quote(k)}:$encoded"
            }

        fun initials(name: String): String =
            if (name.contains("@")) name.take(1).uppercase()
            else name.split(" ").filter(String::isNotBlank).take(2).mapNotNull { it.firstOrNull() }.joinToString("").uppercase()
    }
}

/** Faces in a row, each over the one before with a ring of [ring] between them. */
internal fun Context.avatarStack(faces: List<Pair<String, JSONObject?>>, sizeDp: Int, ring: Int,
                                 core: CoreApi? = null, max: Int = 4): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER
    faces.take(max).forEachIndexed { index, (name, source) ->
        val avatar = PersonAvatarView(context, sizeDp).apply { show(name, source, core) }
        val framed = FrameLayout(context).apply {
            background = roundRect(color(ring), dp(sizeDp + 3) / 2f)
            setPadding(dp(1.5f), dp(1.5f), dp(1.5f), dp(1.5f))
            addView(avatar, FrameLayout.LayoutParams(dp(sizeDp), dp(sizeDp)))
        }
        addView(framed, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            if (index > 0) marginStart = -dp((sizeDp * 0.3f).toInt())
        })
    }
    contentDescription = faces.joinToString(", ") { it.first }
}

/** One row of a list of people or Tasks: a leading view, a title over a detail line, and a dot while it waits. */
internal fun Context.personRow(leading: View?, title: CharSequence, detail: CharSequence?, waiting: Boolean = false,
                               onClick: () -> Unit): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    minimumHeight = dp(56)
    setPadding(dp(10), dp(8), dp(10), dp(8))
    PressFeedback(this, R.color.token_surface_ink, scale = false)
    clipToRoundedBackground(dp(10).toFloat())
    isClickable = true
    setOnClickListener { onClick() }
    if (waiting) addView(View(context).apply { background = roundRect(color(R.color.token_bg_brand_solid), dp(4).toFloat()) },
        LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(10) })
    leading?.let { addView(it, (it.layoutParams as? LinearLayout.LayoutParams ?: LinearLayout.LayoutParams(-2, -2)).apply { marginEnd = dp(12) }) }
    val texts = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    texts.addView(text(Level.REGULAR, R.color.token_text_primary).apply {
        text = title
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
    })
    if (!detail.isNullOrEmpty()) texts.addView(text(Level.SMALL, R.color.token_text_tertiary).apply {
        text = detail
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(2) })
    addView(texts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    contentDescription = listOfNotNull(title, detail).joinToString(", ")
}

/**
 * One of a person's two ways to work with them: a glyph beside its name on a rounded surface, which deepens under a
 * finger. The surface is the frame's; the press is the tile's, over it.
 */
internal fun Context.actionTile(icon: Int, label: CharSequence, id: Int, onClick: () -> Unit): FrameLayout = FrameLayout(this).apply {
    // The Tasks group's surface, corners and row height, so the two read as sections of one page.
    val radius = dp(24).toFloat()
    background = roundRect(color(R.color.token_bg_tertiary), radius)
    clipToRoundedBackground(radius)
    val tile = LinearLayout(context).apply {
        this.id = id
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = dp(50)
        setPadding(dp(12), dp(10), dp(12), dp(10))
        PressFeedback(this, R.color.token_surface_ink, scale = false)
        isClickable = true
        setOnClickListener { onClick() }
        addView(ImageView(context).apply {
            setImageResource(icon)
            imageTintList = android.content.res.ColorStateList.valueOf(color(R.color.token_text_primary))
        }, LinearLayout.LayoutParams(dp(18), dp(18)))
        addView(text(Level.SMALL, R.color.token_text_primary, DesignFonts.medium).apply {
            text = label
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(6) })
        contentDescription = label
    }
    addView(tile, FrameLayout.LayoutParams(-1, -2))
}

internal fun TextView.lines(max: Int) = apply {
    maxLines = max
    ellipsize = TextUtils.TruncateAt.END
}

/** A sheet's text action in its bar (Start, Send, Next): the page's ink, semibold; faded while it cannot run. */
internal fun Context.barAction(label: CharSequence, onClick: () -> Unit): TextView =
    text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
        text = label
        gravity = Gravity.CENTER
        minHeight = dp(44)
        setPadding(dp(10), 0, dp(6), 0)
        setOnClickListener { onClick() }
    }

/** A glyph that leads a row, in the quiet ink of the row's details. */
internal fun Context.rowGlyph(icon: Int, tint: Int = R.color.token_text_tertiary, sizeDp: Int = 18): ImageView = ImageView(this).apply {
    setImageResource(icon)
    imageTintList = android.content.res.ColorStateList.valueOf(color(tint))
    layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
}
