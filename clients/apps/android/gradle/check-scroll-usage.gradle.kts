// Keep this check independent of Android compilation so lint fails early with source locations.
abstract class CheckScrollUsage : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:Internal
    abstract val sourceRoot: DirectoryProperty

    @TaskAction
    fun check() {
        val forbidden = listOf(
            "android.widget.ScrollView",
            "android.widget.HorizontalScrollView",
            "androidx.core.widget.NestedScrollView",
            "androidx.recyclerview.widget.RecyclerView",
        )
        val errors = mutableListOf<String>()
        sources.files.sorted().forEach { file ->
            val source = file.readText()
            // Preserve line numbers while ignoring comments. String literals remain available
            // for XML class attributes and reflective references; comment markers inside them
            // are not interpreted as comments.
            // Possessive, loop-free patterns: lazy or alternating repeats recurse once per
            // character in java.util.regex and overflow the stack on long raw strings.
            val comments = if (file.extension == "xml") Regex("<!--(?:[^-]++|-(?!->))*+-->") else
                Regex("\"\"\"(?:[^\"]++|\"(?!\"\"))*+\"\"\"|\"(?:[^\"\\\\\\n]++|\\\\.)*+\"|'(?:[^'\\\\\\n]++|\\\\.)*+'|/\\*(?:[^*]++|\\*(?!/))*+\\*/|//[^\\r\\n]*+")
            val text = comments.replace(source) { match ->
                if (file.extension == "xml" || match.value.startsWith("/"))
                    match.value.map { if (it == '\n' || it == '\r') it else ' ' }.joinToString("")
                else match.value
            }
            val matches = mutableMapOf<Int, String>()
            forbidden.forEach { name ->
                val qualified = name.split('.').joinToString("\\s*\\.\\s*") { "`?${Regex.escape(it)}`?" }
                Regex("(?<![\\w.])$qualified(?![\\w])").findAll(text).forEach {
                    matches[it.range.first] = name
                }
                val pkg = name.substringBeforeLast('.')
                val simple = name.substringAfterLast('.')
                if (file.extension == "xml") {
                    // Android inflaters also accept unqualified framework tags and <view class>.
                    if (pkg == "android.widget") {
                        Regex("<\\s*$simple(?=[\\s/>])|\\bclass\\s*=\\s*[\"']$simple[\"']").findAll(text).forEach {
                            matches[it.range.first] = name
                        }
                    }
                } else {
                    val wildcard = Regex("\\bimport\\s+${pkg.split('.').joinToString("\\s*\\.\\s*") { Regex.escape(it) }}\\s*\\.\\s*\\*")
                    if (wildcard.containsMatchIn(text)) {
                        // An explicit module import takes precedence over a wildcard import.
                        val moduleImport = Regex("\\bimport\\s+surf\\.comma\\.android\\.scroll\\.widget\\.$simple[ \t]*(?:;|$)", RegexOption.MULTILINE)
                        if (!moduleImport.containsMatchIn(text)) {
                            Regex("(?<![\\w.`])`?$simple`?(?![\\w])").findAll(text).forEach { matches[it.range.first] = name }
                        }
                    }
                }
            }
            matches.toSortedMap().forEach { (offset, name) ->
                val line = text.take(offset).count { it == '\n' } + 1
                errors += "${file.relativeTo(sourceRoot.get().asFile.parentFile).invariantSeparatorsPath}:$line: $name is forbidden; use :scroll (surf.comma.android.scroll.widget)."
            }
        }
        if (errors.isNotEmpty()) throw GradleException("Scroll usage check failed:\n" + errors.joinToString("\n"))
    }
}

val checkScrollUsage = tasks.register<CheckScrollUsage>("checkScrollUsage") {
    group = "verification"
    description = "Reject scrolling widgets outside the :scroll module in app sources and layouts."
    sourceRoot.set(layout.projectDirectory.dir("src"))
    sources.from(fileTree(sourceRoot) {
        include("**/*.kt", "**/*.java", "**/res/layout*/*.xml")
    })
}

tasks.configureEach {
    if (name.startsWith("lint")) dependsOn(checkScrollUsage)
}
