package surf.comma.android.shell

import android.annotation.SuppressLint
import android.view.Gravity
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.list.SwipeRow
import surf.comma.android.tasks.list.TaskRowView
import surf.comma.android.tasks.list.searchField
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.kit.GlassIconButton
import surf.comma.android.ui.kit.Row
import surf.comma.android.ui.kit.RowsAdapter
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * Task search over the tabs, opened from its button beside the Inbox tab, which leaves the selected tab as it is.
 * As on iOS 26 iPhones, the field and its close button sit above the keyboard. Titles are matched on the server once
 * typing pauses for 300 ms, 20 at most; typing again cancels the search in flight. Opening a Task puts the keyboard
 * away and keeps the query for the way back.
 */
@SuppressLint("ViewConstructor")
class SearchLayer(private val shell: Shell, private val onClosed: () -> Unit) : FrameLayout(shell.activity) {
    private val activity = shell.activity
    private val store = shell.store
    private val adapter = RowsAdapter()
    private val list = RecyclerView(activity).apply {
        layoutManager = LinearLayoutManager(activity)
        adapter = this@SearchLayer.adapter
        clipToPadding = false
    }
    private val placeholder = EmptyStateView(activity)
    private val hint = activity.label(Level.MINI, R.color.token_text_quaternary).apply { setText(R.string.search_hint) }
    private val field = searchField(activity, activity.getString(R.string.search_prompt)).apply { glass(elevated = true) }
    private val input = field.getChildAt(1) as EditText
    private val close = GlassIconButton(activity, R.drawable.ic_action_close, activity.getString(R.string.shell_close)).apply { glass(elevated = true) }
    private val bar = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(activity.dp(16), activity.dp(8), activity.dp(16), activity.dp(8))
    }
    private var results: List<TaskSummary>? = null
    private var failed = false
    private var searching: Job? = null
    private var attempt = 0
    private val back = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() = dismiss()
    }

    init {
        id = R.id.search_field
        setBackgroundColor(activity.getColor(R.color.token_bg_primary))
        isClickable = true
        addView(list, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(placeholder, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(hint, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        bar.addView(field, LinearLayout.LayoutParams(0, activity.dp(48), 1f))
        bar.addView(close, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginStart = activity.dp(10)
        })
        addView(bar, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        close.setOnClickListener { dismiss() }
        input.doAfterTextChanged { search() }
        input.imeOptions = EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        input.setOnEditorActionListener { _, action, event ->
            if (action == EditorInfo.IME_ACTION_SEARCH || event?.keyCode == KeyEvent.KEYCODE_ENTER) { hideKeyboard(); true } else false
        }
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                if (newState == RecyclerView.SCROLL_STATE_DRAGGING) hideKeyboard()
            }
        })
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            (bar.layoutParams as LayoutParams).bottomMargin = maxOf(ime, bars.bottom)
            list.setPadding(0, bars.top, 0, maxOf(ime, bars.bottom) + activity.dp(64))
            bar.requestLayout()
            insets
        }
        activity.onBackPressedDispatcher.addCallback(activity, back)
        render()
    }

    fun show() {
        alpha = 0f
        animate().alpha(1f).setDuration(DesignMotion.durationMillis(DesignMotion.dialogEnter)).start()
        ViewCompat.requestApplyInsets(this)
        input.requestFocus()
        input.post { activity.getSystemService(InputMethodManager::class.java)?.showSoftInput(input, 0) }
    }

    /** Back closes search only while it is the top layer; the shell turns it off under the router chat or a raised Task. */
    fun setBackEnabled(enabled: Boolean) {
        back.isEnabled = enabled
    }

    /** Search closes the moment its field stops searching; the keyboard goes down on its own over the tabs. */
    fun dismiss() {
        back.remove()
        searching?.cancel()
        hideKeyboard()
        onClosed()
    }

    private fun hideKeyboard() {
        activity.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(input.windowToken, 0)
    }

    private val query get() = input.text.toString().trim()

    /** One bounded server search per settled query. Earlier results stay on screen until the next arrive. */
    private fun search() {
        searching?.cancel()
        val query = query
        if (query.isEmpty()) { results = null; failed = false; render(); return }
        render()
        val token = ++attempt
        searching = activity.lifecycleScope.launch {
            delay(300)
            try {
                val found = store.search(query)
                if (token != attempt) return@launch
                results = found
                failed = false
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: Exception) {
                if (surf.comma.android.BuildConfig.DEBUG) surf.comma.android.platform.logging.AppLog.warn("TaskSearch", "search failed: $failure")
                if (token != attempt) return@launch
                results = null
                failed = true
            }
            render()
        }
    }

    private fun render() {
        val query = query
        val shown = if (query.isEmpty()) emptyList() else results.orEmpty()
        adapter.show(shown.map { task ->
            val pinned = task.id in store.pinned.value
            Row("task:${task.id}", 1, task to pinned, create = { parent ->
                SwipeRow(parent.context, TaskRowView(parent.context)).apply {
                    layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT).apply {
                        marginStart = activity.dp(10); marginEnd = activity.dp(10); topMargin = activity.dp(1); bottomMargin = activity.dp(1)
                    }
                }
            }) { view ->
                val row = (view as SwipeRow).row as TaskRowView
                row.bind(task, pinned)
                row.setOnClickListener { hideKeyboard(); store.openTask(task.id) }
                row.setOnLongClickListener { shell.actions.menu(task).show(it, haptic = true); true }
            }
        })
        hint.isVisible = query.isEmpty()
        placeholder.isVisible = query.isNotEmpty() && (failed || results?.isEmpty() == true)
        when {
            failed -> placeholder.show(R.drawable.ic_warning_triangle, activity.getString(R.string.search_failed), null,
                activity.getString(R.string.shell_try_again) to { failed = false; search() })
            results?.isEmpty() == true -> placeholder.show(R.drawable.ic_tab_search, activity.getString(R.string.search_no_results))
        }
    }
}
