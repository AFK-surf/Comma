package surf.comma.android.ui.kit

import android.view.View
import android.view.ViewGroup
import surf.comma.android.scroll.widget.DiffUtil
import surf.comma.android.scroll.widget.ListAdapter
import surf.comma.android.scroll.widget.RecyclerView

/**
 * One row of a page's list. [key] identifies it across updates; [type] picks the kind of view it needs, which
 * [create] builds once per holder; [bind] shows this row's [content] on it. Rows with equal [content] are not
 * rebound.
 */
class Row(
    val key: String,
    val type: Int,
    val content: Any?,
    val create: (ViewGroup) -> View,
    val bind: (View) -> Unit = {},
)

/** The pages' list adapter: rows of any kind, diffed by key and content. */
class RowsAdapter : ListAdapter<Row, RecyclerView.ViewHolder>(DIFF) {
    init { setHasStableIds(true) }

    private val factories = mutableMapOf<Int, (ViewGroup) -> View>()

    fun show(rows: List<Row>, done: (() -> Unit)? = null) {
        rows.forEach { factories.getOrPut(it.type) { it.create } }
        submitList(rows) { done?.invoke() }
    }

    override fun getItemId(position: Int): Long = getItem(position).key.hashCode().toLong()

    override fun getItemViewType(position: Int): Int = getItem(position).type

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val view = factories.getValue(viewType)(parent)
        if (view.layoutParams !is RecyclerView.LayoutParams) {
            view.layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT)
        }
        return object : RecyclerView.ViewHolder(view) {}
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = getItem(position).bind(holder.itemView)

    private companion object {
        val DIFF = object : DiffUtil.ItemCallback<Row>() {
            override fun areItemsTheSame(oldItem: Row, newItem: Row) = oldItem.key == newItem.key
            override fun areContentsTheSame(oldItem: Row, newItem: Row) = oldItem.type == newItem.type && oldItem.content == newItem.content
        }
    }
}
