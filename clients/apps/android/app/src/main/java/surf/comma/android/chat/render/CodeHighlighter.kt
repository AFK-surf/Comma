package surf.comma.android.chat.render

/**
 * 代码块里一段字符的语法角色。
 *
 * 分类和配色不是自己编的：取自 `~/Desktop/Projects/rendered-editor` 的 `assets/theme.css`，
 * 那套 `--apple-syntax-*` 是 Xcode 的 *DVTUserInterfaceKit Default* 明暗两套主题。
 * 颜色值落在 `values/colors.xml` 和 `values-night/colors.xml`；这里只管切，不管上色。
 */
enum class CodeToken {
    KEYWORD,
    STRING,
    COMMENT,
    NUMBER,
    TYPE,
    FUNCTION,
    CONSTANT,
    PREPROCESSOR,
    ATTRIBUTE,
}

/** 一段认出来的 token：`[start, end)` 是它在代码正文里的下标区间。 */
data class CodeSpan(val start: Int, val end: Int, val token: CodeToken)

/**
 * 语法高亮的切分。纯 Kotlin、不碰 Android —— 跟消息的块同一条可测性要求；
 * 上色交给 `MessageLayoutPrecomputer`，它才拿得到主题色。
 *
 * 这是**词法**高亮，不是解析：注释、字符串、数字、关键字，以及靠形状判断的类型名和函数名。
 * 它不理解语法——这是有意的。流式里代码块每一帧都是半截的，能稳妥地对付未闭合的字符串和
 * 注释，比认得全语法重要得多：未闭合的块注释吃到结尾，未闭合的引号止于行尾，两种都不会
 * 把后面的代码染成一片。
 *
 * 认不出的语言退回通用规则（注释 + 字符串 + 数字）。宁可少标，不要标错。
 */
object CodeHighlighter {

    fun spans(language: String, code: String): List<CodeSpan> {
        if (code.isEmpty()) return emptyList()
        val spec = specFor(language)
        val out = ArrayList<CodeSpan>()
        var index = 0
        while (index < code.length) {
            val char = code[index]
            index += when {
                spec.lineComments.any { code.startsWith(it, index) } -> lineComment(code, index, out)
                spec.blockComment != null && code.startsWith(spec.blockComment.first, index) ->
                    blockComment(code, index, spec.blockComment, out)
                char == '"' || char == '\'' || (char == '`' && spec.backtickStrings) ->
                    string(code, index, spec, out)
                char.isDigit() && startsToken(code, index) -> number(code, index, out)
                char.isLetter() || char == '_' || char == '$' -> word(code, index, spec, out)
                else -> 1
            }
        }
        return out
    }

    private fun lineComment(code: String, start: Int, out: MutableList<CodeSpan>): Int {
        var end = start
        while (end < code.length && code[end] != '\n') end++
        out.add(CodeSpan(start, end, CodeToken.COMMENT))
        return (end - start).coerceAtLeast(1)
    }

    private fun blockComment(
        code: String,
        start: Int,
        delimiters: Pair<String, String>,
        out: MutableList<CodeSpan>,
    ): Int {
        val close = code.indexOf(delimiters.second, start + delimiters.first.length)
        // 没等到收尾就吃到结尾：流式里注释开一半是常态，不该因此把后面全当代码。
        val end = if (close < 0) code.length else close + delimiters.second.length
        out.add(CodeSpan(start, end, CodeToken.COMMENT))
        return (end - start).coerceAtLeast(1)
    }

    private fun string(code: String, start: Int, spec: LanguageSpec, out: MutableList<CodeSpan>): Int {
        val quote = code[start]
        var index = start + 1
        while (index < code.length) {
            val char = code[index]
            if (char == '\\' && spec.backslashEscapes) {
                index += 2
                continue
            }
            if (char == quote) {
                index++
                break
            }
            // 单行字符串不跨行：一个还没配对的引号不该把整段代码染成字符串。
            if (char == '\n' && quote != '`') break
            index++
        }
        val end = index.coerceAtMost(code.length)
        out.add(CodeSpan(start, end, CodeToken.STRING))
        return (end - start).coerceAtLeast(1)
    }

    private fun number(code: String, start: Int, out: MutableList<CodeSpan>): Int {
        var end = start
        while (end < code.length && (code[end].isLetterOrDigit() || code[end] == '.' || code[end] == '_')) end++
        out.add(CodeSpan(start, end, CodeToken.NUMBER))
        return (end - start).coerceAtLeast(1)
    }

    private fun word(code: String, start: Int, spec: LanguageSpec, out: MutableList<CodeSpan>): Int {
        var end = start
        while (end < code.length && (code[end].isLetterOrDigit() || code[end] == '_' || code[end] == '$')) end++
        val word = code.substring(start, end)
        // 形状判断，不是语义：`Foo(` 当类型，`foo(` 当函数，SCREAMING_CASE 当常量。
        val token = when {
            word in spec.keywords -> CodeToken.KEYWORD
            word in spec.constants -> CodeToken.CONSTANT
            spec.dashedFlagsAreAttributes && precededByDash(code, start) -> CodeToken.ATTRIBUTE
            followedByCall(code, end) ->
                if (word.first().isUpperCase()) CodeToken.TYPE else CodeToken.FUNCTION
            word.length > 1 && word.none { it.isLowerCase() } && word.any { it.isLetter() } ->
                CodeToken.CONSTANT
            spec.capitalisedWordsAreTypes && word.first().isUpperCase() -> CodeToken.TYPE
            else -> null
        }
        if (token != null) out.add(CodeSpan(start, end, token))
        return (end - start).coerceAtLeast(1)
    }

    /** 数字只在词首才算数字：`sha256` 里的 `256` 不是。 */
    private fun startsToken(code: String, index: Int): Boolean {
        if (index == 0) return true
        val previous = code[index - 1]
        return !(previous.isLetterOrDigit() || previous == '_' || previous == '$')
    }

    private fun followedByCall(code: String, end: Int): Boolean {
        var index = end
        while (index < code.length && code[index] == ' ') index++
        return index < code.length && code[index] == '('
    }

    /**
     * `--serial` 是参数，`verify-apk-install.sh` 里的连字符不是。区别在于短横前面是不是
     * 词的开头——文件名里的横杠前面贴着字母。
     */
    private fun precededByDash(code: String, start: Int): Boolean {
        var index = start
        while (index > 0 && code[index - 1] == '-') index--
        if (index == start) return false
        return index == 0 || !(code[index - 1].isLetterOrDigit() || code[index - 1] == '.')
    }

    private data class LanguageSpec(
        val keywords: Set<String>,
        val constants: Set<String> = DEFAULT_CONSTANTS,
        val lineComments: List<String> = listOf("//"),
        val blockComment: Pair<String, String>? = "/*" to "*/",
        val backtickStrings: Boolean = false,
        val backslashEscapes: Boolean = true,
        val capitalisedWordsAreTypes: Boolean = false,
        /** shell 的 `--serial`、`-r`：整条标成 attribute，读命令时一眼分得开参数和值。 */
        val dashedFlagsAreAttributes: Boolean = false,
    )

    private fun specFor(language: String): LanguageSpec = when (language.lowercase()) {
        "bash", "sh", "shell", "zsh", "console", "terminal" -> SHELL
        "kotlin", "kt", "java", "swift", "groovy", "gradle" -> JVM
        "python", "py" -> PYTHON
        "javascript", "js", "typescript", "ts", "tsx", "jsx" -> JS
        "sql" -> SQL
        "json", "jsonc", "yaml", "yml", "toml", "ini", "properties" -> DATA
        else -> GENERIC
    }

    private val DEFAULT_CONSTANTS =
        setOf("true", "false", "null", "nil", "None", "True", "False", "undefined")

    private val SHELL = LanguageSpec(
        keywords = setOf(
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
            "esac", "function", "return", "in", "select", "local", "export", "readonly", "set",
            "unset", "shift", "source", "alias", "trap", "exit", "echo", "cd", "test", "sudo",
        ),
        lineComments = listOf("#"),
        blockComment = null,
        backtickStrings = true,
        dashedFlagsAreAttributes = true,
    )

    private val JVM = LanguageSpec(
        keywords = setOf(
            "package", "import", "class", "interface", "object", "fun", "val", "var", "if", "else",
            "when", "for", "while", "do", "return", "break", "continue", "try", "catch", "finally",
            "throw", "throws", "is", "as", "in", "out", "by", "this", "super", "private", "public",
            "protected", "internal", "open", "abstract", "override", "final", "static", "sealed",
            "data", "enum", "companion", "suspend", "inline", "lateinit", "const", "typealias",
            "init", "constructor", "void", "new", "extends", "implements", "let", "guard", "func",
            "struct", "extension", "protocol",
        ),
        capitalisedWordsAreTypes = true,
    )

    private val PYTHON = LanguageSpec(
        keywords = setOf(
            "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue",
            "import", "from", "as", "pass", "raise", "try", "except", "finally", "with", "yield",
            "lambda", "global", "nonlocal", "assert", "del", "in", "is", "not", "and", "or",
            "async", "await", "self",
        ),
        lineComments = listOf("#"),
        blockComment = null,
        capitalisedWordsAreTypes = true,
    )

    private val JS = LanguageSpec(
        keywords = setOf(
            "const", "let", "var", "function", "class", "extends", "return", "if", "else", "for",
            "while", "do", "break", "continue", "switch", "case", "default", "try", "catch",
            "finally", "throw", "new", "delete", "typeof", "instanceof", "in", "of", "this",
            "super", "import", "export", "from", "as", "async", "await", "yield", "static",
            "interface", "type", "enum", "implements", "readonly", "public", "private",
        ),
        backtickStrings = true,
        capitalisedWordsAreTypes = true,
    )

    private val SQL = LanguageSpec(
        keywords = setOf(
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
            "create", "table", "drop", "alter", "add", "index", "join", "left", "right", "inner",
            "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or",
            "not", "primary", "key", "foreign", "references", "distinct", "union", "with",
        ),
        lineComments = listOf("--"),
    )

    /** JSON / YAML / TOML：没有关键字，值本身就是内容。只标注释、字符串、数字。 */
    private val DATA = LanguageSpec(
        keywords = emptySet(),
        lineComments = listOf("#"),
        blockComment = null,
    )

    private val GENERIC = LanguageSpec(
        keywords = emptySet(),
        lineComments = listOf("#", "//"),
    )
}
