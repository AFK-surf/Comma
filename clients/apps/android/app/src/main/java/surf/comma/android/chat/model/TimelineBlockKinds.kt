package surf.comma.android.chat.model

/** Stable block kinds used inside an assistant turn document. */
object TimelineBlockKinds {
    const val LIVE_STATUS = "status.live"

    /**
     * [LIVE_STATUS] 行的 cardPayload 标记：思考态（思考中 / 正在整理答复）渲染成
     * 内容骨架 shimmer，而不是 13sp 文案。首个 delta 原位替换为正文，从结构上
     * 消灭 13sp→16sp 的排版跳变。携带服务端进度文案或重连提示时不打标记，照常出字。
     */
    const val LIVE_STATUS_SKELETON = "status.skeleton"
    const val TOOL_PLACEHOLDER = "tool.placeholder"

    /**
     * A reply that failed, shown in its place as a card: the row's text is the title,
     * [ChatMessage.cardPayload] the explanation, and [ChatMessage.retryable] whether a retry
     * control is shown.
     */
    const val REPLY_ERROR = "reply.error"
    const val INLINE_PHOTO = "photo.inline"

    /**
     * The instructions a task was created with, on the task's own page: the message's text in a
     * card that shows its first lines until it is opened. [ChatMessage.cardPayload] is
     * [TASK_BRIEF_EXPANDED] while it is open.
     */
    const val TASK_BRIEF = "task.brief"
    const val TASK_BRIEF_EXPANDED = "expanded"

    /**
     * 一条 Core `image` 事件。跟 [INLINE_PHOTO] 一样是「图片行」而不是卡片，
     * 但它有自己的 kind，理由是流式：[appendDelta] 只肯往 `cardKind` 为 null 或
     * [LIVE_STATUS] 的尾行续写，所以图片必须有一个**非 null 的 kind**，
     * 图片后面的正文才会另起一行，而不是被追加进图片那条消息里。
     */
    const val CORE_IMAGE = "media.image"

    /**
     * 这两个以前是散在各处的裸字符串：注册表、适配器、预排层、内容解析和一堆测试里各写一份。
     * 都路由得好好的，但字符串写错时没有任何报错——只是悄悄退回普通消息行。
     */
    const val PHOTO_GRID = "photo.grid"
    const val MAP_PREVIEW = "map.preview"
    const val APP_INSTALL = "app.install"
    const val MEDIA_NOW_PLAYING = "media.now_playing"
    const val UBER_RIDE_PREPARE = "ride.uber_prepare"
    const val CALENDAR_EVENTS = "calendar.events"
    const val PERSONAL_CONTEXT_RESULTS = "context.results"

    const val WEATHER_PREVIEW = "weather.preview"
    const val WEATHER_CURRENT = "weather.current"
    const val WEATHER_FORECAST = "weather.forecast"

    const val STOCK_PREVIEW = "stock.preview"
    const val STOCK_QUOTE = "stock.quote"
    const val STOCK_CHART = "stock.chart"
}
