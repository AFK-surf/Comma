package surf.comma.android.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import surf.comma.android.scroll.widget.DiffUtil
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.ListAdapter
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.R
import surf.comma.android.chat.model.Conversation
import surf.comma.android.chat.model.DeviceOrigin
import surf.comma.android.ui.theme.NDotTypeface
import surf.comma.android.ui.theme.UiSansTypeface
import surf.comma.android.ui.widget.CircleIconButton
import surf.comma.android.ui.widget.DrawerHostLayout

/**
 * 会话列表面板。
 *
 * `ChatRepository` 的 conversations / openConversation / deleteConversation 三个 API
 * 一直存在但全项目零 UI 调用——直接后果是「开了新会话，旧的就回不去」。
 * 这里只做入口：列表、切换、删除。开新会话仍然归 header 上原有的 newChatButton，
 * 不再多一个入口。
 */
class ConversationListController(
    private val root: View,
    private val scrim: View,
    /**
     * The layout that actually moves the panel. Passed in rather than reached
     * for with `root.parent as DrawerHostLayout`: that cast is a promise about
     * the XML that the compiler cannot check, and one more wrapper around the
     * drawer would turn it into a crash on startup.
     */
    private val motion: DrawerHostLayout,
    private val pages: List<View>,
    private val onOpenConversation: (String) -> Unit,
    private val onDeleteConversation: (String) -> Unit,
) {
    private val header = root.findViewById<View>(R.id.conversationsHeader)
    private val title = root.findViewById<TextView>(R.id.conversationsTitle)
    private val close = root.findViewById<CircleIconButton>(R.id.closeConversationsButton)
    private val empty = root.findViewById<TextView>(R.id.conversationsEmpty)
    private val list = root.findViewById<RecyclerView>(R.id.conversationsList).apply {
        layoutManager = LinearLayoutManager(context)
    }

    private val adapter = ConversationAdapter(
        onOpen = { id ->
            onOpenConversation(id)
            close()
        },
        onDelete = onDeleteConversation,
    )

    val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = close()
    }

    val isOpen: Boolean get() = motion.isOpen

    private var conversations: List<Conversation> = emptyList()
    private var activeId: String? = null

    init {
        title.typeface = NDotTypeface
        empty.typeface = UiSansTypeface
        close.setPattern(Dots.close, ContextCompat.getColor(root.context, R.color.ink))
        close.setOnClickListener { close() }
        list.adapter = adapter
        list.itemAnimator = null
        list.overScrollMode = View.OVER_SCROLL_ALWAYS
        list.isVerticalScrollBarEnabled = false
        scrim.setOnClickListener { close() }
        motion.bind(root, scrim, pages) { visible -> backCallback.isEnabled = visible }
        applyInsets()
    }

    fun open() = motion.open()

    fun close() = motion.close()

    fun restoreOpen() = motion.restoreOpen()

    fun render(conversations: List<Conversation>, activeConversationId: String?) {
        if (conversations == this.conversations && activeConversationId == activeId) return
        this.conversations = conversations
        activeId = activeConversationId
        adapter.activeId = activeConversationId
        adapter.submitList(conversations)
        empty.isVisible = conversations.isEmpty()
    }

    private fun applyInsets() {
        val headerExtraTop = header.paddingTop
        val listExtraBottom = list.paddingBottom
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val status = insets.getInsets(WindowInsetsCompat.Type.statusBars())
            val nav = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
            header.setPadding(
                header.paddingLeft,
                headerExtraTop + status.top,
                header.paddingRight,
                header.paddingBottom,
            )
            list.setPadding(
                list.paddingLeft,
                list.paddingTop,
                list.paddingRight,
                listExtraBottom + nav.bottom,
            )
            insets
        }
        ViewCompat.requestApplyInsets(root)
    }

}

private class ConversationAdapter(
    private val onOpen: (String) -> Unit,
    private val onDelete: (String) -> Unit,
) : ListAdapter<Conversation, ConversationAdapter.Holder>(DIFF) {

    var activeId: String? = null

    init {
        setHasStableIds(true)
    }

    override fun getItemId(position: Int): Long = getItem(position).id.hashCode().toLong()

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_conversation, parent, false)
        return Holder(view)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val item = getItem(position)
        val context = holder.itemView.context
        holder.title.typeface = UiSansTypeface
        val title = item.title.ifBlank { context.getString(R.string.conversation_untitled) }
        // Which devices spoke in it, as pictures in front of the title. Only a label.
        val devices = DeviceOrigin.iconsFor(item.deviceKinds)
        holder.title.text = titleWithDeviceIcons(context, devices, title)
        holder.title.contentDescription = deviceTitleDescription(context, devices, title)
        holder.time.typeface = UiSansTypeface
        holder.time.text = ConversationTimeFormatter.format(context, item.updatedAt)
        val active = item.id == activeId
        holder.dot.background.mutate().setTint(
            ContextCompat.getColor(
                context,
                if (active) R.color.comma_accent else R.color.rule_grey,
            ),
        )
        holder.delete.setPattern(
            Dots.close,
            ContextCompat.getColor(context, R.color.ink_muted),
            iconSizeDp = 10,
        )
        holder.itemView.setOnClickListener { onOpen(item.id) }
        holder.delete.setOnClickListener { onDelete(item.id) }
    }

    class Holder(view: View) : RecyclerView.ViewHolder(view) {
        val dot: View = view.findViewById(R.id.conversationActiveDot)
        val title: TextView = view.findViewById(R.id.conversationTitle)
        val time: TextView = view.findViewById(R.id.conversationTime)
        val delete: CircleIconButton = view.findViewById(R.id.conversationDelete)
    }

    private companion object {
        val DIFF = object : DiffUtil.ItemCallback<Conversation>() {
            override fun areItemsTheSame(oldItem: Conversation, newItem: Conversation): Boolean =
                oldItem.id == newItem.id

            override fun areContentsTheSame(oldItem: Conversation, newItem: Conversation): Boolean =
                oldItem == newItem
        }
    }
}
