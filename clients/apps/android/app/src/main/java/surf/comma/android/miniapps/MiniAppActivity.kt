package surf.comma.android.miniapps

import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.core.CoreError
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.text
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.AppearanceStore
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.glyph
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.io.File

/**
 * The restricted runtime shared by the Apps tab, shared links and chat previews. Back suspends a run that can continue
 * and Close ends it. Publication stays in trusted host controls: the menu offers Publish while the build review of
 * the previewed Version still matches.
 */
class MiniAppActivity : ComponentActivity() {
    private lateinit var target: MiniAppTarget
    private lateinit var session: MiniAppSession
    /** The run this screen shows; Reload replaces it, and only its state is drawn. */
    private val current = MutableStateFlow<MiniAppSession?>(null)
    private var handle: String? = null
    private var host: MiniAppWebHost? = null
    private var management: MiniAppsModel? = null
    private var managementJobs: List<Job> = emptyList()
    private var consent: MiniAppConsentDialog? = null
    private var photos: MiniAppPhotoDialog? = null
    private var shownPhotoRequest: Long? = null
    private var hostDialog: MiniAppHostDialog? = null
    private var shownHostRequest: Long? = null
    private val device = MiniAppDevice(this)
    private var cameraFile: File? = null
    /** The system photo picker or camera this screen opened is over it; the run stays in the foreground. */
    private var picking = false
    private var closing = false

    private val root by lazy { FrameLayout(this).apply { setBackgroundColor(color(R.color.token_bg_primary)) } }
    private val content = lazy { FrameLayout(this) }
    private val header by lazy {
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(color(R.color.token_bg_primary))
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
    }
    private val title by lazy { text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply { maxLines = 1; gravity = Gravity.CENTER } }
    private val subtitle by lazy { text(Level.MINI, R.color.token_text_secondary).apply { gravity = Gravity.CENTER } }
    private val controls by lazy { controls() }
    private val status by lazy { text(Level.REGULAR, R.color.token_text_secondary).apply { gravity = Gravity.CENTER } }
    private var insets = WindowInsetsCompat.CONSUMED

    private val pickOne = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        picking = false
        picked(listOfNotNull(uri))
    }
    private val pickMany = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MiniAppPhotoRequest.MAX_PHOTOS)) {
        picking = false
        picked(it)
    }
    private val takePhoto = registerForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        picking = false
        val file = cameraFile
        cameraFile = null
        if (saved && file != null) picked(listOf(Uri.fromFile(file)), camera = file) else file?.delete()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle = intent.getStringExtra(EXTRA_HANDLE)
        // A run is never restored after the process or the account changed: nothing is replayed.
        val presented = MiniAppRuntimes.presented(handle)
        val core = AuthGraph.core(this)
        if (presented == null || core == null || AuthGraph.get(this).state.value !is AuthState.Connected) {
            finish()
            return
        }
        target = presented
        session = MiniAppRuntimes.retained(target) ?: MiniAppSession(core, target)
        current.value = session
        WindowCompat.setDecorFitsSystemWindows(window, false)
        buildViews()
        setContentView(root)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = suspendAndLeave()
        })
        target.conversationId?.let { conversation ->
            AuthGraph.get(this).let { auth ->
                val workspace = (auth.state.value as? AuthState.Connected)?.selection?.workspace ?: return@let
                management = MiniAppsModel(this, core, workspace, MiniAppRuntimes.currentScope())
            }
        }
        startRuntime()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                @OptIn(ExperimentalCoroutinesApi::class)
                launch { current.filterNotNull().flatMapLatest { run -> run.state.map { run to it } }.collect { (run, state) -> render(run, state) } }
                launch {
                    // Another account or Workspace ends the run: its page sends no more commands.
                    AuthGraph.get(this@MiniAppActivity).conversationScope.collect { scope ->
                        if (scope == null || !MiniAppRuntimes.isCurrent(scope, this@MiniAppActivity) || MiniAppRuntimes.presented(handle) == null) {
                            session.stop()
                            leave()
                        }
                    }
                }
            }
        }
        management?.let { model ->
            managementJobs = listOf(
                lifecycleScope.launch { model.followApp(target.appId) },
                // Ownership is known only once the app has loaded; the review is followed from then on.
                lifecycleScope.launch {
                    model.state.first { it.app != null }
                    model.followReview(target.conversationId)
                },
            )
        }
    }

    private fun buildViews() {
        val back = controls
        header.addView(back, LinearLayout.LayoutParams(-2, dp(44)))
        val titles = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(title, LinearLayout.LayoutParams(-1, -2))
            addView(subtitle, LinearLayout.LayoutParams(-1, -2))
        }
        header.addView(titles, LinearLayout.LayoutParams(0, -2, 1f))
        // Balances the controls so the title stays centred.
        header.addView(View(this), LinearLayout.LayoutParams(dp(89), dp(44)))
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(header, LinearLayout.LayoutParams(-1, -2))
        column.addView(content.value, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(column, FrameLayout.LayoutParams(-1, -1))
        root.addView(status, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER).apply { marginStart = dp(32); marginEnd = dp(32) })
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, next ->
            insets = next
            layoutChrome()
            WindowInsetsCompat.CONSUMED
        }
    }

    private fun controls(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        glass(radius = dp(22).toFloat())
        val back = glyph(R.drawable.ic_task_back).apply {
            id = R.id.mini_app_back
            contentDescription = getString(R.string.settings_back)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            tactile()
            setOnClickListener { suspendAndLeave() }
        }
        val menu = glyph(R.drawable.ic_action_more).apply {
            id = R.id.mini_app_menu
            contentDescription = getString(R.string.mini_app_menu)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            tactile()
            setOnClickListener { showMenu(it) }
        }
        addView(back, LinearLayout.LayoutParams(dp(44), dp(44)))
        addView(View(context).apply { setBackgroundColor(color(R.color.token_border_primary)) }, LinearLayout.LayoutParams(1, dp(20)))
        addView(menu, LinearLayout.LayoutParams(dp(44), dp(44)))
    }

    /** Immersive runs edge to edge with floating controls; otherwise a header holds them over the app. */
    private fun layoutChrome() {
        val immersive = session.immersive
        val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
        WindowInsetsControllerCompat(window, root).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (immersive) hide(WindowInsetsCompat.Type.systemBars()) else show(WindowInsetsCompat.Type.systemBars())
            val light = !AppearanceStore.isNight(this@MiniAppActivity)
            isAppearanceLightStatusBars = light
            isAppearanceLightNavigationBars = light
        }
        (controls.parent as? android.view.ViewGroup)?.removeView(controls)
        if (immersive) {
            header.isVisible = false
            root.addView(controls, FrameLayout.LayoutParams(-2, dp(44), Gravity.TOP or Gravity.START).apply {
                topMargin = bars.top + dp(12)
                marginStart = bars.left + dp(12)
            })
            content.value.setPadding(0, 0, 0, 0)
        } else {
            header.isVisible = true
            header.addView(controls, 0, LinearLayout.LayoutParams(-2, dp(44)))
            header.setPadding(dp(12) + bars.left, dp(8) + bars.top, dp(12) + bars.right, dp(8))
            content.value.setPadding(bars.left, 0, bars.right, bars.bottom)
        }
    }

    private fun startRuntime() {
        MiniAppRuntimes.retain(session)
        session.device = device
        lifecycleScope.launch {
            session.open()
            session.resume()
            attachRuntime()
        }
    }

    /** Uses the retained WebView of a continued run, or starts one once the member approved cloud access. */
    private fun attachRuntime() {
        if (!session.canRun) return
        val existing = session.runtime as? MiniAppWebHost
        val runtime = existing ?: try {
            MiniAppWebHost(this, session, dark()).also { session.runtime = it }
        } catch (error: Exception) {
            session.failed(CoreError("unavailable", getString(R.string.mini_app_webview_missing)))
            return
        }
        runtime.detach()
        runtime.attach(this)
        host = runtime
        content.value.addView(runtime.webView, 0, FrameLayout.LayoutParams(-1, -1))
        if (existing == null) runtime.load() else runtime.updateTheme(dark())
    }

    private fun render(run: MiniAppSession, state: MiniAppSession.State) {
        if (run !== session) return
        title.text = state.name ?: getString(R.string.mini_apps_app)
        subtitle.text = state.version?.let { "v$it" }.orEmpty()
        subtitle.isVisible = state.version != null
        status.text = when {
            state.failure != null -> getString(R.string.mini_app_unavailable) + "\n" + state.failure
            !state.ready && !state.needsConsent -> getString(R.string.mini_app_loading)
            else -> null
        }
        status.isVisible = !status.text.isNullOrEmpty()
        if (state.needsConsent && consent == null) {
            consent = MiniAppConsentDialog(this, run = {
                consent = null
                if (run === session) {
                    run.approve()
                    attachRuntime()
                }
            }, cancel = {
                if (run === session) {
                    consent = null
                    MiniAppRuntimes.close(run)
                    leave()
                }
            }).also { it.show() }
        }
        if (state.running && host == null && !closing) attachRuntime()
        if (!state.running && host != null && state.failure != null) {
            host = null
        }
        val host = state.hostRequest
        if (host?.id != shownHostRequest) {
            hostDialog?.dismiss()
            hostDialog = null
            shownHostRequest = host?.id
            if (host != null) hostDialog = MiniAppHostDialog(this, state.name ?: getString(R.string.mini_apps_app), host,
                allow = { run.finishHostRequest(host.id, approved = true) },
                cancel = { run.finishHostRequest(host.id, approved = false) }).also { it.show() }
        }
        val request = state.photoRequest
        if (request?.id != shownPhotoRequest) {
            photos?.dismiss()
            photos = null
            shownPhotoRequest = request?.id
            if (request != null) photos = MiniAppPhotoDialog(this, state.name ?: getString(R.string.mini_apps_app),
                share = { run.finishPhotoRequest(request.id, it) },
                choose = {
                    val media = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    picking = true
                    if (request.request.multiple) pickMany.launch(media) else pickOne.launch(media)
                },
                camera = ::openCamera,
                cancel = { run.cancelPhotoRequest(request.id) }).also { it.show() }
        }
    }

    private fun openCamera() {
        val directory = File(cacheDir, "mini-app-camera").apply { mkdirs() }
        val file = File.createTempFile("photo", ".jpg", directory)
        cameraFile = file
        picking = true
        runCatching { takePhoto.launch(FileProvider.getUriForFile(this, "$packageName.composer.files", file)) }
            .onFailure {
                picking = false
                file.delete()
                photos?.showFailure(getString(R.string.mini_app_photo_camera_unavailable))
            }
    }

    /** Encodes what the member picked off the main thread, then shows it in the confirmation. */
    private fun picked(uris: List<Uri>, camera: File? = null) {
        if (uris.isEmpty()) return
        val request = session.state.value.photoRequest?.request ?: return
        lifecycleScope.launch {
            val encoded = withContext(Dispatchers.IO) {
                runCatching { uris.take(request.limit).map { MiniAppPhotoEncoding.encode(contentResolver, it, request.png) } }
                    .also { camera?.delete() }
            }
            val dialog = photos ?: return@launch
            encoded.onSuccess { list ->
                if (list.sumOf { it.data.size } > MiniAppPhotoRequest.MAX_TOTAL_BYTES) dialog.showFailure(getString(R.string.mini_app_photo_too_large))
                else dialog.showPhotos(list)
            }.onFailure { dialog.showFailure(getString(R.string.mini_app_photo_failed)) }
        }
    }

    private fun showMenu(anchor: View) {
        val state = session.state.value
        val menu = ActionMenu(this)
        menu.item(state.name ?: getString(R.string.mini_apps_app), enabled = false) {}
        state.version?.let { menu.item("v$it", enabled = false) {} }
        menu.divider()
        menu.item(getString(R.string.mini_app_immersive), checked = session.immersive) {
            session.immersive = !session.immersive
            layoutChrome()
        }
        menu.item(getString(R.string.mini_app_reload), action = ::reload)
        publication()?.let { publication ->
            menu.item(getString(R.string.mini_app_publish)) { management?.let { MiniAppPublishDialog(this, it, publication).show() } }
        }
        menu.divider()
        menu.item(getString(R.string.mini_app_close), destructive = true) {
            MiniAppRuntimes.close(session)
            leave()
        }
        menu.show(anchor)
    }

    private fun publication(): MiniAppPublication? {
        val model = management ?: return null
        if (!session.state.value.ready) return null
        val version = model.state.value.versions.firstOrNull { it.number == target.version } ?: return null
        return model.publication(version)
    }

    private fun reload() {
        val immersive = session.immersive
        host?.let { content.value.removeView(it.webView) }
        host = null
        MiniAppRuntimes.close(session)
        val core = AuthGraph.core(this) ?: return leave()
        session = MiniAppSession(core, target).also { it.immersive = immersive }
        consent?.dismiss()
        consent = null
        photos?.dismiss()
        photos = null
        shownPhotoRequest = null
        hostDialog?.dismiss()
        hostDialog = null
        shownHostRequest = null
        current.value = session
        startRuntime()
    }

    private fun suspendAndLeave() {
        session.suspend()
        MiniAppRuntimes.suspended()
        leave()
    }

    private fun leave() {
        if (closing) return
        closing = true
        finish()
    }

    private fun dark() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        host?.updateTheme(dark())
    }

    override fun onStart() {
        super.onStart()
        if (::session.isInitialized && !closing) session.resume()
    }

    override fun onStop() {
        // Backgrounding requires the member to open the app again; the run waits suspended. The member's own photo
        // choice is not backgrounding.
        if (::session.isInitialized && !isFinishing && !picking) {
            session.suspend()
            MiniAppRuntimes.suspended()
        }
        super.onStop()
    }

    override fun onDestroy() {
        managementJobs.forEach(Job::cancel)
        device.release()
        if (::session.isInitialized) {
            if (session.device === device) session.device = null
            host?.detach()
            // A screen the system recreates (a configuration change, or reclaimed behind the photo picker or camera)
            // keeps its handle and run, and shows them again.
            if (isFinishing) {
                // A run that cannot continue (refused, failed, closed) ends with its screen.
                if (!session.canContinue || !session.isSuspended) MiniAppRuntimes.close(session)
                MiniAppRuntimes.forget(handle)
            }
        }
        super.onDestroy()
    }

    companion object {
        const val EXTRA_HANDLE = "miniApp.handle"
    }
}
