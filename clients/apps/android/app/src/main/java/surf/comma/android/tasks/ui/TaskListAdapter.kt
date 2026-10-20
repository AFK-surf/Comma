package surf.comma.android.tasks.ui

import android.view.ViewGroup
import surf.comma.android.scroll.widget.DiffUtil
import surf.comma.android.scroll.widget.ListAdapter
import surf.comma.android.scroll.widget.RecyclerView

/**
 * Maps string row keys to stable item ids. Ids are handed out once per key and never reused,
 * so two tasks can never collide the way hashed ids can.
 */
class StableIds {
    private val ids = HashMap<String, Long>()
    private var next = 1L

    fun idFor(key: String): Long = ids.getOrPut(key) { next++ }
}

/** Rows arrive fully prepared; binding only hands the prepared row to the view. */
class TaskListAdapter(
    private val theme: TaskTheme,
    private val metrics: TaskCardMetrics,
    private val onOpenTask: (String) -> Unit,
    private val onArchive: (String) -> Unit = {},
) : ListAdapter<PreparedTaskRow, RecyclerView.ViewHolder>(DIFF) {
    private val stableIds = StableIds()

    init {
        setHasStableIds(true)
    }

    override fun getItemId(position: Int): Long = stableIds.idFor(getItem(position).key)

    override fun getItemViewType(position: Int): Int = when (getItem(position)) {
        is PreparedTaskRow.Header -> VIEW_TYPE_HEADER
        is PreparedTaskRow.Card -> VIEW_TYPE_CARD
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder =
        when (viewType) {
            VIEW_TYPE_HEADER -> HeaderHolder(TaskSectionHeaderView(parent.context, metrics, theme))
            else -> CardHolder(
                TaskCardView(parent.context, theme, metrics).also {
                    it.onOpenTask = onOpenTask
                    it.onArchive = onArchive
                },
            )
        }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (holder) {
            is HeaderHolder -> holder.view.bind(getItem(position) as PreparedTaskRow.Header)
            is CardHolder -> {
                // A row coming back after an unconfirmed archive must not keep its swiped offset.
                holder.view.resetSwipe()
                holder.view.bind(getItem(position) as PreparedTaskRow.Card)
            }
        }
    }

    fun cardAt(position: Int): PreparedTaskRow.Card? =
        currentList.getOrNull(position) as? PreparedTaskRow.Card

    class HeaderHolder(val view: TaskSectionHeaderView) : RecyclerView.ViewHolder(view)
    class CardHolder(val view: TaskCardView) : RecyclerView.ViewHolder(view)

    companion object {
        const val VIEW_TYPE_HEADER = 1
        const val VIEW_TYPE_CARD = 2

        private val DIFF = object : DiffUtil.ItemCallback<PreparedTaskRow>() {
            override fun areItemsTheSame(oldItem: PreparedTaskRow, newItem: PreparedTaskRow): Boolean =
                oldItem.key == newItem.key

            /** The preparer memoises on exact inputs, so an unchanged row is the same object. */
            override fun areContentsTheSame(oldItem: PreparedTaskRow, newItem: PreparedTaskRow): Boolean =
                oldItem === newItem
        }
    }
}
