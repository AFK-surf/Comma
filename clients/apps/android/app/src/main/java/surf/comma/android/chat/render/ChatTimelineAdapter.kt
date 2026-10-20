package surf.comma.android.chat.render

import android.view.View
import android.view.ViewGroup
import android.view.animation.PathInterpolator
import surf.comma.android.scroll.widget.DiffUtil
import surf.comma.android.scroll.widget.ListAdapter
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.chat.live.AttachmentView
import surf.comma.android.chat.live.QuestionCardHost
import surf.comma.android.chat.live.QuestionCardView
import surf.comma.android.chat.live.ReplyAction
import surf.comma.android.chat.live.ReplyActionsRow
import surf.comma.android.chat.model.TimelineBlockKinds

class ChatTimelineAdapter :
    ListAdapter<PreparedChatMessage, RecyclerView.ViewHolder>(DIFF) {

    var onImageClick: ((String) -> Unit)? = null
    var onRetry: ((Long) -> Unit)? = null
    var onDiscard: ((Long) -> Unit)? = null
    var onSendFailed: ((Long) -> Unit)? = null
    var onLongPress: ((View, PreparedChatMessage) -> Unit)? = null
    var onCopyCode: ((String) -> Unit)? = null
    var onToggleBrief: ((Long) -> Unit)? = null
    internal var onReplyAction: ((ReplyAction, PreparedChatMessage) -> Boolean)? = null
    /** What question cards do on this page; null shows each card as its receipt. */
    internal var questionHost: QuestionCardHost? = null
    /** Rows mid-reveal; cells read their caret from it, card rows their opacity. */
    internal var reveals: TextRevealBook? = null
    /** Rows drawn by the send flight instead of by themselves; kept invisible through rebinds. */
    internal var hiddenRows: Set<Long> = emptySet()
    /** Sideways offsets of code blocks and tables, shared by every cell of this timeline. */
    private val blockScrolls = BlockScrollBook()
    private val cardViews = LinkedHashMap<View, ChatCardRenderer>()
    private val boundKinds = HashMap<Long, String?>()
    private val typingExit = TypingExitDecoration()
    private var timeline: RecyclerView? = null
    /** The typing bubble was just added and has not been bound yet. */
    private var typingEnterPending = false

    init {
        setHasStableIds(true)
    }

    override fun getItemId(position: Int): Long = getItem(position).message.id

    override fun getItemViewType(position: Int): Int = ChatCardRendererRegistry.viewTypeFor(
        getItem(position).message.cardKind,
    )

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val renderer = ChatCardRendererRegistry.forViewType(viewType)
        return if (renderer != null) {
            val view = renderer.create(parent.context)
            if (view is PhotoGridCell) {
                view.onImageClick = { source -> onImageClick?.invoke(source) }
            }
            if (view is AttachmentView) view.onSendFailed = { onSendFailed?.invoke(it) }
            if (view is ReplyActionsRow) view.onAction = { action, item -> onReplyAction?.invoke(action, item) == true }
            if (view is QuestionCardView) view.hostOf = { questionHost }
            cardViews[view] = renderer
            CardHolder(view, renderer)
        } else {
            MessageHolder(ChatMessageCell(parent.context).also { cell ->
                cell.reveals = reveals
                cell.blockScrolls = blockScrolls
                cell.onImageClick = { source -> onImageClick?.invoke(source) }
                cell.onRetry = { messageId -> onRetry?.invoke(messageId) }
                cell.onDiscard = { messageId -> onDiscard?.invoke(messageId) }
                cell.onSendFailed = { messageId -> onSendFailed?.invoke(messageId) }
                cell.onLongPress = { item -> onLongPress?.invoke(cell, item) }
                cell.onCopyCode = { code -> onCopyCode?.invoke(code) }
                cell.onToggleBrief = { messageId -> onToggleBrief?.invoke(messageId) }
            })
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        val item = getItem(position)
        typingExit.boundRows[holder.itemView] = item.message.id
        val previousKind = boundKinds.put(item.message.id, item.message.cardKind)
        holder.itemView.animate().cancel()
        holder.itemView.alpha = when {
            item.message.id in hiddenRows -> 0f
            else -> reveals?.cardAlpha(item.message.id) ?: 1f
        }
        when (holder) {
            is MessageHolder -> {
                holder.cell.bind(item)
                if (typingEnterPending && TypingBubble.isTypingRow(item)) {
                    typingEnterPending = false
                    holder.cell.popInTyping()
                }
            }
            is CardHolder -> holder.renderer.bind(holder.itemView, item)
        }
        if (previousKind == TimelineBlockKinds.TOOL_PLACEHOLDER &&
            item.message.cardKind != TimelineBlockKinds.TOOL_PLACEHOLDER
        ) {
            // The row keeps its height and id; only the ready surface dissolves in.
            holder.itemView.alpha = 0f
            holder.itemView.animate()
                .alpha(1f)
                .setDuration(CARD_REVEAL_DURATION_MS)
                .setInterpolator(CARD_REVEAL_CURVE)
                .start()
        }
    }

    override fun onCurrentListChanged(
        previousList: MutableList<PreparedChatMessage>,
        currentList: MutableList<PreparedChatMessage>,
    ) {
        super.onCurrentListChanged(previousList, currentList)
        val liveIds = currentList.mapTo(HashSet()) { it.message.id }
        boundKinds.keys.retainAll(liveIds)
        typingEnterPending = typingEnters(previousList, currentList)
        val exit = typingExit(previousList, currentList)
        val list = timeline
        if (exit != null && list != null) typingExit.start(exit, list) else typingExit.cancel()
    }

    override fun onAttachedToRecyclerView(recyclerView: RecyclerView) {
        super.onAttachedToRecyclerView(recyclerView)
        timeline = recyclerView
        recyclerView.addItemDecoration(typingExit)
    }

    override fun onDetachedFromRecyclerView(recyclerView: RecyclerView) {
        recyclerView.removeItemDecoration(typingExit)
        typingExit.cancel()
        timeline = null
        super.onDetachedFromRecyclerView(recyclerView)
    }

    override fun onViewDetachedFromWindow(holder: RecyclerView.ViewHolder) {
        (holder.itemView as? TimelineMediaCell)?.setMediaVisible(false)
        super.onViewDetachedFromWindow(holder)
    }

    override fun onViewRecycled(holder: RecyclerView.ViewHolder) {
        (holder.itemView as? TimelineMediaCell)?.releaseMedia()
        super.onViewRecycled(holder)
    }

    fun releaseCards() {
        cardViews.forEach { (view, renderer) -> renderer.release(view) }
        cardViews.clear()
    }

    class MessageHolder(val cell: ChatMessageCell) : RecyclerView.ViewHolder(cell)
    private class CardHolder(
        view: View,
        val renderer: ChatCardRenderer,
    ) : RecyclerView.ViewHolder(view)

    companion object {
        const val VIEW_TYPE_MESSAGE = ChatCardRendererRegistry.MESSAGE_VIEW_TYPE
        val VIEW_TYPE_PHOTO: Int = ChatCardRendererRegistry.viewTypeFor(TimelineBlockKinds.PHOTO_GRID)
        private const val CARD_REVEAL_DURATION_MS = 180L
        private val CARD_REVEAL_CURVE = PathInterpolator(0.2f, 0f, 0f, 1f)

        private val DIFF = object : DiffUtil.ItemCallback<PreparedChatMessage>() {
            override fun areItemsTheSame(
                oldItem: PreparedChatMessage,
                newItem: PreparedChatMessage,
            ): Boolean = oldItem.message.id == newItem.message.id

            override fun areContentsTheSame(
                oldItem: PreparedChatMessage,
                newItem: PreparedChatMessage,
            ): Boolean = oldItem.cacheKey == newItem.cacheKey
        }
    }
}
