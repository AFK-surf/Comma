package surf.comma.android.tasks.files

import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.activity.ComponentActivity
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import surf.comma.android.R
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaDownloadState
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.MediaSource
import surf.comma.android.media.file.AttachmentFileActions
import surf.comma.android.media.file.FileCardView
import surf.comma.android.tasks.tools.ToolPage
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.composer.ComposerModel
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.dpf
import surf.comma.android.ui.kit.glyph
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import java.io.File

/**
 * The open Task's files (Task details > Task files): the files its Agents attached, newest first, a page at a time.
 * Tapping one previews it in another app; its menu also saves or shares it, or adds it to the Task's draft by reference
 * (nothing is sent). The page ends with the account or Workspace: a late download then opens nothing.
 */
internal class TaskFilesSheet(
    activity: ComponentActivity,
    private val model: TaskFilesModel,
    /** How many files the Task's draft holds now. */
    private val draftFiles: () -> Int,
) : CommaSheet(activity, activity.getString(R.string.task_files_title), Detent.LARGE) {
    private val page = ToolPage(activity)
    private val search = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.getColor(R.color.token_text_primary))
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        setHint(R.string.task_files_search)
        isSingleLine = true
        background = rounded(activity.getColor(R.color.token_bg_tertiary), activity.dpf(12f))
        setPadding(activity.dp(14), activity.dp(10), activity.dp(14), activity.dp(10))
        doAfterTextChanged { render() }
    }
    private var following: Job? = null
    private var work: Job? = null

    init {
        setContent(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(search, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                marginStart = activity.dp(16); marginEnd = activity.dp(16); bottomMargin = activity.dp(8)
            })
            addView(page.view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        following = activity.lifecycleScope.launch { model.state.collect { render() } }
        activity.lifecycleScope.launch { model.load() }
    }

    override fun onRemoved() {
        following?.cancel()
        work?.cancel()
    }

    private fun render() {
        val state = model.state.value
        page.clear()
        if (state.loading && !state.loaded) page.progress()
        if (state.indexing) {
            val section = page.section()
            page.note(section, activity.getString(R.string.task_files_indexing))
            page.action(section, activity.getString(R.string.task_files_refresh)) { reload() }
        }
        if (state.loaded && !state.loading && !state.indexing && state.files.isEmpty() && state.failed == null) {
            page.note(page.section(), activity.getString(R.string.task_files_empty))
        }
        val shown = TaskFilesModel.filter(state.files, search.text?.toString().orEmpty())
        if (shown.isNotEmpty()) {
            val section = page.section(activity.getString(R.string.task_files_title))
            shown.forEach { file -> section.add(row(file, state)) }
        }
        if (!state.cursor.isNullOrEmpty()) {
            page.action(page.section(), activity.getString(if (state.loading) R.string.task_files_loading else R.string.task_files_load_more),
                enabled = !state.loading) { activity.lifecycleScope.launch { model.load(more = true) } }
        }
        when (val failed = state.failed) {
            TaskFilesModel.Failure.Unavailable -> page.error(activity.getString(R.string.task_files_failed)) { reload() }
            is TaskFilesModel.Failure.Said -> page.error(failed.message ?: activity.getString(R.string.task_files_failed)) { reload() }
            null -> Unit
        }
    }

    private fun reload() {
        activity.lifecycleScope.launch { model.load() }
    }

    private fun row(file: TaskFile, state: TaskFilesModel.State): View = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = activity.dp(56)
        setPadding(activity.dp(14), activity.dp(8), 0, activity.dp(8))
        val busy = state.preparing != null
        val body = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(activity.glyph(if (file.isImage) R.drawable.ic_media_file_image else R.drawable.ic_media_file, R.color.token_text_tertiary),
                LinearLayout.LayoutParams(activity.dp(24), activity.dp(24)))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(activity.label(Level.REGULAR, R.color.token_text_primary, lines = 2).apply { text = file.name })
                addView(activity.label(Level.MINI, R.color.token_text_tertiary).apply {
                    text = Formatter.formatShortFileSize(activity, file.size)
                }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = activity.dp(3) })
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(12) })
            if (state.preparing == file.id) addView(ProgressBar(activity), LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
            isEnabled = !busy
            alpha = if (busy && state.preparing != file.id) 0.5f else 1f
            setOnClickListener { prepare(file, ::openFile) }
        }
        addView(body, LinearLayout.LayoutParams(0, -2, 1f))
        addView(FrameLayout(activity).apply {
            contentDescription = activity.getString(R.string.task_files_actions, file.name)
            isEnabled = !busy && !state.attaching
            alpha = if (isEnabled) 1f else 0.5f
            addView(activity.glyph(R.drawable.ic_action_more, R.color.token_text_tertiary),
                FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
            setOnClickListener { anchor -> menu(anchor, file) }
        }, LinearLayout.LayoutParams(activity.dp(48), activity.dp(48)))
    }

    private fun menu(anchor: View, file: TaskFile) {
        ActionMenu(activity)
            .item(activity.getString(R.string.task_files_preview)) { prepare(file, ::openFile) }
            .item(activity.getString(R.string.media_file_save_as)) {
                prepare(file) { ready, media -> AttachmentFileActions.saveAs(activity, ready, media) }
            }
            .item(activity.getString(R.string.media_file_share)) {
                prepare(file) { ready, media -> AttachmentFileActions.share(activity, ready, media) }
            }
            .item(activity.getString(R.string.task_files_add_to_context),
                enabled = draftFiles() < ComposerModel.MAX_ATTACHMENTS) {
                activity.lifecycleScope.launch { if (model.attach(file)) dismiss() }
            }
            .show(anchor)
    }

    /** Downloads [file] through the core's downloads, then runs [act] with it (open, save as or share); one at a time. */
    private fun prepare(file: TaskFile, act: (File, MediaAttachment) -> Unit) {
        if (!model.beginPreparing(file)) return
        work = activity.lifecycleScope.launch {
            var failure: String? = null
            try {
                val ready = download(file)
                if (!model.current) return@launch
                if (ready == null) failure = activity.getString(R.string.media_file_unavailable)
                else act(ready, attachment(file))
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                failure = error.message
            } finally {
                model.endPreparing(failure)
            }
        }
    }

    private fun openFile(file: File, media: MediaAttachment) {
        FileCardView.open(activity, file, media)
    }

    private fun attachment(file: TaskFile) = MediaAttachment(file.name, file.mediaType, file.size,
        MediaSource.MessageAttachment(file.conversation, file.message, file.index, null))

    private suspend fun download(file: TaskFile): File? {
        val download = MediaGraph.get(activity).files.download(attachment(file)) ?: return null
        download.start()
        val end = withTimeoutOrNull(DOWNLOAD_WAIT_MS) {
            download.state.first { it is MediaDownloadState.Ready || it is MediaDownloadState.Failed }
        }
        return (end as? MediaDownloadState.Ready)?.file
    }

    private companion object {
        const val DOWNLOAD_WAIT_MS = 120_000L
    }
}
