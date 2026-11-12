package surf.comma.android.miniapps

import android.app.Activity
import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.core.CoreError
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.settings.SettingsDialog
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.filledButton
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignTypography.Level
import java.io.ByteArrayOutputStream

/**
 * New encodings of picked photos: at most 2048 px on the long side, JPEG at 80 or PNG, without the source's metadata
 * or library identifiers. Decoding is bounded to that size.
 */
internal object MiniAppPhotoEncoding {
    private const val MAX_SIDE = 2048

    fun encode(resolver: ContentResolver, uri: Uri, png: Boolean): MiniAppPhoto {
        val bitmap = try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                val side = maxOf(info.size.width, info.size.height)
                if (side > MAX_SIDE) {
                    val scale = MAX_SIDE.toFloat() / side
                    decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } catch (_: Exception) {
            throw CoreError("invalid", "The photo could not be loaded.")
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 80, out)
        bitmap.recycle()
        val bytes = out.toByteArray()
        if (bytes.isEmpty() || bytes.size > MiniAppPhotoRequest.MAX_PHOTO_BYTES) throw CoreError("quota_exceeded", "The photo is too large.")
        return MiniAppPhoto(bytes, png)
    }
}

/**
 * The host's photo confirmation: only the photos the member confirms here reach the app. Choosing and taking photos
 * are the activity's ([choose], [camera]); [share] sends the confirmed ones, and closing otherwise sends none.
 */
internal class MiniAppPhotoDialog(
    private val activity: Activity,
    appName: String,
    private val share: (List<MiniAppPhoto>) -> Unit,
    private val choose: () -> Unit,
    private val camera: () -> Unit,
    private val cancel: () -> Unit,
) : SettingsDialog(activity) {
    private var photos: List<MiniAppPhoto> = emptyList()
    private var shared = false
    private val failure = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }
    private val strip = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val stripScroll = ScrollContainer(activity).apply {
        orientation = ScrollContainer.HORIZONTAL
        addView(strip)
        isVisible = false
    }
    private val shareButton = activity.filledButton(activity.getString(R.string.mini_app_photo_share), R.color.token_bg_brand_solid, null).apply {
        isVisible = false
        setOnClickListener {
            shared = true
            share(photos)
            dismiss()
        }
    }

    init {
        card.addView(title(activity.getString(R.string.mini_app_photo_title, appName)))
        card.addView(message(activity.getString(R.string.mini_app_photo_message)), params(8))
        card.addView(failure, params(8))
        card.addView(stripScroll, LinearLayout.LayoutParams(-1, activity.dp(96)).apply { topMargin = activity.dp(16) })
        card.addView(shareButton, LinearLayout.LayoutParams(-1, activity.dp(44)).apply { topMargin = activity.dp(16) })
        card.addView(secondary(R.string.mini_app_photo_choose, choose), LinearLayout.LayoutParams(-1, activity.dp(44)).apply { topMargin = activity.dp(12) })
        card.addView(secondary(R.string.mini_app_photo_camera, camera), LinearLayout.LayoutParams(-1, activity.dp(44)).apply { topMargin = activity.dp(8) })
        card.addView(secondary(R.string.settings_cancel) { dismiss() }, LinearLayout.LayoutParams(-1, activity.dp(44)).apply { topMargin = activity.dp(8) })
    }

    private fun params(top: Int) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(top) }

    private fun secondary(label: Int, action: () -> Unit): TextView =
        activity.filledButton(activity.getString(label), R.color.token_bg_quaternary, R.color.token_text_primary).apply {
            gravity = Gravity.CENTER
            setOnClickListener {
                failure.isVisible = false
                action()
            }
        }

    fun showPhotos(picked: List<MiniAppPhoto>) {
        photos = picked
        strip.removeAllViews()
        picked.forEach { photo ->
            strip.addView(ImageView(activity).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                clipToOutline = true
                background = surf.comma.android.settings.roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(12).toFloat())
                setImageBitmap(android.graphics.BitmapFactory.decodeByteArray(photo.data, 0, photo.data.size))
            }, LinearLayout.LayoutParams(activity.dp(96), activity.dp(96)).apply { marginEnd = activity.dp(8) })
        }
        stripScroll.isVisible = picked.isNotEmpty()
        shareButton.isVisible = picked.isNotEmpty()
    }

    fun showFailure(text: String) {
        showPhotos(emptyList())
        failure.text = text
        failure.isVisible = true
    }

    override fun onClosing() {
        if (!shared) cancel()
    }
}

/** Asks for cloud access before the host reads or runs the app bundle. Closing it without Run closes the app. */
internal class MiniAppConsentDialog(activity: Activity, private val run: () -> Unit, private val cancel: () -> Unit) : SettingsDialog(activity) {
    private var approved = false

    init {
        card.addView(title(activity.getString(R.string.mini_app_consent_title)))
        card.addView(message(activity.getString(R.string.mini_app_consent_message)), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        card.addView(buttons(activity.getString(R.string.mini_app_consent_run), destructive = false) {
            approved = true
            run()
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }

    override fun onClosing() {
        if (!approved) cancel()
    }
}

/**
 * The host's confirmation for one app action or capability: [allow] answers yes, any other close answers no. The app's
 * text or link shows as it is, selectable, so the member sees exactly what the app asked for.
 */
internal class MiniAppHostDialog(
    activity: Activity,
    appName: String,
    request: MiniAppSession.HostRequest,
    private val allow: () -> Unit,
    private val cancel: () -> Unit,
) : SettingsDialog(activity) {
    private var allowed = false

    init {
        card.addView(message(appName))
        card.addView(title(activity.getString(hostRequestTitle(request.op))), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(4) })
        if (request.detail.isNotEmpty()) {
            // All of it is what the app acts on, so a long text scrolls rather than being cut.
            val detail = object : FrameLayout(activity) {
                override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) = super.onMeasure(widthMeasureSpec,
                    MeasureSpec.makeMeasureSpec(activity.dp(HOST_DETAIL_MAX_HEIGHT_DP), MeasureSpec.AT_MOST))
            }
            detail.addView(ScrollContainer(activity).apply {
                isVerticalScrollBarEnabled = true
                isScrollbarFadingEnabled = false
                addView(message(request.detail).apply { setTextIsSelectable(true) })
            }, FrameLayout.LayoutParams(-1, -2))
            card.addView(detail, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        }
        card.addView(buttons(activity.getString(R.string.mini_app_host_allow), destructive = false) {
            allowed = true
            allow()
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }

    override fun onClosing() {
        if (!allowed) cancel()
    }
}

internal fun hostRequestTitle(op: String): Int = when (op) {
    "tasks.propose" -> R.string.mini_app_host_task
    "links.open" -> R.string.mini_app_host_link
    "identity.basic" -> R.string.mini_app_host_identity
    "drive.app_folder" -> R.string.mini_app_host_drive
    "notifications" -> R.string.mini_app_host_notifications
    else -> R.string.mini_app_host_action
}

private const val HOST_DETAIL_MAX_HEIGHT_DP = 240
