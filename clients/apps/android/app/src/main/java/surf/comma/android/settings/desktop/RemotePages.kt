package surf.comma.android.settings.desktop

import android.annotation.SuppressLint
import android.graphics.Color
import android.text.InputType
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.core.view.isVisible
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.FieldDialog
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.clipToRoundedBackground
import surf.comma.android.settings.dp

/** Settings > Compute resources: the Workspace's shells and other workloads, with only the actions the server allows. */
internal class ComputePage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_compute, KEY) {
    private val feed = scope?.let { WorkspaceTopic(it, "compute", json("prefer" to it.workspaceId), workspaceField = true) }
    private var environment = ""
    private var name = ""
    private val environmentRow = SettingsRow(activity, null, activity.getString(R.string.ds_compute_environment))
    private val create = activity.actionRow(activity.getString(R.string.ds_compute_create)) {
        scope?.launch("compute.create", json("environment" to environment, "name" to name))
    }
    private val shell = SettingsSection(activity, activity.getString(R.string.ds_compute_new)).add(environmentRow)
        .add(activity.fieldRow(activity.getString(R.string.ds_models_name_optional)) { name = it }).add(create)
    private val list = SettingsSection(activity, activity.getString(R.string.ds_compute))

    init {
        layout.section(shell, top = 0)
        layout.section(list)
        feed?.follow()
        start { scope?.perform("compute.refresh", workspaceParameter = false) }
    }

    override fun render() {
        super.render()
        val feed = feed ?: return
        loading.isVisible = !feed.loaded
        val projection = feed.value?.optJSONObject("projection")
        shell.isVisible = projection?.optBoolean("can_manage") == true
        list.isVisible = projection != null
        if (projection == null) return
        val environments = projection.objects("environments").filter { it.optBoolean("can_create") }.mapNotNull { it.string("id") }
        environmentRow.choices(listOf<Pair<String, CharSequence>>("" to activity.getString(R.string.ds_compute_choose)) + environments.map { it to it },
            environment) { environment = it; render() }
        create.isEnabled = environment.isNotEmpty()
        val workloads = projection.objects("workloads")
        list.fill(workloads.map(::row).ifEmpty { listOf(activity.infoRow(activity.getString(R.string.ds_compute_none))) })
    }

    private fun row(workload: JSONObject): View {
        val id = workload.string("id")
        val title = workload.string("name") ?: id.orEmpty()
        val detail = (listOfNotNull(workload.string("phase") ?: workload.string("observed_state")) +
            workload.objects("uses").mapNotNull { it.string("label") ?: it.string("kind") } +
            listOfNotNull(workload.optJSONObject("problem")?.string("code"))).joinToString("\n")
        val actions = workload.optJSONObject("actions")
        val generation = workload.int("generation")
        val menu = surf.comma.android.ui.ActionMenu(activity)
        if (id != null && actions?.optBoolean("rename") == true) menu.item(activity.getString(R.string.ds_rename)) {
            FieldDialog(activity, activity.getString(R.string.ds_compute_rename), activity.getString(R.string.ds_name), workload.string("name").orEmpty(),
                activity.getString(R.string.settings_save), InputType.TYPE_CLASS_TEXT, 100,
                onSave = { scope?.launch("compute.rename", json("id" to id, "name" to it)) }, keyboard = true).show()
        }
        if (id != null && generation != null && actions?.optBoolean("retry") == true) menu.item(activity.getString(R.string.ds_compute_retry)) {
            scope?.launch("compute.retry", json("id" to id, "generation" to generation))
        }
        if (id != null && generation != null && actions?.optBoolean("delete") == true) menu.divider().item(activity.getString(R.string.ds_compute_delete), destructive = true) {
            // The deletion names the generation shown, so the server refuses it for a workload that changed since.
            ConfirmDialog(activity, activity.getString(R.string.ds_compute_delete_title), activity.getString(R.string.ds_compute_delete_message),
                activity.getString(R.string.ds_compute_delete), destructive = true) {
                scope?.launch("compute.delete", json("id" to id, "generation" to generation))
            }.show()
        }
        val more = if (menu.isEmpty) null else activity.moreButton(activity.getString(R.string.ds_requests_manage, title)) { menu.show(it) }
        return activity.describedRow(title, detail, control = more)
    }

    companion object { const val KEY = "compute" }
}

/**
 * My devices > View screen, and a device of Simulators and devices: the screen over the mesh ([MeshScreenView]),
 * decoded onto a surface. Leaving the page or the app stops viewing.
 */
internal class ScreenPage(
    ctx: SettingsContext,
    private val device: String,
    /** `display`, or a device the station lists. */
    private val target: String = "display",
    private var instance: String? = null,
    title: String? = null,
    /** Starts viewing at once (a measured run's entry, a debug build's SettingsActivity extras). */
    startsAtOnce: Boolean = false,
) : WorkspacePage(ctx, R.string.ds_screen, "screen", titleText = title) {
    private val isDevice = target != "display"
    private var control = isDevice
    private var open: MeshScreenView? = null
    private var viewing: Job? = null
    private val controlRow = SwitchRow(activity, activity.getString(R.string.ds_screen_control)) { on ->
        val current = open
        if (current == null) { control = on; render() } else current.control(on)
    }
    private val toggle = activity.actionRow(activity.getString(R.string.ds_screen_start)) { if (open != null) stopViewing() else startViewing() }
    private val home = activity.actionRow(activity.getString(R.string.ds_screen_home)) { open?.home() }
    private val phaseRow = activity.infoRow(activity.getString(R.string.ds_screen_connection))
    private val picture = ScreenSurface(activity)
    private val frame = FrameLayout(activity).apply {
        minimumHeight = activity.dp(250)
        clipToRoundedBackground(activity.dp(16).toFloat())
        contentDescription = activity.getString(R.string.ds_screen_viewport)
        addView(picture, FrameLayout.LayoutParams(-1, activity.dp(if (isDevice) 480 else 320)))
    }
    private val pause = object : DefaultLifecycleObserver {
        override fun onStop(owner: LifecycleOwner) = stopViewing()
    }

    init {
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_screen))
            .add(controlRow.row).add(toggle).add(home).add(phaseRow), top = 0)
        layout.section(frame)
        activity.lifecycle.addObserver(pause)
        loading.isVisible = false
        start()
        // Holds the workspace's stations while the page is open: the core links the computer's station only then.
        scope?.work?.launch { scope.core.subscribe(json("topic" to "stations", "workspace" to scope.workspaceId)) { it }.collect {} }
        if (startsAtOnce) scope?.work?.launch {
            // A device's running instance, as its list says, when the entry did not give one.
            if (isDevice && instance == null) {
                val listed = runCatching { scope.call("devices.listScreens", json("device" to device)) as? JSONObject }.getOrNull()
                instance = listed?.objects("screens")?.firstOrNull { it.string("id") == target }?.string("instance")
            }
            startViewing()
        }
    }

    override fun onClose() {
        activity.lifecycle.removeObserver(pause)
        stopViewing()
    }

    override fun render() {
        super.render()
        val state = open?.state
        // A computer's screen is watched or driven as chosen before it opens; a device's while an agent drives it.
        controlRow.row.isVisible = !isDevice || state?.agent == true
        controlRow.set(state?.control ?: control, enabled = open == null || state?.agent == true)
        toggle.title.text = activity.getString(if (open != null) R.string.ds_screen_stop else R.string.ds_screen_start)
        home.isVisible = target.startsWith("simulator:") && open != null
        home.isEnabled = state?.control == true
        phaseRow.isVisible = state != null
        phaseRow.value(state?.let {
            activity.getString(when (it.phase) {
                MeshScreenState.Phase.LIVE -> R.string.ds_connected
                MeshScreenState.Phase.FAILED -> R.string.ds_screen_failed
                MeshScreenState.Phase.CONNECTING -> R.string.ds_screen_connecting
            })
        })
        frame.isVisible = open != null
        picture.show(state)
        // The page's whole width, as tall as the picture's shape asks (a computer's wide, a phone's tall).
        if (state != null && state.width > 0 && state.height > 0 && frame.width > 0) {
            val height = (frame.width.toLong() * state.height / state.width).toInt()
            if (picture.layoutParams.height != height) picture.layoutParams = picture.layoutParams.apply { this.height = height }
        }
    }

    private fun startViewing() {
        val scope = scope ?: return
        if (open != null || !scope.current) return
        scope.error = null
        // A debug build with `screen-busy` in its files dir (adb) keeps the core busy while it shows, for a measured run.
        val busy = surf.comma.android.BuildConfig.DEBUG &&
            java.io.File(activity.getExternalFilesDir(null), "screen-busy").exists()
        // And with `screen-json`, takes the pictures as JSON progress, as before the core handed them over.
        val asProgress = surf.comma.android.BuildConfig.DEBUG &&
            java.io.File(activity.getExternalFilesDir(null), "screen-json").exists()
        val next = MeshScreenView(scope, device, target, instance, control, busy, asProgress) { state ->
            if (state.phase == MeshScreenState.Phase.FAILED) {
                scope.error = if (state.unreachable) PageError.Text(R.string.ds_screen_unreachable)
                    else state.failure?.let { PageError.Message(it) }
            }
            render()
        }
        open = next
        picture.attach(next)
        viewing = scope.work.launch { next.run() }
        render()
    }

    private fun stopViewing() {
        val closing = open ?: return
        open = null
        viewing?.cancel()
        viewing = null
        picture.attach(null)
        closing.attach(null)
        render()
    }
}

/** The picture of a view: its decoder's surface, sized to the picture's shape, and the touches on it as its shares. */
@SuppressLint("ViewConstructor")
private class ScreenSurface(context: android.content.Context) : FrameLayout(context) {
    private val surface = SurfaceView(context)
    private val finger = View(context).apply {
        background = android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.OVAL
            setColor(Color.argb(90, 255, 255, 255))
        }
        isVisible = false
    }
    private var view: MeshScreenView? = null
    private var shape = 0f

    init {
        addView(surface, LayoutParams(-1, -1, android.view.Gravity.CENTER))
        addView(finger, LayoutParams(context.resources.displayMetrics.density.times(28).toInt(), context.resources.displayMetrics.density.times(28).toInt()))
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) { view?.attach(holder.surface) }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) { view?.attach(null) }
        })
        @SuppressLint("ClickableViewAccessibility")
        surface.setOnTouchListener { touched, event ->
            val kind = when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> "down"
                MotionEvent.ACTION_MOVE -> "move"
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> "up"
                else -> return@setOnTouchListener false
            }
            view?.touch(kind, event.x / touched.width.coerceAtLeast(1), event.y / touched.height.coerceAtLeast(1))
            true
        }
    }

    fun attach(next: MeshScreenView?) {
        view = next
        if (next != null && surface.holder.surface.isValid) next.attach(surface.holder.surface)
    }

    /** Fits the surface to the picture's shape, and draws the agent's finger where it presses. */
    fun show(state: MeshScreenState?) {
        val ratio = if (state != null && state.width > 0 && state.height > 0) state.width.toFloat() / state.height else 0f
        if (ratio != shape) {
            shape = ratio
            requestLayout()
        }
        val at = state?.agentPointer
        finger.isVisible = at != null
        if (at != null) {
            finger.translationX = surface.left + at.first * surface.width - finger.width / 2f
            finger.translationY = surface.top + at.second * surface.height - finger.height / 2f
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        val width = right - left
        val height = bottom - top
        if (shape <= 0f || width == 0 || height == 0) return
        val fitted = if (width.toFloat() / height > shape) (height * shape).toInt() to height else width to (width / shape).toInt()
        val x = (width - fitted.first) / 2
        val y = (height - fitted.second) / 2
        surface.layout(x, y, x + fitted.first, y + fitted.second)
    }
}

/**
 * My devices > Simulators and devices: the iOS Simulators and Android devices a computer runs, as its station lists
 * them over the mesh (`devices.listScreens`), each opened on its own page. Read again every 5 s while shown, as the
 * desktop's list is: a person has few computers, and a read is one request.
 */
internal class ScreenDevicesPage(ctx: SettingsContext, private val device: String) :
    WorkspacePage(ctx, R.string.ds_screen_devices, "screen-devices") {
    private val list = SettingsSection(activity, activity.getString(R.string.ds_screen_devices))
    private var screens: List<JSONObject> = emptyList()
    private var read = false

    init {
        layout.section(list, top = 0)
        start()
        scope?.work?.launch {
            // Holds the workspace's stations meanwhile, which keeps the mesh's link to the computer.
            val held = launch { scope.core.subscribe(json("topic" to "stations", "workspace" to scope.workspaceId)) { it }.collect {} }
            try {
                while (true) {
                    try {
                        val listed = scope.call("devices.listScreens", json("device" to device)) as? JSONObject
                        screens = listed?.objects("screens").orEmpty()
                        scope.error = listed?.string("unavailable")?.let { PageError.Message(it) }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        scope.error = WorkspaceScope.describe(e)
                    }
                    read = true
                    render()
                    delay(5_000)
                }
            } finally {
                held.cancel()
            }
        }
    }

    override fun render() {
        super.render()
        loading.isVisible = !read
        list.isVisible = read
        list.fill(screens.mapNotNull(::row).ifEmpty { listOf(activity.infoRow(activity.getString(R.string.ds_screen_devices_none))) })
    }

    private fun row(screen: JSONObject): View? {
        val id = screen.string("id") ?: return null
        val instance = screen.string("instance") ?: return null
        val title = screen.string("title") ?: screen.string("name") ?: id
        return SettingsRow(activity, null, title).value(null, chevron = true)
            .onClick { ctx.open(ScreenPage(ctx, device, id, instance, title)) }
    }
}
