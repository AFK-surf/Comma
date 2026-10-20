package surf.comma.android.settings

import android.content.Context
import android.text.method.LinkMovementMethod
import android.text.util.Linkify
import android.view.View
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.lifecycleScope
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.DesignTypography.Level

/** One third-party component and how to show its license. */
internal data class LicenseEntry(
    val name: String,
    val version: String?,
    /** License names, for example "Apache License 2.0". */
    val licenses: List<String>,
    val website: String?,
    /** Where the full text comes from; null when there is nothing to ship (a commercial license). */
    val text: LicenseText?,
)

internal sealed interface LicenseText {
    data class Inline(val value: String) : LicenseText
    /** Files under `assets/`, shown one after another. */
    data class Assets(val paths: List<String>) : LicenseText
}

/**
 * Everything the app ships from others: the dependency list generated at build time by the
 * AboutLibraries Gradle plugin, plus what Gradle does not know about (the scroll module's
 * upstreams, the bundled font, the licensed icons).
 */
internal object LicenseCatalog {
    private const val SCROLL_NOTICE = "licenses/NOTICE.txt"
    private const val APACHE = "licenses/Apache-2.0.txt"

    fun load(context: Context): List<LicenseEntry> {
        val json = context.resources.openRawResource(R.raw.aboutlibraries).use { it.readBytes().toString(Charsets.UTF_8) }
        return parse(json, context.getString(R.string.settings_licenses_commercial))
    }

    fun parse(json: String, commercial: String): List<LicenseEntry> {
        val root = JSONObject(json)
        val licenses = root.optJSONObject("licenses") ?: JSONObject()
        val libraries = root.optJSONArray("libraries")
        val generated = (0 until (libraries?.length() ?: 0)).mapNotNull { index ->
            val library = libraries!!.getJSONObject(index)
            val id = library.optString("uniqueId")
            // Bills of materials only align versions; nothing of them ships.
            if (id.isEmpty() || id.endsWith("-bom")) return@mapNotNull null
            val keys = library.optJSONArray("licenses")?.let { array -> (0 until array.length()).map(array::getString) }.orEmpty()
            val names = keys.map { key -> licenses.optJSONObject(key)?.optString("name")?.takeIf(String::isNotBlank) ?: key }
            val text = keys.mapNotNull { key -> licenses.optJSONObject(key)?.optString("content")?.takeIf(String::isNotBlank) }
                .joinToString("\n\n").takeIf(String::isNotBlank)
            val bundled = BUNDLED_TEXT.entries.firstOrNull { id.startsWith(it.key) }?.value
            LicenseEntry(
                name = library.optString("name").takeIf(String::isNotBlank) ?: id,
                version = library.optString("artifactVersion").takeIf(String::isNotBlank),
                licenses = names,
                website = library.optString("website").takeIf(String::isNotBlank),
                text = bundled?.let { LicenseText.Assets(listOf(it)) } ?: text?.let(LicenseText::Inline),
            )
        }
        val manual = listOf(
            LicenseEntry("AndroidX RecyclerView (scroll module, modified)", null, listOf("Apache License 2.0"),
                "https://android.googlesource.com/platform/frameworks/support/+/androidx-main/recyclerview/",
                LicenseText.Assets(listOf(SCROLL_NOTICE, APACHE))),
            LicenseEntry("FluidRecyclerView (scroll module, modified)", null, listOf("Apache License 2.0"),
                "https://github.com/Helixform/FluidRecyclerView", LicenseText.Assets(listOf(SCROLL_NOTICE, APACHE))),
            LicenseEntry("fluid-scroll (scroll physics, modified)", null, listOf("Apache License 2.0"),
                "https://github.com/ktiays/fluid-scroll", LicenseText.Assets(listOf(SCROLL_NOTICE, APACHE))),
            LicenseEntry("Inter", null, listOf("SIL Open Font License 1.1"), "https://github.com/rsms/inter",
                LicenseText.Assets(listOf("licenses/Inter-OFL.txt"))),
            // Shipped inside the math layout library; its own listing covers only its code.
            LicenseEntry("KaTeX fonts", null, listOf("SIL Open Font License 1.1"), "https://github.com/KaTeX/KaTeX",
                LicenseText.Assets(listOf("licenses/KaTeX-fonts-OFL.txt"))),
            // Commercially licensed: listed, but the icon files and license are not redistributed.
            LicenseEntry("Central Icons", null, listOf(commercial), null, null),
        )
        return (generated.distinctBy { it.name to it.version } + manual).sortedBy { it.name.lowercase() }
    }

    /** Components whose own license file ships in `assets/licenses/`. */
    private val BUNDLED_TEXT = mapOf("io.coil-kt.coil3:" to "licenses/Coil-3.3.0-LICENSE.txt")

    fun read(context: Context, text: LicenseText): String = when (text) {
        is LicenseText.Inline -> text.value
        is LicenseText.Assets -> text.paths.joinToString("\n\n") { path ->
            context.assets.open(path).use { it.readBytes().toString(Charsets.UTF_8) }
        }
    }
}

/** The list of third-party components. */
internal class LicensesPage(private val ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_licenses)) { ctx.back() }
    override val view: View = layout
    private val loading: Job

    init {
        val intro = activity.text(Level.SMALL, R.color.token_text_quaternary).apply {
            text = activity.getString(R.string.settings_licenses_intro)
            setPadding(activity.dp(16), 0, activity.dp(16), 0)
        }
        layout.section(intro, top = 0)
        loading = activity.lifecycleScope.launch {
            val entries = withContext(Background.files) { LicenseCatalog.load(activity) }
            val section = SettingsSection(activity, null)
            entries.forEach { entry ->
                val row = SettingsRow(activity, null, entry.name)
                row.detail(listOfNotNull(entry.version, entry.licenses.joinToString(", ").takeIf(String::isNotBlank)).joinToString(" · "))
                if (entry.text != null) row.value(null, chevron = true).onClick { ctx.open(LicenseTextPage(ctx, entry)) }
                section.add(row)
            }
            layout.section(section, top = 16)
        }
    }

    override fun onRemoved() = loading.cancel()

    companion object { const val KEY = "licenses" }
}

/** One component's license text. Not restored after recreation; the list is. */
internal class LicenseTextPage(ctx: SettingsContext, entry: LicenseEntry) : SettingsPage {
    override val key = "license"
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, entry.name) { ctx.back() }
    override val view: View = layout
    private val loading: Job

    init {
        val body = activity.text(Level.SMALL, R.color.token_text_secondary).apply {
            setTextIsSelectable(true)
            setPadding(activity.dp(4), 0, activity.dp(4), 0)
        }
        entry.website?.let { site ->
            layout.section(activity.text(Level.SMALL, R.color.token_markdown_text_link).apply {
                text = site
                Linkify.addLinks(this, Linkify.WEB_URLS)
                movementMethod = LinkMovementMethod.getInstance()
                setPadding(activity.dp(4), 0, activity.dp(4), 0)
            }, top = 0)
        }
        layout.section(body, top = 16)
        loading = activity.lifecycleScope.launch {
            body.text = withContext(Background.files) { entry.text?.let { LicenseCatalog.read(activity, it) }.orEmpty() }
        }
    }

    override fun onRemoved() = loading.cancel()
}
