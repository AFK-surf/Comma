package surf.comma.android

import surf.comma.android.chat.render.CodeHighlighter
import surf.comma.android.chat.render.CodeSpan
import surf.comma.android.chat.render.CodeToken
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 代码块语法高亮的切分。纯 JVM。
 *
 * 重点在两头：常见语言标得对，以及**半截代码不能崩**。流式里代码块每一帧都是半截的，
 * 一个没配对的引号或没收尾的注释如果吃掉后面全部内容，屏幕上就是整段变色。
 */
class CodeHighlighterTest {

    @Test
    fun shellKeywordsFlagsAndCommentsGetTheirOwnColour() {
        val code = "# 装包\nif [ -f app.apk ]; then\n  adb install -r app.apk\nfi"
        val spans = CodeHighlighter.spans("bash", code)
        assertEquals(CodeToken.COMMENT, spans.first().token)
        assertEquals("# 装包", slice(code, spans.first()))
        assertTrue(tokensOf(code, spans, CodeToken.KEYWORD).containsAll(listOf("if", "then", "fi")))
        assertTrue("-r 应该是 attribute", tokensOf(code, spans, CodeToken.ATTRIBUTE).contains("r"))
    }

    /** `--serial` 是参数；`verify-apk-install.sh` 里的横杠只是文件名的一部分。 */
    @Test
    fun onlyALeadingDashMakesAFlag() {
        val code = "scripts/verify-apk-install.sh --serial X"
        val spans = CodeHighlighter.spans("bash", code)
        assertEquals(listOf("serial"), tokensOf(code, spans, CodeToken.ATTRIBUTE))
    }

    @Test
    fun kotlinSeparatesKeywordsTypesFunctionsAndNumbers() {
        val code = "fun main() {\n    val n: Int = 42\n    println(\"hi\")\n}"
        val spans = CodeHighlighter.spans("kotlin", code)
        assertTrue(tokensOf(code, spans, CodeToken.KEYWORD).containsAll(listOf("fun", "val")))
        assertTrue(tokensOf(code, spans, CodeToken.FUNCTION).containsAll(listOf("main", "println")))
        assertEquals(listOf("42"), tokensOf(code, spans, CodeToken.NUMBER))
        assertEquals(listOf("\"hi\""), tokensOf(code, spans, CodeToken.STRING))
    }

    /** `sha256` 里的 256 不是数字字面量。 */
    @Test
    fun digitsInsideAnIdentifierAreNotNumbers() {
        val code = "val sha256 = md5sum"
        assertEquals(emptyList<String>(), tokensOf(code, CodeHighlighter.spans("kotlin", code), CodeToken.NUMBER))
    }

    @Test
    fun screamingCaseIsAConstant() {
        val code = "val x = MAX_RETRIES"
        assertEquals(
            listOf("MAX_RETRIES"),
            tokensOf(code, CodeHighlighter.spans("kotlin", code), CodeToken.CONSTANT),
        )
    }

    @Test
    fun anUnknownLanguageStillFindsStringsAndComments() {
        val code = "// note\nsomething \"quoted\" 7"
        val spans = CodeHighlighter.spans("brainfuck", code)
        assertEquals(listOf("// note"), tokensOf(code, spans, CodeToken.COMMENT))
        assertEquals(listOf("\"quoted\""), tokensOf(code, spans, CodeToken.STRING))
        assertEquals(emptyList<String>(), tokensOf(code, spans, CodeToken.KEYWORD))
    }

    // ---- 半截代码 --------------------------------------------------------

    /** 引号还没配对：染到行尾为止，下一行照常解析。 */
    @Test
    fun anUnclosedQuoteStopsAtTheEndOfItsLine() {
        val code = "val a = \"still typing\nval b = 1"
        val spans = CodeHighlighter.spans("kotlin", code)
        assertEquals(listOf("\"still typing"), tokensOf(code, spans, CodeToken.STRING))
        assertEquals(listOf("1"), tokensOf(code, spans, CodeToken.NUMBER))
    }

    /** 块注释还没收尾：吃到结尾，但不越界、不重叠。 */
    @Test
    fun anUnclosedBlockCommentRunsToTheEndAndNoFurther() {
        val code = "val a = 1\n/* still\n   typing"
        val spans = CodeHighlighter.spans("kotlin", code)
        val comment = spans.single { it.token == CodeToken.COMMENT }
        assertEquals(code.length, comment.end)
        assertEquals("/* still\n   typing", slice(code, comment))
    }

    /**
     * 逐字符喂：任何前缀都必须切得出合法、不重叠、不越界的区间。
     * 高亮不改几何，所以它唯一能造成的破坏就是崩或者染错一大片——这条把两者都挡住。
     */
    @Test
    fun everyPrefixOfAStreamingCodeBlockProducesSaneSpans() {
        val code = """
            #!/usr/bin/env bash
            set -euo pipefail
            # 核对手机上跑的是不是刚编的包
            LOCAL="$(md5 -q "${'$'}APK")"
            if [ "${'$'}LOCAL" != "${'$'}DEVICE" ]; then
              echo "mismatch" >&2
              exit 1
            fi
        """.trimIndent()
        for (end in 0..code.length) {
            val prefix = code.substring(0, end)
            val spans = CodeHighlighter.spans("bash", prefix)
            var previousEnd = 0
            spans.forEach { span ->
                assertTrue("第 $end 个字符：区间倒了 $span", span.start < span.end)
                assertTrue("第 $end 个字符：区间越界 $span", span.end <= prefix.length)
                assertTrue("第 $end 个字符：区间重叠 $span", span.start >= previousEnd)
                previousEnd = span.end
            }
        }
    }

    private fun slice(code: String, span: CodeSpan) = code.substring(span.start, span.end)

    private fun tokensOf(code: String, spans: List<CodeSpan>, token: CodeToken) =
        spans.filter { it.token == token }.map { slice(code, it) }
}
