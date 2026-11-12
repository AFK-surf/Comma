package surf.comma.android.settings.desktop

import android.content.Intent
import android.content.res.ColorStateList
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.content.FileProvider
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.text
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.io.File

/**
 * Settings > Drive and System Files: one space at a time, its folders then files, with a breadcrumb back to any
 * parent. The bar holds the space filter and the new memory file action; search stays above the breadcrumb.
 */
internal class DrivePage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_drive, KEY) {
    private val model = scope?.let(::DriveModel)
    private val search = activity.fieldRow(activity.getString(R.string.ds_drive_search)) { model?.query = it }
    private val crumbs = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(activity.dp(4), 0, activity.dp(4), 0)
    }
    /** The breadcrumb scrolls sideways; the current folder stays in view. */
    private val breadcrumb = RecyclerView(activity).apply {
        layoutManager = LinearLayoutManager(activity, LinearLayoutManager.HORIZONTAL, false)
        adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            override fun getItemCount() = 1
            override fun onCreateViewHolder(parent: android.view.ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(crumbs) {}
            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
        }
        contentDescription = activity.getString(R.string.ds_drive_location)
        minimumHeight = activity.dp(44)
    }
    private val list = SettingsSection(activity, null)
    private val pager = SettingsSection(activity, null)
    private val empty = activity.text(Level.REGULAR, R.color.token_text_tertiary).apply {
        text = activity.getString(R.string.ds_drive_no_files)
        gravity = Gravity.CENTER
        setPadding(0, activity.dp(32), 0, activity.dp(32))
    }
    private val note = SettingsSection(activity, null).add(activity.noteRow(activity.getString(R.string.ds_drive_node_off)))
    private val filter = barButton(R.drawable.ic_list_filter, R.string.ds_drive_scope) { anchor -> chooseSpace(anchor) }
    private val create = barButton(R.drawable.ic_plus_small, R.string.ds_drive_new_file) { scope?.let { ctx.open(DriveDocumentPage(ctx, DriveDocument(it))) } }

    init {
        layout.trailing.addView(filter)
        layout.trailing.addView(create)
        layout.section(SettingsSection(activity, null).add(search), top = 0)
        layout.section(breadcrumb, top = 8)
        layout.section(list, top = 4)
        layout.section(pager, top = 12)
        layout.section(empty, top = 0)
        layout.section(note)
        model?.follow()
        start { model?.refresh() }
    }

    private fun barButton(icon: Int, description: Int, onClick: (View) -> Unit) = ImageView(activity).apply {
        setImageResource(icon)
        imageTintList = ColorStateList.valueOf(activity.color(R.color.token_fg_primary))
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        contentDescription = activity.getString(description)
        layoutParams = LinearLayout.LayoutParams(activity.dp(44), activity.dp(44))
        PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        setOnClickListener(onClick)
    }

    private fun spaceName(space: DriveSpace) = space.name ?: activity.getString(
        if (space.id == DriveSpace.SYSTEM_FILES) R.string.ds_drive_system_files else R.string.ds_drive_task_files)

    private fun chooseSpace(anchor: View) {
        val model = model ?: return
        val menu = ActionMenu(activity)
        model.spaces.forEach { space -> menu.item(spaceName(space), checked = space.id == model.selectedSpaceId) { model.selectSpace(space.id) } }
        menu.show(anchor)
    }

    override fun render() {
        super.render()
        val model = model ?: return
        val loaded = model.feed.loaded
        loading.isVisible = !loaded
        if (search.text.toString() != model.query) search.setText(model.query)
        val space = model.selectedSpace
        filter.isEnabled = model.spaces.isNotEmpty() && model.scope.current
        filter.alpha = if (filter.isEnabled) 1f else 0.4f
        create.isEnabled = model.selectedSpaceId == DriveSpace.SYSTEM_FILES && model.scope.current && !model.scope.busy
        create.alpha = if (create.isEnabled) 1f else 0.4f
        breadcrumb.isVisible = space != null
        list.isVisible = model.spaces.isNotEmpty()
        if (space != null) renderCrumbs(listOf(spaceName(space)) + model.folderPath, model)
        val rows = model.entries.map { entry ->
            when (entry) {
                is DriveEntry.Folder -> activity.linkRow(entry.name, icon = R.drawable.ic_settings_folder) { model.openFolder(entry.name) }
                is DriveEntry.File -> activity.linkRow(entry.file.name, Formatter.formatShortFileSize(activity, entry.file.size), R.drawable.ic_settings_file) {
                    ctx.open(DriveDocumentPage(ctx, DriveDocument(model.scope, entry.file)))
                }
            }
        }.toMutableList<View>()
        if (loaded && model.entries.isEmpty() && model.spaces.isNotEmpty()) {
            rows += activity.infoRow(activity.getString(if (model.query.isEmpty()) R.string.ds_drive_folder_empty else R.string.ds_drive_no_files))
        }
        list.fill(rows)
        pager.fill(if (model.pageCount > 1) listOf(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(activity.inlineButton(activity.getString(R.string.ds_drive_previous)) { model.movePage(-1) }.apply { isEnabled = model.page > 0 })
            addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply {
                text = activity.getString(R.string.ds_drive_page, model.page + 1, model.pageCount)
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(activity.inlineButton(activity.getString(R.string.ds_drive_next)) { model.movePage(1) }.apply { isEnabled = model.page + 1 < model.pageCount })
        }) else emptyList())
        empty.isVisible = loaded && model.spaces.isEmpty() && model.scope.error == null
        note.isVisible = loaded && model.entryCount == 0 && model.query.isEmpty() && model.scope.error == null && model.nodeOff
    }

    private fun renderCrumbs(names: List<String>, model: DriveModel) {
        crumbs.removeAllViews()
        names.forEachIndexed { depth, name ->
            if (depth > 0) crumbs.addView(ImageView(activity).apply {
                setImageResource(R.drawable.ic_settings_chevron)
                imageTintList = ColorStateList.valueOf(activity.color(R.color.token_text_quaternary))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(activity.dp(16), activity.dp(16)))
            val last = depth == model.folderPath.size
            crumbs.addView(activity.text(Level.SMALL, if (last) R.color.token_text_primary else R.color.token_text_secondary,
                if (last) DesignFonts.semibold else DesignFonts.regular).apply {
                text = name
                minHeight = activity.dp(44)
                gravity = Gravity.CENTER_VERTICAL
                setPadding(activity.dp(6), 0, activity.dp(6), 0)
                if (last) isAccessibilityHeading = true else setOnClickListener { model.navigate(depth) }
            })
        }
        breadcrumb.contentDescription = activity.getString(R.string.ds_drive_location) + ": " + names.joinToString(" / ")
        breadcrumb.post { breadcrumb.scrollBy(Int.MAX_VALUE / 2, 0) }
    }

    companion object { const val KEY = "drive" }
}

/**
 * A Drive file: memory and instructions are edited and saved over the version read; other files preview as text, or
 * open in another app. Saving or sharing goes through the system share sheet; it can also join the Router chat's draft.
 */
internal class DriveDocumentPage(ctx: SettingsContext, private val model: DriveDocument) :
    WorkspacePage(ctx, R.string.ds_drive_new_file, "drive.file", model.scope, titleText = model.file?.name) {
    private val pathField = activity.fieldRow(activity.getString(R.string.ds_drive_memory_path)) { model.path = it }
    private val editor = activity.fieldRow(activity.getString(R.string.ds_drive_content), lines = 8, mono = true) { model.text = it; render() }
    private val preview = activity.textBlock("")
    private val pathSection = SettingsSection(activity, activity.getString(R.string.ds_drive_memory_path)).add(pathField)
        .footer(activity.getString(R.string.ds_drive_memory_path_footer))
    private val content = SettingsSection(activity, null)
    private val actions = SettingsSection(activity, null)
    private var started = false

    init {
        pathField.setText(model.path)
        started = true
        layout.section(pathSection, top = 0)
        layout.section(content)
        layout.section(actions)
        start { model.load() }
        launch { model.load() }
    }

    override fun render() {
        if (!started) return
        super.render()
        loading.isVisible = !model.loaded
        pathSection.isVisible = model.loaded && model.file == null
        content.isVisible = model.loaded
        actions.isVisible = model.loaded
        if (!model.loaded) return
        if (model.editable) {
            if (editor.text.toString() != model.text) editor.setText(model.text)
            content.fill(listOf(editor))
        } else {
            preview.text = model.preview
            content.fill(listOfNotNull(preview.takeIf { model.preview != null },
                activity.actionRow(activity.getString(R.string.ds_drive_open_preview)) { openWith(Intent.ACTION_VIEW) }.takeIf { model.preview == null && model.bytes != null }))
        }
        val rows = mutableListOf<View>()
        if (model.editable) rows += activity.actionRow(activity.getString(R.string.settings_save)) {
            launch { if (model.save() && model.file == null) ctx.back() }
        }.apply { isEnabled = !(model.saved == model.text && model.file != null) }
        if (model.bytes != null) {
            rows += activity.linkRow(activity.getString(R.string.ds_drive_share), icon = R.drawable.ic_share_os) { openWith(Intent.ACTION_SEND) }
            rows += activity.actionRow(activity.getString(R.string.ds_drive_add_to_router)) {
                val bytes = model.bytes ?: return@actionRow
                launch { if (model.scope.current && ctx.attachToRouter(model.name, bytes)) ctx.openRouter() }
            }.apply { isEnabled = model.saved == model.text }
        }
        actions.fill(rows)
    }

    /** Hands the file to another app through a private, read-only content link. */
    private fun openWith(action: String) {
        val bytes = model.bytes ?: return
        runCatching {
            val folder = File(activity.cacheDir, "drive-preview").apply { deleteRecursively(); mkdirs() }
            val file = File(folder, File(model.name).name.ifEmpty { "file" }).apply { writeBytes(bytes) }
            val uri = FileProvider.getUriForFile(activity, activity.packageName + ".composer.files", file)
            val intent = Intent(action).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (action == Intent.ACTION_SEND) intent.setType(model.mediaType).putExtra(Intent.EXTRA_STREAM, uri)
            else intent.setDataAndType(uri, model.mediaType)
            activity.startActivity(Intent.createChooser(intent, null))
        }.onFailure { ctx.toast(activity.getString(R.string.ds_drive_open_failed), true) }
    }
}
