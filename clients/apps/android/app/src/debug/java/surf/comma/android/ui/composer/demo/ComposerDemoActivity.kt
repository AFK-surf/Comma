package surf.comma.android.ui.composer.demo

import android.content.Context
import android.content.res.Configuration
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.R
import surf.comma.android.platform.logging.AppLog
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerAttachment
import surf.comma.android.ui.composer.ComposerView

/**
 * Debug-only playground for [ComposerView]: a fake conversation, a fake streamed reply and fake
 * uploads, so keyboard follow, the attachment panel, thumbnails and sending can all be exercised
 * without a backend.
 *
 * adb shell am start -n surf.comma.android.dev/surf.comma.android.ui.composer.demo.ComposerDemoActivity
 */
class ComposerDemoActivity : ComponentActivity() {

    private val main = Handler(Looper.getMainLooper())
    private val messages = ArrayList<Message>()
    private val adapter = MessageAdapter()
    private lateinit var list: RecyclerView
    private lateinit var composer: ComposerView
    private var replyStep: Runnable? = null
    private var uploadsSeen = 0
    /** Upload ids that have already failed once; their retry succeeds. */
    private val failedOnce = HashSet<String>()

    override fun attachBaseContext(newBase: Context) {
        // Set before launch by the offline fixture; onCreate is too late for resource overrides.
        val mode = fixtureNightMode
        super.attachBaseContext(if (mode == null) newBase else newBase.createConfigurationContext(
            Configuration(newBase.resources.configuration).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or mode
            },
        ))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this).apply { setBackgroundColor(getColor(R.color.token_bg_primary)) }

        list = RecyclerView(this).apply {
            layoutManager = LinearLayoutManager(this@ComposerDemoActivity).apply { stackFromEnd = true }
            adapter = this@ComposerDemoActivity.adapter
            clipToPadding = false
            itemAnimator = null // the fake stream rebinds the reply every 60 ms; no crossfades
        }
        root.addView(list, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        seedMessages()

        composer = ComposerView(this)
        composer.attachTo(root)
        composer.onSend = ::onSend
        composer.transcribeDictation = { audio ->
            kotlinx.coroutines.delay(800)
            AppLog.info(TAG, "dictation bytes=${audio.size}")
            "这是一段假的转录"
        }
        composer.onAttachmentsAdded = { added -> added.forEach { simulateUpload(it.id) } }
        composer.onAttachmentRetry = { id -> simulateUpload(id) }
        composer.onAttachmentRemoved = { id -> main.removeCallbacksAndMessages(id) }
        composer.onImeOffset = { updateListInset() }
        composer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateListInset() }
        // Touching the conversation puts the keyboard and the attachment panel away.
        list.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(rv: RecyclerView, e: android.view.MotionEvent): Boolean {
                if (e.actionMasked == android.view.MotionEvent.ACTION_DOWN) composer.dismiss()
                return false
            }
        })

        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        setContentView(root)
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ---- Sending and the fake reply ----

    private fun onSend(text: String, attachments: List<ComposerAttachment>) {
        logSnapshot()
        val label = buildString {
            if (attachments.isNotEmpty()) append("[${attachments.size} 张图片] ")
            append(text)
        }
        addMessage(Message(label, fromUser = true))
        startReply(text)
    }

    private fun logSnapshot() {
        val snapshot = composer.captureSendSnapshot()
        AppLog.info(
            TAG,
            "snapshot lines=${snapshot.textLayout?.lineCount ?: 0} " +
                "surface=${snapshot.surfaceBounds} images=${snapshot.attachments.size}",
        )
    }

    private fun startReply(prompt: String) {
        stopReply()
        val reply = Message("", fromUser = false)
        addMessage(reply)
        val full = FAKE_REPLY.replace("%s", prompt.take(24).ifBlank { "这几张图" })
        var shown = 0
        val step = object : Runnable {
            override fun run() {
                shown = (shown + 3).coerceAtMost(full.length)
                reply.text = full.substring(0, shown)
                adapter.notifyItemChanged(messages.indexOf(reply))
                if (shown < full.length) {
                    main.postDelayed(this, 60)
                } else {
                    replyStep = null
                }
            }
        }
        replyStep = step
        main.postDelayed(step, 400)
    }

    private fun stopReply() {
        replyStep?.let(main::removeCallbacks)
        replyStep = null
    }

    // ---- Fake uploads: pending → uploading → done; every third image fails once ----

    private fun simulateUpload(id: String) {
        main.removeCallbacksAndMessages(id)
        val fails = (++uploadsSeen % 3 == 0) && failedOnce.add(id)
        composer.setAttachmentState(id, AttachmentUploadState.Pending)
        var progress = 0f
        fun tick() {
            progress += 0.1f
            if (fails && progress >= 0.5f) {
                composer.setAttachmentState(id, AttachmentUploadState.Failed)
                return
            }
            if (progress >= 1f) {
                composer.setAttachmentState(id, AttachmentUploadState.Done)
                return
            }
            composer.setAttachmentState(id, AttachmentUploadState.Uploading(progress))
            main.postAtTime({ tick() }, id, android.os.SystemClock.uptimeMillis() + 150)
        }
        main.postAtTime({ tick() }, id, android.os.SystemClock.uptimeMillis() + 500)
    }

    // ---- List ----

    private fun updateListInset() {
        val bottom = composer.height + composer.liftPx.toInt()
        if (list.paddingBottom == bottom) return
        val atEnd = !list.canScrollVertically(1)
        list.setPadding(0, 0, 0, bottom)
        if (atEnd && messages.isNotEmpty()) list.scrollToPosition(messages.size - 1)
    }

    private fun addMessage(message: Message) {
        messages += message
        adapter.notifyItemInserted(messages.size - 1)
        list.scrollToPosition(messages.size - 1)
    }

    private fun seedMessages() {
        SEED.forEachIndexed { index, text -> messages += Message(text, fromUser = index % 2 == 0) }
        adapter.notifyDataSetChanged()
    }

    private class Message(var text: String, val fromUser: Boolean)

    private inner class MessageAdapter : RecyclerView.Adapter<MessageAdapter.Holder>() {
        inner class Holder(val label: TextView) : RecyclerView.ViewHolder(
            FrameLayout(this@ComposerDemoActivity).apply {
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                val gutter = dp(16)
                setPadding(gutter, dp(10), gutter, dp(10))
                addView(label)
            },
        )

        override fun getItemCount() = messages.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
            val label = TextView(this@ComposerDemoActivity).apply {
                textSize = 15f
                setLineSpacing(0f, 1.2f)
            }
            return Holder(label)
        }

        override fun onBindViewHolder(holder: Holder, position: Int) {
            val message = messages[position]
            val label = holder.label
            label.text = message.text
            val lp = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                if (message.fromUser) Gravity.END else Gravity.START,
            )
            if (message.fromUser) {
                lp.marginStart = dp(58)
                label.background = GradientDrawable().apply {
                    setColor(getColor(R.color.token_bg_brand_solid))
                    cornerRadius = dp(20).toFloat()
                }
                label.setTextColor(0xFFFFFFFF.toInt())
                label.setPadding(dp(13), dp(10), dp(13), dp(10))
            } else {
                label.background = null
                label.setTextColor(getColor(R.color.token_text_primary))
                label.setPadding(0, 0, 0, 0)
            }
            label.layoutParams = lp
            label.visibility = if (message.text.isEmpty() && !message.fromUser) View.INVISIBLE else View.VISIBLE
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        @Volatile var fixtureNightMode: Int? = null
        const val TAG = "ComposerDemo"
        const val FAKE_REPLY = "收到：「%s」。这是一段假的流式回复，用来检验生成中的停止按钮：" +
            "回复还在往外吐字的时候，输入框右侧是实心方块；后端还没有停止接口，所以它先是灰的、点了没反应。" +
            "你可以在生成过程中继续打字，但发送会被挡住，直到这段话说完。"
        val SEED = listOf(
            "帮我看看这张收据上的金额对不对",
            "可以，把图片发过来就行。拍照、相册、文件三种方式都支持，一次最多十张。",
            "键盘弹起来的时候输入框会跟着走吗？",
            "会逐帧跟着键盘。打开附件面板时，面板和键盘一样高，所以两者互相切换时输入框一个像素都不动。",
        )
    }
}
