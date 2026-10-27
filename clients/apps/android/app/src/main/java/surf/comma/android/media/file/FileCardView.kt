package surf.comma.android.media.file

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.text.format.Formatter
import android.view.Gravity
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.annotation.MainThread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.media.FileKind
import surf.comma.android.media.FileKinds
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaDownload
import surf.comma.android.media.MediaDownloadState
import surf.comma.android.media.MediaLimits
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import java.io.File

/**
 * Any attachment that is not shown inline, including SVG, HTML and PDF: they may run scripts or
 * load remote resources, so they are never rendered here. Tapping downloads the whole file into
 * the media cache and hands it to another app to open.
 */
class FileCardView(context: Context) : LinearLayout(context) {
    private val density = resources.displayMetrics.density
    private val icon = ImageView(context).apply {
        imageTintList = android.content.res.ColorStateList.valueOf(context.getColor(R.color.token_fg_primary))
    }
    private val name = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.medium)
        setTextColor(context.getColor(R.color.token_text_primary))
        maxLines = 1
        // Keep the extension visible; it says as much as the icon.
        ellipsize = TextUtils.TruncateAt.MIDDLE
    }
    private val detail = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.MINI, DesignFonts.regular)
        setTextColor(context.getColor(R.color.token_text_quaternary))
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }
    private var attachment: MediaAttachment? = null
    private var download: MediaDownload? = null
    private var job: Job? = null
    private var openWhenReady = false

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val padding = (12 * density).toInt()
        setPadding(padding, padding, (16 * density).toInt(), padding)
        background = GradientDrawable().apply {
            setColor(context.getColor(R.color.token_bg_secondary))
            cornerRadius = resources.getDimension(R.dimen.radius_xl)
            // DESIGN: a 0.5 line is one physical pixel.
            setStroke(1, context.getColor(R.color.token_border_primary))
        }
        val iconBox = (40 * density).toInt()
        val iconPad = (8 * density).toInt()
        icon.setPadding(iconPad, iconPad, iconPad, iconPad)
        icon.background = GradientDrawable().apply {
            setColor(context.getColor(R.color.token_bg_quaternary))
            cornerRadius = 8 * density
        }
        addView(icon, LayoutParams(iconBox, iconBox))
        val texts = LinearLayout(context).apply {
            orientation = VERTICAL
            addView(name)
            addView(detail)
        }
        addView(texts, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = (12 * density).toInt() })
        setOnClickListener { onTap() }
    }

    /** [download] is null when the file cannot be fetched (too large, path-only, or signed out). */
    @MainThread
    fun bind(attachment: MediaAttachment, download: MediaDownload?, scope: CoroutineScope) {
        unbind()
        this.attachment = attachment
        this.download = download
        val kind = FileKinds.kind(attachment.fileName, attachment.mimeType)
        icon.setImageResource(iconFor(kind))
        name.text = attachment.displayName
        contentDescription = attachment.displayName
        render(download?.state?.value ?: MediaDownloadState.Idle)
        val flow = download?.state ?: return
        job = scope.launch(Dispatchers.Main.immediate) {
            flow.drop(1).collect { state ->
                render(state)
                if (state is MediaDownloadState.Ready && openWhenReady) {
                    openWhenReady = false
                    open(context, state.file, attachment)
                }
                if (state !is MediaDownloadState.Downloading) openWhenReady = false
            }
        }
    }

    @MainThread
    fun unbind() {
        job?.cancel()
        job = null
        attachment = null
        download = null
        openWhenReady = false
    }

    private fun render(state: MediaDownloadState) {
        val attachment = attachment ?: return
        val kind = context.getString(kindLabel(FileKinds.kind(attachment.fileName, attachment.mimeType)))
        val size = attachment.size?.let { Formatter.formatShortFileSize(context, it) }
        val summary = if (size != null) context.getString(R.string.media_file_meta, kind, size) else kind
        detail.text = when {
            download == null -> context.getString(R.string.media_file_unavailable)
            state is MediaDownloadState.Downloading -> state.progress?.let {
                context.getString(R.string.media_file_downloading, (it * 100).toInt())
            } ?: context.getString(R.string.media_file_downloading_unknown)
            state is MediaDownloadState.Failed && state.reason == MediaDownloadState.Failure.UNAVAILABLE ->
                context.getString(R.string.media_file_unavailable)
            state is MediaDownloadState.Failed -> context.getString(R.string.media_file_failed)
            else -> summary
        }
    }

    private fun onTap() {
        val attachment = attachment ?: return
        val download = download ?: run {
            Toast.makeText(context, R.string.media_file_unavailable, Toast.LENGTH_SHORT).show()
            return
        }
        when (val state = download.state.value) {
            is MediaDownloadState.Ready -> open(context, state.file, attachment)
            is MediaDownloadState.Downloading -> { openWhenReady = false; download.cancel() }
            else -> { openWhenReady = true; download.start() }
        }
    }

    companion object {
        fun iconFor(kind: FileKind): Int = when (kind) {
            FileKind.IMAGE -> R.drawable.ic_media_file_image
            FileKind.VIDEO -> R.drawable.ic_media_file_video
            FileKind.AUDIO -> R.drawable.ic_media_file_audio
            FileKind.PDF -> R.drawable.ic_media_file_pdf
            FileKind.TEXT -> R.drawable.ic_media_file_text
            FileKind.CODE -> R.drawable.ic_media_file_code
            FileKind.ARCHIVE -> R.drawable.ic_media_file_archive
            FileKind.OTHER -> R.drawable.ic_media_file
        }

        fun kindLabel(kind: FileKind): Int = when (kind) {
            FileKind.IMAGE -> R.string.media_file_kind_image
            FileKind.VIDEO -> R.string.media_file_kind_video
            FileKind.AUDIO -> R.string.media_file_kind_audio
            FileKind.PDF -> R.string.media_file_kind_pdf
            FileKind.TEXT -> R.string.media_file_kind_text
            FileKind.CODE -> R.string.media_file_kind_code
            FileKind.ARCHIVE -> R.string.media_file_kind_archive
            FileKind.OTHER -> R.string.media_file_kind_other
        }

        /**
         * Hands [file] to another app, read-only, through [MediaFileProvider]. Says so when no
         * installed app can open the type.
         */
        fun open(context: Context, file: File, attachment: MediaAttachment): Boolean {
            val uri = MediaFileProvider.uri(context, file) ?: run {
                // Only the downloads are shared; anything else is refused, never crashes the list.
                Toast.makeText(context, R.string.media_file_unavailable, Toast.LENGTH_SHORT).show()
                return false
            }
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, FileKinds.openType(attachment.fileName, attachment.mimeType))
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            return try {
                context.startActivity(intent)
                true
            } catch (_: ActivityNotFoundException) {
                Toast.makeText(context, R.string.media_file_no_app, Toast.LENGTH_SHORT).show()
                false
            }
        }
    }
}
