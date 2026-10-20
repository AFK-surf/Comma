package surf.comma.android.ui.icons

/**
 * Where every licensed icon in `res/drawable` came from.
 *
 * These glyphs are Central Icons (commercially licensed): the app may ship them, but the files
 * must not be shared or redistributed. Before this repository goes public, every entry here has
 * to be removed or replaced (or generated at build time from a licensed copy). The drawables keep
 * the source viewBox and paths, stroke 2 with round caps and joins, and are tinted in code.
 *
 * `IconSourcesTest` keeps this list and the drawable folder in step.
 */
object IconSources {

    data class Entry(
        /** Drawable resource name, without the `R.drawable.` prefix. */
        val resource: String,
        /** What the icon means in the app. */
        val use: String,
        /** Central Icons style package. */
        val pack: String,
        /** Central Icons glyph name. */
        val glyph: String,
        /** Version of [pack] the paths were taken from. */
        val version: String,
        /** Anything done to the paths beyond copying them. */
        val note: String? = null,
    )

    const val OUTLINED = "@central-icons-react/round-outlined-radius-2-stroke-2"
    const val FILLED = "@central-icons-react/round-filled-radius-2-stroke-2"
    private const val OUTLINED_VERSION = "1.1.296"
    private const val FILLED_VERSION = "1.1.300"

    private fun outlined(resource: String, use: String, glyph: String, note: String? = null) =
        Entry(resource, use, OUTLINED, glyph, OUTLINED_VERSION, note)

    private fun filled(resource: String, use: String, glyph: String, note: String? = null) =
        Entry(resource, use, FILLED, glyph, FILLED_VERSION, note)

    /**
     * Simple locally drawn glyphs standing in until a Central Icons glyph replaces them. They are
     * not licensed icons, so they are not [entries]; replacing one moves it there.
     */
    val pendingReplacement: Map<String, String> = mapOf(
        "ic_chat_send_failed" to "Chat: a message that did not send (filled error circle with an exclamation mark)",
        "ic_chat_retry" to "Chat: retry a failed reply (circular arrow)",
        "ic_composer_slash" to "Composer: open the skills menu (a single slash)",
    )

    val entries: List<Entry> = listOf(
        outlined("ic_call_expand", "Call card: expand to the full call page", "IconExpand45"),
        outlined("ic_call_mic", "Call: mute", "IconMicrophone"),
        outlined("ic_call_mic_off", "Call: unmute (muted)", "IconMicrophoneOff"),
        outlined("ic_call_minimize", "Call page: minimize to the card", "IconMinimize45"),
        filled("ic_call_bluetooth", "Call audio output: Bluetooth", "IconBluetooth"),
        filled(
            "ic_call_end", "Call: end the call; chat: a finished call", "IconCall",
            note = "path unchanged; a group turns it 135 degrees about (12, 12) so the handset lies face down",
        ),
        filled("ic_call_headphones", "Call audio output: headphones", "IconHeadphones"),
        filled("ic_call_phone", "Call audio output: the phone's earpiece", "IconPhone"),
        filled("ic_call_speaker", "Call audio output: speaker", "IconVolumeFull"),
        outlined("ic_chat_arrow_down", "Chat: scroll to the latest message", "IconArrowDown"),
        outlined("ic_chat_call", "Chat top bar: start or open a voice call", "IconCall", note = "source sets no line cap"),
        outlined("ic_chat_copy", "Chat: copy a reply", "IconSquareBehindSquare6", note = "source sets no line join"),
        outlined("ic_chat_menu", "Chat: open the sidebar", "IconBarsTwo"),
        outlined("ic_connection_offline", "Connection error: device offline", "IconWifiNoSignal", note = "source sets no line join"),
        outlined("ic_composer_arrow_up", "Composer: send", "IconArrowUp"),
        outlined("ic_composer_camera", "Attach panel: take a photo", "IconCamera1"),
        outlined("ic_composer_check", "Dictation: confirm; chat: a reply was copied", "IconCheckmark1Small"),
        outlined("ic_composer_close", "Dictation: cancel; attachment: remove", "IconCrossSmall"),
        outlined("ic_composer_file", "Attach panel: files", "IconFileBend"),
        filled("ic_composer_mic", "Composer: voice input", "IconMicrophone"),
        outlined("ic_composer_photo", "Attach panel: photos", "IconImages1"),
        outlined("ic_composer_plus", "Composer: attach", "IconPlusLarge"),
        outlined("ic_composer_retry", "Attachment: retry a failed upload", "IconArrowRotateClockwise"),
        outlined("ic_task_archived", "Task status: archived", "IconArchive1"),
        outlined("ic_task_back", "Task detail: back; composer @ menu: back from a model's thinking efforts", "IconChevronLeft"),
        outlined("ic_task_cancelled", "Task status: cancelled", "IconCircleX"),
        outlined("ic_task_done", "Task status: done", "IconCircleCheck"),
        outlined("ic_task_in_progress", "Task status: in progress (spins)", "IconLoader"),
        outlined("ic_task_needs_review", "Task status: needs review; connection error illustration", "IconBubbleAlert"),
        outlined(
            "ic_task_neutral", "Task without a known status", "IconCircleDashed",
            note = "stroke-dasharray 3 4 baked into arcs; VectorDrawable has no dash array",
        ),
        outlined(
            "ic_media_file", "File card: any other type", "IconFileBend",
            note = "same glyph as ic_composer_file; kept separate so the two can diverge",
        ),
        outlined(
            "ic_media_file_archive", "File card: archives", "IconFileZip",
            note = "the outlined pack draws this glyph as filled outlines; no strokes",
        ),
        outlined("ic_media_file_audio", "File card: audio", "IconAudio", note = "source sets no line cap"),
        outlined("ic_media_file_code", "File card: code, HTML, SVG", "IconCode"),
        outlined("ic_media_file_image", "File card: images that are not shown inline", "IconImages1", note = "source sets no line cap"),
        outlined("ic_media_file_pdf", "File card: PDF", "IconFilePdf"),
        outlined("ic_media_file_text", "File card: text and documents", "IconFileText", note = "source sets no line join"),
        outlined("ic_media_file_video", "File card: videos that are not shown inline", "IconVideo", note = "source sets no line cap"),
        outlined("ic_media_close", "Image viewer, video player: close", "IconCrossLarge", note = "source sets no line join"),
        filled("ic_media_play", "Video cover: play", "IconPlay"),
        outlined("ic_media_retry", "Video cover, file card: retry a failed download", "IconArrowRotateClockwise"),
        outlined("ic_media_save", "Image viewer: save to Photos", "IconArrowDownWall"),
        outlined("ic_settings_backend", "Settings (debug): backend address; connection error service badge", "IconServer"),
        outlined("ic_settings_build", "Settings (debug): build variant", "IconCode"),
        outlined("ic_settings_chevron", "Settings: row opens a page; composer @ menu: a model's thinking efforts", "IconChevronRightSmall"),
        outlined("ic_settings_devices", "Settings: signed-in devices", "IconDevices"),
        outlined("ic_settings_comma_device", "Settings: a Comma device", "IconSpeaker", note = "source sets no line join on the grille"),
        outlined("ic_settings_hide", "Wi-Fi password: hide it", "IconEyeSlash"),
        outlined("ic_settings_show", "Wi-Fi password: show it", "IconEyeOpen"),
        outlined("ic_settings_edit", "Settings: edit name", "IconPencil"),
        outlined("ic_settings_labels", "Settings: label changes permission", "IconTag"),
        outlined("ic_settings_language", "Settings: language", "IconGlobe"),
        outlined("ic_settings_licenses", "Settings: open-source licenses", "IconLaw"),
        outlined("ic_settings_log", "Settings (debug): network error log", "IconBug"),
        outlined("ic_settings_notifications", "Settings: reply notifications", "IconBell"),
        outlined("ic_settings_session", "Settings (debug): session generation", "IconHashtag"),
        outlined("ic_settings_sign_out", "Settings: sign out", "IconArrowBoxRight"),
        outlined("ic_settings_text_size", "Settings: font size", "IconTextSize"),
        outlined("ic_settings_theme", "Settings: theme", "IconContrast"),
        outlined("ic_settings_trash", "Settings: remove avatar", "IconTrashCan"),
        outlined("ic_settings_version", "Settings: app version", "IconCircleInfo"),
        outlined("ic_action_check", "Menus and filters: checked", "IconCheckmark1Small"),
        outlined("ic_action_close", "Task sheet, sheets and filters: close", "IconCrossLarge", note = "source sets no line join"),
        outlined("ic_action_cross_small", "Filters: remove a filter", "IconCrossSmall", note = "source sets no line join"),
        outlined("ic_action_done", "Task actions: mark as done", "IconCircleCheck"),
        outlined("ic_action_link", "Task actions: share link", "IconChainLink4"),
        outlined("ic_action_more", "Task sheet: task actions", "IconDotGrid1x3Horizontal"),
        outlined("ic_action_pin", "Task actions: pin", "IconPin"),
        filled("ic_action_pin_fill", "Task rows: pinned", "IconPin"),
        outlined("ic_action_plus", "Labels: add a label", "IconPlusLarge", note = "source sets no line join"),
        outlined("ic_action_rename", "Task and label actions: rename, edit", "IconEditBig", note = "one square line cap drawn round"),
        outlined("ic_action_restore", "Task actions: restore from the archive", "IconArrowOutOfBox"),
        outlined("ic_action_unpin", "Task actions: unpin", "IconUnpin"),
        outlined("ic_arrow_rotate_ccw", "Share: replace link", "IconArrowRotateCounterClockwise"),
        outlined("ic_arrow_rotate_cw", "Routines: refresh; share: include newer messages", "IconArrowRotateClockwise"),
        outlined("ic_arrow_up_right", "Links that leave the app", "IconArrowUpRight"),
        outlined("ic_chevron_down_small", "Task sheet: details; status menus", "IconChevronDownSmall"),
        outlined("ic_circle_x", "Share: stop sharing", "IconCircleX"),
        outlined("ic_composer_at", "Composer: mention a task", "IconAt", note = "source sets no line join"),
        outlined("ic_empty_planning", "Home: no tasks yet", "IconPlanning"),
        outlined("ic_filter_device", "Filters and task details: client platform", "IconMacbook", note = "square or miter caps and joins drawn round"),
        outlined("ic_filter_label", "Filters: label; settings: task labels", "IconTag", note = "source sets no line join; square or miter caps and joins drawn round"),
        outlined("ic_filter_platform", "Filters: platform", "IconSquareGridCircle", note = "source strokes are 1.995 wide; drawn 2"),
        outlined("ic_history", "Task details: Worker history", "IconHistory"),
        outlined("ic_history_input", "Worker history: what the Worker received", "IconArrowInbox"),
        outlined("ic_history_reply", "Worker history: what the Worker replied", "IconChatBubble7", note = "source sets no line cap"),
        outlined("ic_history_thinking", "Worker history: what the Worker thought; composer @ menu: a model", "IconBrain",
            note = "source sets no line join"),
        outlined("ic_history_tool", "Worker history: a tool call and its result", "IconHammer"),
        outlined("ic_inbox_actions", "Inbox and labels: more actions", "IconDotGrid1x3Horizontal"),
        outlined("ic_inbox_clear", "Inbox: clear", "IconArchiveJunk", note = "source sets no line join"),
        outlined("ic_inbox_mark_unread", "Inbox: read and unread", "IconEmail2Unread"),
        outlined("ic_list_archive", "Home: archived tasks; task actions: archive", "IconArchive1"),
        outlined("ic_list_filter", "Task lists: filters", "IconFilter2", note = "source sets no line join"),
        outlined("ic_nav_chevron_down", "Router chat: close", "IconChevronDownMedium"),
        outlined("ic_people", "Settings: account", "IconPeople", note = "source sets no line cap"),
        outlined("ic_plus_small", "Task details: add a label", "IconPlusSmall", note = "source sets no line join"),
        outlined("ic_routine_puzzle", "Home: an app without a logo", "IconPuzzle", note = "square or miter caps and joins drawn round"),
        outlined("ic_settings_arrow_box_left", "Settings: sign out", "IconArrowBoxLeft"),
        outlined("ic_settings_bell", "Settings: notifications", "IconBell"),
        outlined("ic_settings_bell_off", "Settings: notifications blocked", "IconBellOff"),
        outlined("ic_settings_globe", "Settings: language", "IconGlobe", note = "source sets no line join; square or miter caps and joins drawn round"),
        outlined("ic_settings_info", "Settings: version", "IconCircleInfo", note = "source sets no line cap; source sets no line join"),
        outlined("ic_settings_signed_in", "Settings: signed-in devices", "IconDevices", note = "square or miter caps and joins drawn round"),
        outlined("ic_settings_workspace", "Settings: workspace", "IconBuildings"),
        outlined("ic_share_os", "Share: send link", "IconShareOs"),
        outlined("ic_tab_home", "Tab bar: Home", "IconHomeRoof"),
        filled("ic_tab_home_fill", "Tab bar: Home, selected", "IconHomeRoof"),
        outlined("ic_tab_inbox", "Tab bar: Inbox", "IconBox2", note = "square or miter caps and joins drawn round"),
        filled("ic_tab_inbox_fill", "Tab bar: Inbox, selected", "IconBox2"),
        outlined("ic_tab_people", "Tab bar: Settings without an avatar", "IconPeopleCircle", note = "source sets no line cap"),
        outlined("ic_tab_search", "Tab bar: task search", "IconMagnifyingGlass", note = "source sets no line join"),
        outlined("ic_trash_can", "Labels: delete", "IconTrashCan"),
        outlined("ic_warning_triangle", "Warnings: reconnect an app, load failures", "IconExclamationTriangle", note = "source sets no line join"),
    )

    /** A third-party brand mark, shipped as its owner requires. Not a Central Icon, and never tinted. */
    data class BrandMark(
        /** Drawable resource name; one PNG per density bucket. */
        val resource: String,
        val use: String,
        /** Where the artwork came from. */
        val source: String,
        /** The terms it is used under. */
        val terms: String,
        val note: String,
    )

    /** Model makers whose logo is a Central Icons glyph (commercially licensed, like the glyphs above). */
    private val CENTRAL_MODEL_LOGOS = setOf("meta", "mistral", "openai", "xai")

    /** Provider marks drawn in one colour, which follow the text colour instead of keeping their own. */
    val MONOCHROME_PROVIDERS = setOf("github", "notion")

    val brandMarks: List<BrandMark> = listOf(
        BrandMark(
            "ic_google_g", "Sign-in: the Continue with Google button",
            source = "Google Sign-In branding assets (signin-assets.zip), https://developers.google.com/identity/branding-guidelines",
            terms = "Google brand feature, used unmodified as the Sign in with Google branding guidelines require; " +
                "other uses need Google's consent (https://about.google/brand-resource-center/)",
            note = "the standard colour G from the Android light button SVG, rendered at 20dp for each density with a transparent background",
        ),
    ) + listOf("feishu", "github", "gmail", "google", "googlecalendar", "googledrive", "lark", "linear", "notion",
        "outlook", "signal", "slack", "telegram", "wechat").map { key ->
        BrandMark(
            "provider_$key", "Home and routines: the mark of a connected app",
            source = "the iOS app's provider artwork, which follows the desktop's provider logo resolver",
            terms = "the provider's own mark, used unmodified only to name the provider's connected app",
            note = "rendered from the iOS vector artwork at 32dp for each density with a transparent background" +
                if (key in MONOCHROME_PROVIDERS) "; monochrome, so it is tinted with the text colour" else "",
        )
    } + listOf("anthropic", "deepseek", "glm", "google", "kimi", "meta", "minimax", "mistral", "openai", "qwen", "xai").map { key ->
        BrandMark(
            "model_$key", "Tasks: the logo of the maker of the model a Task's Worker runs",
            source = (if (key in CENTRAL_MODEL_LOGOS) "Central Icons ($FILLED $FILLED_VERSION, mask flattened to its paths)"
                else "the desktop's model vendor artwork (`ModelVendorIcon` assets)") + ", the same as the iOS app's `model-$key` asset",
            terms = "the maker's own mark, used unmodified only to name the maker's model",
            note = "rendered at 24dp for each density with a transparent background; monochrome, so it is tinted with the text colour",
        )
    }

    /**
     * Glyphs still waiting for a licensed source. Each resource here is a stand-in drawn for the
     * app, not a Central Icon; replace it with the Mac client's glyph once one is chosen.
     * Empty: every media glyph so far has a Central Icons source.
     */
    val pending: List<String> = emptyList()
}
