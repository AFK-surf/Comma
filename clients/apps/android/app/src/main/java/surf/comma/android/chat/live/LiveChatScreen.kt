package surf.comma.android.chat.live

import android.content.res.Configuration
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.widget.FrameLayout
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import androidx.core.view.isVisible
import androidx.core.view.doOnPreDraw
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import surf.comma.android.BuildConfig
import surf.comma.android.R
import surf.comma.android.platform.logging.AppLog
import surf.comma.android.auth.AuthGraph
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskGraph
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.UiSansTypeface
import surf.comma.android.tasks.ui.TaskRefCardLayout
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.auth.AuthState
import surf.comma.android.voice.CallController
import surf.comma.android.voice.CallControllerState
import surf.comma.android.voice.ui.CallLog
import surf.comma.android.voice.ui.CallLogStore
import surf.comma.android.voice.ui.CallPresentation
import surf.comma.android.voice.ui.VoiceAvailability
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageActionLabels
import surf.comma.android.chat.render.codeLabels
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.codeSyntaxTheme
import surf.comma.android.conversation.AgentRequest
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.ConversationState
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.ui.connection.ConnectionRetryTarget
import surf.comma.android.ui.connection.connectionAvailability
import surf.comma.android.ui.connection.mountConnectionError
import surf.comma.android.ui.MessageActionsPopup
import surf.comma.android.media.*
import surf.comma.android.media.viewer.ChatMediaLink
import surf.comma.android.media.viewer.ImageViewerActivity
import java.io.File
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.ui.composer.DictationFailure
import surf.comma.android.ui.composer.message
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.widget.BackdropBlurLayout
import surf.comma.android.ui.widget.LiquidGlass
import kotlin.coroutines.resume
import kotlin.math.roundToInt

/**
 * The main chat: the conversation data layer on the timeline, with the composer at the bottom.
 *
 * Each published state is mapped and laid out off the main thread; the main thread only submits
 * the prepared rows, which the list diffs by stable id. A new state is taken only after the
 * previous one has been committed, so bursts of streaming updates collapse into one list update
 * per commit.
 */
class LiveChatScreen(
    private val activity: ComponentActivity,
    private val repository: ChatView,
    private val session: StateFlow<AuthState>,
    private val retrySession: suspend () -> Unit,
    /** The connection error page's way to the account (settings). */
    private val onOpenAccount: () -> Unit,
    /** The top bar's Call button: start a call, or open the one in progress. */
    private val onCall: () -> Unit = {},
    /** Whether the workspace can take voice calls; null when it could not be told. */
    private val voiceReady: suspend () -> Boolean? = { null },
    /** Called once, when the first conversation content has been drawn. */
    private val onFirstContent: () -> Unit = {},
    /** The router chat over the tabs: the compact top bar, whose left button closes the chat ([onOpenSidebar]). */
    router: Boolean = false,
    /**
     * Whose lifetime the screen's work follows: the activity for the router chat, a shorter one for a Task's chat,
     * whose work ends when its dock closes.
     */
    private val owner: androidx.lifecycle.LifecycleOwner = activity,
    /** A Task's conversation in its dock: no top bar of its own, the dock's header stands over the list instead. */
    private val embedded: Boolean = false,
    /** The process's media components, which a test may replace. */
    private val media: MediaComponents = MediaGraph.get(activity),
    /** The process's task data and the session it is read under, which a test may replace. */
    taskData: ServerTaskRepository = TaskGraph.get(activity, AuthGraph.get(activity)),
    taskSessions: StateFlow<Any?> = AuthGraph.get(activity).conversationScope,
) {
    private val density = activity.resources.displayMetrics.density
    val root = FrameLayout(activity).apply { setBackgroundColor(activity.getColor(R.color.token_bg_primary)) }
    private val timeline = ChatTimelineView(activity).apply {
        id = R.id.conversation_timeline
        clipToPadding = false
        drawsBehindComposer = true
    }
    private val topBar = HomeTopBar(activity, compact = router)
    /** Under the top bar while the connection has been lost for a while. */
    private val notice = ConnectionNoticeView(activity)
    private val noticeTick: Runnable = Runnable { connection.tick() }
    private val connection: ConnectionNoticeController = ConnectionNoticeController(
        clock = SystemClock::uptimeMillis,
        wakeIn = { delay ->
            notice.removeCallbacks(noticeTick)
            notice.postDelayed(noticeTick, delay)
        },
        onChanged = notice::show,
        onRetry = { target ->
            when (target) {
                ConnectionRetryTarget.SESSION -> owner.lifecycleScope.launch { retrySession() }
                ConnectionRetryTarget.CONVERSATION -> repository.reconnect()
            }
        },
        onNetworkChanged = repository::networkChanged,
    )
    /** Frosts the list beneath the top bar and the floating composer. */
    private val body = BackdropBlurLayout(activity)
    private val composer = ComposerView(activity)
    private val flight = SendFlightView(activity, timeline)
    private val scrollToLatest = ScrollToLatestButton(activity)
    private var localPreviews = emptyMap<MediaSource, ViewerImage.Local>()
    private val frozenSizes = mutableMapOf<MediaSource, ImageDimensions>()
    private var geometrySession: MediaSessionId? = null
    private val preprocessor = AndroidImagePreprocessor(activity.contentResolver, File(activity.cacheDir, "outgoing-media"))
    private val draft = ChatImageDraft(media.http, preprocessor, AndroidPickedFileRefs(activity.contentResolver),
        owner.lifecycleScope, repository,
        ViewModelProvider(activity)[DraftAttachmentPreviews::class.java]) { image, local, captured ->
        val images = media.images()
        if (media.http.isCurrent(captured)) {
            images.remember(image, captured)
            if (media.http.isCurrent(captured)) {
                localPreviews = (localPreviews + (MediaSource.UploadedFile(image.path) to local))
                    .entries.toList().takeLast(100).associate { it.key to it.value }
            }
        }
    }
    private var uploadBinding: kotlinx.coroutines.Job? = null
    /** The images added to question cards' other answers, apart from the composer's draft. */
    private val questionImages = QuestionImages(media.http, preprocessor, owner.lifecycleScope, repository) {
        Toast.makeText(activity, R.string.chat_question_upload_failed, Toast.LENGTH_SHORT).show()
    }
    /** What the Agent's question cards do here: answer through the core, add images through the composer's picker. */
    private val questions = object : QuestionCardHost {
        override val forms = QuestionForms()

        override fun answer(questionMessageId: String, answer: QuestionCardAnswer, done: (Boolean) -> Unit) {
            owner.lifecycleScope.launch {
                done(repository.answerQuestion(questionMessageId, answer.choiceIds, answer.other, answer.skipped))
            }
        }

        override fun pickImages(questionMessageId: String, remaining: Int) =
            composer.pickQuestionImages(questionMessageId, remaining)

        override fun addImages(questionMessageId: String, uris: List<android.net.Uri>) = questionImages.add(questionMessageId, uris)

        override fun removeImage(questionMessageId: String, attachmentId: String) =
            questionImages.remove(questionMessageId, attachmentId)

        override fun retryImage(questionMessageId: String, attachmentId: String) =
            questionImages.retry(questionMessageId, attachmentId)
    }
    private val deviceLocation = DeviceLocation(activity)
    private val locationAnswers = AgentLocationAnswers.of(activity)

    /** What the Agent's request cards do here: open the provider's page in the browser, decline through the core. */
    private val requests = object : AgentRequestCardHost {
        override val opened = HashSet<String>()

        override fun answeringLocation(requestId: String) = locationAnswers.answering(requestId)

        override fun watchLocationAnswers(changed: () -> Unit) = locationAnswers.watch(changed)

        override fun authorize(url: String) {
            runCatching {
                activity.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
            }
        }

        override fun decline(requestId: String, done: (Boolean) -> Unit) {
            owner.lifecycleScope.launch { done(repository.declineRequest(requestId)) }
        }

        override fun fill(request: AgentRequest, done: (Boolean) -> Unit) {
            AgentRequestFillDialog(activity, request) { values ->
                owner.lifecycleScope.launch { done(repository.fillRequest(request.id, values)) }
            }.show()
        }

        override fun shareLocation(requestId: String, done: (AgentLocationAnswer) -> Unit) {
            deviceLocation.read { position ->
                when (position) {
                    DeviceLocation.Reading.Denied -> done(AgentLocationAnswer.DENIED)
                    DeviceLocation.Reading.Unavailable -> done(AgentLocationAnswer.UNAVAILABLE)
                    is DeviceLocation.Reading.At -> owner.lifecycleScope.launch {
                        val taken = repository.shareLocation(requestId, position.latitude, position.longitude, position.accuracy)
                        done(if (taken) AgentLocationAnswer.TAKEN else AgentLocationAnswer.FAILED)
                    }
                }
            }
        }
    }
    private val precomputer = MessageLayoutPrecomputer(
        cardHeights = TaskRefCardLayout(TaskTheme(activity), activity.getString(R.string.chat_task_ref), UiSansTypeface)
            .then(QuestionCardLayout(activity, interactive = true))
            .then(AgentRequestCardLayout(activity)),
        bubbles = true,
    )
    private val palette = ChatPalette.from(activity)
    private val syntax = codeSyntaxTheme(activity)
    private val labels = LiveLabels(
        task = activity.getString(R.string.chat_task_ref),
        taskUnavailable = activity.getString(R.string.chat_task_unavailable),
        interactiveUnavailable = activity.getString(R.string.chat_interactive_unavailable),
        file = activity.getString(R.string.chat_file),
        replyErrorTitle = activity.getString(R.string.chat_reply_error_title),
        replyErrorDetail = activity.getString(R.string.chat_reply_error_detail),
        historyGap = activity.getString(R.string.chat_history_gap),
    )
    private val actionLabels = MessageActionLabels(
        retry = activity.getString(R.string.chat_retry),
        discard = activity.getString(R.string.chat_delete),
        sendFailedNote = activity.getString(R.string.chat_send_failed_note),
    )
    private val codeHeaderLabels = codeLabels(activity)
    private val failedSends = FailedSendActions(
        requestIdFor = { retryTargets[it] },
        retry = { id -> owner.lifecycleScope.launch { repository.retry(id) } },
        delete = { id -> owner.lifecycleScope.launch { repository.discard(id) } },
    )
    private val tasks = ChatTasks(activity, owner, cardRefs = if (embedded) "chat#cards#${System.identityHashCode(this)}" else "chat#cards",
        sessions = taskSessions, repository = taskData)
    private val sendFlow = ChatSendFlow(owner.lifecycleScope, composer, timeline, flight,
        draftRequestId = { draft.requestId },
        sendDraft = { text, attachments -> draft.send(text, attachments, triggerMenu.skillLocations(text)) },
        onRefused = { Toast.makeText(activity, R.string.chat_send_not_ready, Toast.LENGTH_SHORT).show() },
    )
    private val workspace = surf.comma.android.workspace.WorkspaceGraph.get(activity)
    private val triggerMenu = TriggerMenu(activity, composer.field, isRouter = !embedded,
        tasks = { workspace.tasks.state.value.snapshot.tasks },
        skills = { workspace.skills.value },
        excludedTaskId = { if (embedded) repository.state.value.conversationId else null },
        onNeedSkills = workspace::loadSkills,
        models = { workspace.models.value },
        onNeedModels = workspace::loadModels,
    )
    private val draftText = ChatDraftText(composer.field, repository, triggerMenu, owner.lifecycleScope, composer::cancelDictation)
    private val calls = CallController.get(activity)
    private val callLog = CallLogStore(activity)
    /** Bumped when a call is logged, so the timeline lays out again with its row. */
    private val callLogVersion = MutableStateFlow(0)
    private var followNewCall = false
    private var voiceAvailable = false
    private var prepared: List<PreparedChatMessage> = emptyList()
    private var lastState: ConversationState? = null
    private var retryTargets: Map<Long, String> = emptyMap()
    private var entryRows: Map<String, Long> = emptyMap()
    private var rowEntries: Map<Long, String> = emptyMap()
    /** An entry to scroll to once it is on the list, and until when to keep waiting for it. */
    private var pendingReveal: Pair<String, Long>? = null
    /** The follow-ups shown for the settled turn, read only while the chat is on screen. */
    private val suggestions = MutableStateFlow<List<ChatSuggestion>>(emptyList())
    /** The turn and language [suggestions] are for, and the one a chosen or accepted suggestion closed. */
    private var suggestionKey: String? = null
    private var dismissedSuggestionKey: String? = null
    private var suggestionWatch: kotlinx.coroutines.Job? = null

    /** The top bar's sidebar button; the home that holds the sidebar sets it. */
    var onOpenSidebar: (() -> Unit)? = null

    /** Opens the remote browser of the conversation's participant; unset, the bar offers none. */
    var onOpenBrowser: ((participant: String) -> Unit)? = null

    private fun showBrowserButton(state: ConversationState) {
        val shown = onOpenBrowser != null && !state.participant?.participantId.isNullOrEmpty()
        if (shown == topBar.browserButton.isVisible) return
        topBar.setBrowser(shown)
        updateChromePatches()
    }

    /** A task card in the transcript was tapped; unset, the task opens as a full page. */
    var onOpenTaskCard: ((taskId: String, known: TaskSummary?) -> Unit)?
        get() = tasks.onOpenCard
        set(value) {
            tasks.onOpenCard = value
        }

    init {
        // The top chrome floats over the list the way the composer floats over its bottom, with
        // the list reaching up behind the status bar. Its height is the list's top inset, so a
        // resting conversation starts below it; [updateTopInset] follows it as it changes.
        bindTopBar()
        body.addView(timeline, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        root.addView(body, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        root.addView(topBar, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP))
        root.addView(notice, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL,
        ))
        composer.attachTo(root)
        root.addView(scrollToLatest, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
        ))
        root.addView(triggerMenu.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM).apply {
            marginStart = (16 * density).toInt(); marginEnd = (16 * density).toInt()
        })
        (triggerMenu.view.layoutParams as FrameLayout.LayoutParams).height = FrameLayout.LayoutParams.WRAP_CONTENT
        triggerMenu.view.minimumHeight = 0
        tasks.attach(timeline)
        root.addView(flight, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        mountConnectionError(activity, root, repository, session, retrySession, onOpenAccount, owner)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            // The backdrop reaches both screen edges, including beneath the system navigation bar.
            view.setPadding(bars.left, 0, bars.right, 0)
            topBar.setStatusBarInset(bars.top)
            // Before the first layout, so a cold start never places a message under the chrome.
            if (!embedded && !topBar.isLaidOut) updateTopInset(topBar.heightFor(bars.top))
            insets
        }
        bindTimeline()
        bindComposer()
        if (embedded) topBar.visibility = android.view.View.GONE
    }

    /** In a Task's dock: the header over the list is [px] tall, which the list starts below. */
    fun setTopChrome(px: Int) {
        updateTopInset(px)
        (notice.layoutParams as FrameLayout.LayoutParams).let { if (it.topMargin != px) { it.topMargin = px; notice.layoutParams = it } }
    }

    /** Starts following the conversation for as long as [activity] is started. */
    fun bind() {
        owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                session.collect { renderConnection(lastState) }
            }
        }
        owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                connectionAvailability(activity).collect(connection::connectivityChanged)
            }
        }
        owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                awaitLaidOut()
                // A StateFlow collector that is still rendering skips to the newest state.
                combine(repository.state, callLogVersion, questionImages.shown, repository.requests,
                    combine(tasks.known, suggestions) { _, _ -> }) { state, _, _, _, _ -> state }.collect(::render)
            }
        }
        owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                try {
                    combine(repository.state, repository.shown) { state, shown -> state.takeIf { shown } }.collect(::updateSuggestions)
                } finally {
                    updateSuggestions(null)
                }
            }
        }
        owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                calls.state.collect { call ->
                    topBar.setCall(available = voiceAvailable, live = call.busy)
                    updateChromePatches()
                    logCall(call)
                }
            }
        }
        owner.lifecycleScope.launch {
            // Read once per signed-in workspace and process, never with a call credential; what
            // was read last shows meanwhile.
            session.collect { state ->
                val connected = state as? AuthState.Connected
                val key = connected?.let { "${it.account.id}/${it.selection.workspace.id}" }
                voiceAvailable = when (state) {
                    is AuthState.Login, AuthState.Unconfigured -> false
                    else -> VoiceAvailability.cached(activity, key)
                }
                showCallButton()
                if (key != null && VoiceAvailability.refreshedKey != key) {
                    val answer = voiceReady()
                    if (BuildConfig.DEBUG) AppLog.info("VoiceAvailability", "ready=$answer")
                    if (answer != null && session.value == state) {
                        VoiceAvailability.remember(activity, key, answer)
                        voiceAvailable = answer
                        showCallButton()
                    }
                }
            }
        }
        tasks.bind()
        // An open / menu fills in once the workspace's skills arrive.
        owner.lifecycleScope.launch { workspace.skills.collect { if (triggerMenu.view.visibility == android.view.View.VISIBLE) triggerMenu.refresh() } }
        // An open @ menu in the router chat fills in once the workspace's models arrive.
        if (!embedded) owner.lifecycleScope.launch {
            workspace.models.collect { if (triggerMenu.view.visibility == android.view.View.VISIBLE) triggerMenu.refresh() }
        }
    }

    private fun showCallButton() {
        topBar.setCall(available = voiceAvailable, live = calls.state.value.busy)
        updateChromePatches()
    }

    /** A finished call that connected goes into the conversation it was made from, once. */
    private fun logCall(call: CallControllerState) {
        if (embedded) return
        val conversationId = repository.state.value.conversationId ?: return
        if (!callLog.logFinished(conversationId, call, SystemClock.elapsedRealtime(), System.currentTimeMillis())) return
        // The call's row is the newest thing said: bring it into view like a sent message.
        followNewCall = true
        callLogVersion.value++
    }

    fun release() {
        if (ChatMediaLink.reveal == timeline::revealMediaRow) ChatMediaLink.reveal = null
        notice.removeCallbacks(noticeTick)
        sendFlow.release()
        composer.cancelDictation()
        draftText.release()
        uploadBinding?.cancel()
        draft.close()
        localPreviews = emptyMap()
        tasks.release()
        timeline.release()
    }

    private suspend fun render(state: ConversationState) {
        if (!repository.isCurrent(state)) return
        showBrowserButton(state)
        val captured = media.http.session.value
        if (geometrySession != captured?.id) {
            frozenSizes.clear()
            localPreviews = emptyMap()
            geometrySession = captured?.id
        }
        val images = media.images()
        val covers = media.covers()
        val previews = localPreviews
        val conversationId = state.conversationId.orEmpty()
        val callRecords = if (conversationId.isEmpty()) emptyList() else callLog.records(conversationId)
        val questionShown = questionImages.shown.value
        // Requests read for another conversation or account are not this one's.
        val shownRequests = repository.requests.value.takeIf { it.scope === state.scope && it.conversationId == state.conversationId }
            ?.requests.orEmpty()
        val knownTasks = tasks.known.value
        val mapped = withContext(Background.compute) {
            mapConversation(state, labels, questionImages = questionShown, requests = shownRequests, tasks = knownTasks) { attachment ->
                val source = attachment.file.source
                if (source == null || attachment.display == AttachmentDisplay.FILE) attachment.copy(session = captured?.id) else {
                    val dimensions = frozenSizes.getOrPut(source) {
                        attachment.dimensions ?: images.dimensions(source) ?:
                        captured?.let { covers.dimensions(mediaCacheKey(it, source)) } ?:
                        if (attachment.display == AttachmentDisplay.VIDEO) ImageDimensions(16, 9) else ImageDimensions(1, 1)
                    }
                    attachment.copy(dimensions = dimensions, preview = previews[source], session = captured?.id)
                }
            }
        }
        if (media.http.session.value != captured || !repository.isCurrent(state)) return
        val logged = CallLog.withRecords(mapped.rows, callRecords, conversationId) { record ->
            activity.getString(R.string.call_log_ended, CallPresentation.duration(record.seconds))
        }
        val shownSuggestions = suggestions.value
        val rows = if (shownSuggestions.isEmpty() || logged.isEmpty()) logged else logged + ChatMessage(
            id = rowId(SUGGESTIONS_KIND), conversationId = conversationId, turnId = logged.last().turnId, role = ChatRole.AGENT,
            text = "", createdAt = 0L, cardKind = SUGGESTIONS_KIND, cardPayload = ChatSuggestion.encode(shownSuggestions),
        )
        // Freeze geometry for the current window; draft thumbnails also survive intermediate states.
        val shownSources = rows.mapNotNull { it.attachment?.file?.source }.toSet()
        frozenSizes.keys.retainAll(shownSources)
        retryTargets = mapped.retryTargets
        entryRows = mapped.entryRows
        rowEntries = mapped.rowEntries
        tasks.onConversation(state)
        sendFlow.showConversation(state.conversationId)
        if (prepared.isEmpty() && rows.size > FIRST_SCREEN_MIN_ROWS) {
            // Opening a long conversation: show the newest screen first, then lay out the rest.
            // The rest arrives as a prepend, which the timeline anchors so nothing moves.
            // Both passes use the same resolved attachments, including frozen sizes and previews.
            var staged = prepared
            val firstScreen = prepareFirstScreen(rows, (timeline.height - timeline.paddingTop) * 3 / 2) { screen ->
                val previousRole = rows.getOrNull(rows.size - screen.size - 1)?.role
                prepare(screen, staged, previousRole).also { staged = it }
            }
            if (media.http.session.value != captured || !repository.isCurrent(state)) return
            prepared = firstScreen
            timeline.hasMoreHistory = false
            submit(firstScreen)
            if (media.http.session.value != captured || !repository.isCurrent(state)) return
        }
        val next = prepare(rows)
        if (media.http.session.value != captured || !repository.isCurrent(state)) return
        prepared = next
        timeline.hasMoreHistory = state.hasOlder && !state.loadingOlder
        submit(next)
        if (media.http.session.value != captured || !repository.isCurrent(state)) return
        if (followNewCall) {
            followNewCall = false
            timeline.followLatest()
        }
        lastState = state
        renderConnection(state)
        revealPending()
    }

    /**
     * Follows the suggestions of [state]'s settled turn in the app's language, or none: null [state] means the chat is
     * hidden. A new turn, a send or another conversation replaces them; nothing polls.
     */
    private fun updateSuggestions(state: ConversationState?) {
        val message = state?.let(ChatSuggestion::settledMessage)
        val locale = ChatSuggestion.language(activity.resources.configuration.locales[0])
        val key = message?.let { "${System.identityHashCode(state.scope)} ${state.conversationId} $it $locale" }
        if (key == suggestionKey) return
        suggestionWatch?.cancel()
        suggestionWatch = null
        suggestionKey = key
        setSuggestions(emptyList())
        if (state == null || message == null || key == dismissedSuggestionKey) return
        suggestionWatch = owner.lifecycleScope.launch {
            repository.suggestions(state, message, locale).collect { if (suggestionKey == key) setSuggestions(it) }
        }
    }

    private fun setSuggestions(next: List<ChatSuggestion>) {
        suggestions.value = next
        // The first prompt stands in the empty composer, as the reply it suggests.
        composer.field.hint = next.firstOrNull()?.prompt ?: activity.getString(R.string.composer_hint)
    }

    /** A chosen or accepted suggestion closes this turn's suggestions until the next turn settles. */
    private fun dismissSuggestions() {
        dismissedSuggestionKey = suggestionKey
        suggestionWatch?.cancel()
        suggestionWatch = null
        setSuggestions(emptyList())
    }

    /**
     * Opens the viewer at [item] over the images and videos of the loaded rows, in timeline order: at most
     * [MEDIA_WINDOW] on either side of it. Paging there reveals each page's tile here.
     */
    private fun openMedia(item: PreparedChatMessage) {
        val session = media.http.session.value ?: return
        val shown = prepared.filter { row ->
            val attachment = row.message.attachment
            attachment != null && attachment.file.source != null && attachment.display != AttachmentDisplay.FILE &&
                (attachment.session == null || attachment.session == session.id)
        }
        val at = shown.indexOfFirst { it.message.id == item.message.id }
        if (at < 0) return
        val window = shown.subList((at - MEDIA_WINDOW).coerceAtLeast(0), (at + MEDIA_WINDOW + 1).coerceAtMost(shown.size))
        val items = window.mapNotNull { row -> row.message.attachment!!.viewerItem()?.let { row.message.id to it } }
        val index = items.indexOfFirst { it.first == item.message.id }
        if (index < 0) return
        ChatMediaLink.reveal = timeline::revealMediaRow
        ImageViewerActivity.startFromChat(activity, items.map { it.second }, items.map { it.first }, index)
    }

    /** A chip sends only its prompt; the composer's text and files stay in the draft. */
    private fun sendSuggestion(suggestion: ChatSuggestion) {
        if (suggestion !in suggestions.value) return
        dismissSuggestions()
        owner.lifecycleScope.launch {
            val sent = repository.send(suggestion.prompt, consumeDraft = false)
            if (sent != null) timeline.followLatest()
            else Toast.makeText(activity, R.string.chat_send_not_ready, Toast.LENGTH_SHORT).show()
        }
    }

    /** A hardware Tab puts the first prompt into an empty composer without sending it. */
    private fun acceptSuggestion(): Boolean {
        val prompt = suggestions.value.firstOrNull()?.prompt ?: return false
        if (composer.field.text.isNotEmpty()) return false
        composer.field.setText(prompt)
        composer.field.setSelection(composer.field.length())
        dismissSuggestions()
        return true
    }

    /** Scrolls to a timeline entry (a reply opened from its notification) as soon as it is shown. */
    fun reveal(entryKey: String) {
        pendingReveal = entryKey to SystemClock.uptimeMillis() + REVEAL_WAIT_MS
        if (prepared.isNotEmpty()) revealPending()
    }

    private fun revealPending() {
        val (key, until) = pendingReveal ?: return
        val row = entryRows[key]
        if (row == null) {
            if (SystemClock.uptimeMillis() > until) pendingReveal = null
            return
        }
        pendingReveal = null
        timeline.revealRow(row)
    }

    private suspend fun prepare(
        rows: List<ChatMessage>,
        previous: List<PreparedChatMessage> = prepared,
        firstPreviousRole: ChatRole? = null,
    ): List<PreparedChatMessage> =
        precomputer.prepareChanged(
            previous = previous, messages = rows, viewportWidthPx = timeline.width, density = density,
            fontScale = activity.resources.configuration.fontScale * DesignTypography.chatScale(), darkTheme = isDark(),
            syntaxTheme = syntax, palette = palette, actionLabels = actionLabels, codeLabels = codeHeaderLabels,
            firstPreviousRole = firstPreviousRole,
        )

    private var firstContentShown = false

    private suspend fun submit(rows: List<PreparedChatMessage>) {
        sendFlow.submit(rows)
        if (!firstContentShown && rows.isNotEmpty()) {
            firstContentShown = true
            timeline.doOnPreDraw { onFirstContent() }
            timeline.invalidate()
        }
    }

    private fun renderConnection(state: ConversationState?) = connection.present(session.value, state)

    private fun bindTopBar() {
        topBar.menuButton.setOnClickListener { onOpenSidebar?.invoke() }
        topBar.callButton.setOnClickListener { onCall() }
        topBar.browserButton.setOnClickListener {
            lastState?.participant?.participantId?.takeIf(String::isNotEmpty)?.let { onOpenBrowser?.invoke(it) }
        }
        // The capsule is a second, larger way into the sidebar.
        topBar.capsule.setOnClickListener { onOpenSidebar?.invoke() }
        notice.setOnClickListener { connection.retry() }
        topBar.capsule.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateChromePatches() }
        topBar.onGlassTouch = { key, event -> body.trackPress(key, event, topBar.pressTarget(key)) }
        topBar.addOnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ ->
            val height = bottom - top
            updateTopInset(height)
            (notice.layoutParams as FrameLayout.LayoutParams).let { params ->
                if (params.topMargin != height) {
                    params.topMargin = height
                    notice.layoutParams = params
                }
            }
            // Frosted behind the whole bar, thinning out across its bottom edge; the button and
            // the capsule sit where it thins, so they get frosted patches of their own.
            body.setTopBand(topBar.frostBottom, topBar.frostSolid)
            flight.frostUnderTop(body, topBar.frostBottom)
            updateBottomInset()
            updateChromePatches()
        }
    }

    /** Frosted patches under the chrome that hangs below the top band, in the list host's coordinates. */
    private fun updateChromePatches() {
        topBar.frostPatches().forEach { patch ->
            patch.bounds.offset(topBar.left - body.left, topBar.top - body.top)
            body.setTopPatch(patch.key, patch.bounds, patch.radius)
        }
    }

    /** Adds [text] to the composer after a blank line and focuses it; the member sends it. */
    fun fillDraft(text: String) = composer.fillDraft(text)

    fun focusComposer() = composer.focusInput()

    /** Puts the keyboard and the attachment panel away, e.g. as the sidebar comes out. */
    fun dismissInput() = composer.dismiss()

    /**
     * Drags that start on the composer (or the keyboard gap under it) belong to it, never to the
     * sidebar. [x] and [y] are in [root]'s coordinates.
     */
    @Suppress("UNUSED_PARAMETER")
    fun excludesSidebarDragAt(x: Float, y: Float): Boolean =
        y >= composer.y

    private fun bindTimeline() {
        scrollToLatest.bindTo(timeline, body::setBottomOverflow)
        scrollToLatest.onShapeChanged = ::updateLatestGlass
        // Frosting only while something is scrolled up under the top chrome.
        timeline.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                body.setTopOverflow(timeline.canScrollVertically(-1))
            }
        })
        timeline.onLongPressMessage = { anchor, item ->
            // Select all copies the whole message, including text beyond a reference card.
            val blocks = rowEntries[item.message.id]?.let { key -> lastState?.let { entryBlocks(it, key, tasks.known.value, labels) } }
            MessageActionsPopup.show(anchor, item, blocks ?: item.contents)
        }
        timeline.onCopyCode = { MessageActionsPopup.copyCode(activity, it) }
        timeline.onLoadOlderHistory = { owner.lifecycleScope.launch { repository.loadOlder() } }
        timeline.onSendFailed = { rowId ->
            if (failedSends.has(rowId)) FailedSendSheet(activity) { failedSends.choose(rowId, it) }.show()
        }
        timeline.questionHost = questions
        timeline.requestHost = requests
        timeline.onSuggestion = ::sendSuggestion
        timeline.onOpenDynamicUi = { target ->
            composer.dismiss()
            surf.comma.android.dynamicui.DynamicUiSheet.open(activity, target, ::fillDraft)
        }
        timeline.onOpenMedia = ::openMedia
        // Touching the conversation puts the keyboard and the attachment panel away; a question card's field keeps it.
        timeline.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(rv: RecyclerView, e: MotionEvent): Boolean {
                if (e.actionMasked == MotionEvent.ACTION_DOWN && !QuestionCardView.isOnField(rv, e.x, e.y)) {
                    composer.dismiss()
                    QuestionCardView.releaseFields(rv)
                }
                return false
            }
        })
    }

    private fun bindComposer() {
        uploadBinding = draft.bindComposer(owner.lifecycleScope, composer::showAttachments)
        sendFlow.bind()
        composer.onAttachmentsAdded = draft::add
        composer.onAttachmentRemoved = draft::remove
        composer.onAttachmentRetry = draft::retry
        composer.onQuestionImagesPicked = questionImages::add
        // The core keeps the draft's files only while it shows the conversation, so a picker over the app keeps it.
        composer.onPicking = { open -> repository.setHold(ChatView.Hold.PICKER, open) }
        composer.onImeOffset = { updateBottomInset() }
        composer.onSurfaceChanged = ::updateComposerGlass
        composer.onGlassTouch = { body.trackPress(COMPOSER_GLASS, it) }
        composer.transformOutgoing = triggerMenu::serialize
        composer.onTabKey = ::acceptSuggestion
        composer.transcribeDictation = repository::transcribeDictation
        composer.onDictated = triggerMenu::dismiss
        composer.onDictationFailed = ::showDictationFailure
        composer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateBottomInset() }
        body.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateBottomInset() }
    }

    private fun showDictationFailure(failure: DictationFailure) {
        val settings = surf.comma.android.workspace.WorkspaceStore.Toast.Action(activity.getString(R.string.call_microphone_open_settings)) {
            activity.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", activity.packageName, null)))
        }
        workspace.showToast(activity.getString(failure.message), true, settings.takeIf { failure == DictationFailure.MICROPHONE_DENIED })
    }

    /**
     * The list's bottom inset is the composer plus whatever lifts it (keyboard or panel). The
     * timeline keeps following with the last real message, not the reserved space below it.
     * The scroll-to-latest button floats over the list and rides the composer's lift without
     * taking any of that space.
     */
    private fun updateBottomInset() {
        followComposer(scrollToLatest, composer.height + dp(SCROLL_TO_LATEST_GAP_DP), composer.liftPx)
        updateLatestGlass()
        followComposer(triggerMenu.view, composer.height - dp(8), composer.liftPx)
        sendFlow.updateBoundary(composer.capsuleTop - body.y - timeline.y)
        // Reflect the top band's full transition above the capsule. Below that edge the band is
        // solid; putting the transition behind the opaque input would hide most of the blur.
        val keyboardInset = kotlin.math.round(composer.keyboardInsetPx).toInt()
        val solid = (body.height - keyboardInset - (composer.capsuleTop - body.y)).toInt().coerceAtLeast(0)
        val fade = topBar.frostBottom - topBar.frostSolid
        // The glass composer lies straight over the content, as on iOS, with no frosted band under it.
        if (body.mode != BackdropBlurLayout.Mode.GLASS) body.setBottomBand(solid + fade, solidPx = solid, insetPx = keyboardInset)
        body.setBottomOverflow(timeline.bottomOverflowPx())
        updateComposerGlass()
    }

    /** The button's glass samples the list under it, and goes with the button as it shows, hides and moves. */
    private fun updateLatestGlass() {
        if (body.mode != BackdropBlurLayout.Mode.GLASS) return
        val button = scrollToLatest
        if (button.visibility != android.view.View.VISIBLE) {
            body.setFloatingPatch(LATEST_GLASS, null, 0f)
            return
        }
        val radius = button.circleRadius
        val x = button.x + button.width / 2f - body.x
        val y = button.y + button.height / 2f - body.y
        val bounds = android.graphics.Rect((x - radius).roundToInt(), (y - radius).roundToInt(), (x + radius).roundToInt(), (y + radius).roundToInt())
        body.setFloatingPatch(LATEST_GLASS, bounds, radius)
        body.setFloatingAlpha(LATEST_GLASS, button.alpha)
    }

    /** The composer is glass only in the experimental material: otherwise it is its own solid surface. */
    private fun updateComposerGlass() {
        if (body.mode != BackdropBlurLayout.Mode.GLASS) return
        val shapes = composer.glassShapes()
        shapes.forEach { it.bounds.offset((-body.x).roundToInt(), (-body.y).roundToInt()) }
        body.setFloatingGroup(COMPOSER_GLASS, shapes, LiquidGlass.BLEND_DP * activity.resources.displayMetrics.density)
        body.lightGroupNearFinger(COMPOSER_GLASS)
    }

    /** The list's top inset is the chrome over it, status bar included. */
    private fun updateTopInset(barHeight: Int) {
        val delta = barHeight - timeline.paddingTop
        if (barHeight <= 0 || delta == 0) return
        timeline.setPadding(timeline.paddingLeft, barHeight, timeline.paddingRight, timeline.paddingBottom)
        timeline.shiftForTopInset(delta)
    }

    private suspend fun awaitLaidOut() {
        if (timeline.isLaidOut && timeline.width > 0) return
        suspendCancellableCoroutine { continuation ->
            timeline.doOnLayout { if (continuation.isActive) continuation.resume(Unit) }
        }
    }

    private fun isDark() = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
        Configuration.UI_MODE_NIGHT_YES

    private fun dp(value: Int) = (value * density).toInt()

    private companion object {
        const val COMPOSER_GLASS = "composer"
        const val LATEST_GLASS = "latest"
        /** How many media items the viewer pages through on either side of the opened one. */
        const val MEDIA_WINDOW = 100
        /** Leaves `md` (8 dp) between the 40 dp circle and the composer inside its 48 dp target. */
        const val SCROLL_TO_LATEST_GAP_DP = 4
        /** How long a reveal waits for its entry to arrive (a cold start syncs first). */
        const val REVEAL_WAIT_MS = 15_000L
    }
}

/** Keeps [view], bottom-docked in the chat root, [bottomPx] up and lifted with the composer. */
internal fun followComposer(view: android.view.View, bottomPx: Int, liftPx: Float) {
    val params = view.layoutParams as? FrameLayout.LayoutParams ?: return
    if (params.bottomMargin != bottomPx) {
        params.bottomMargin = bottomPx
        view.layoutParams = params
    }
    view.translationY = -liftPx
}
