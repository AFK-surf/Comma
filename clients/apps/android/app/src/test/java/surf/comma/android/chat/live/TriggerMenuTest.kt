package surf.comma.android.chat.live

import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.R
import surf.comma.android.conversation.ModelMentionLinks
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.workspace.MentionModel

/** The @ menu's models in the router chat: what it lists, how a pick reads in the field and travels in the message. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TriggerMenuTest {
    private val gpt = MentionModel("gpt-5.5", "GPT 5.5", "openai", listOf("low", "medium", "high"))
    private val claude = MentionModel("claude-opus", "Claude Opus", "anthropic", emptyList())

    @Test fun `a model mention travels as the desktop's comma model link and reads back`() {
        val plain = ModelMention.of("GPT 5.5", "gpt-5.5")!!
        assertEquals("@GPT 5.5", plain.displayText)
        assertEquals("[GPT 5.5](comma:model/gpt-5.5)", plain.wireText)
        val high = ModelMention.of("GPT 5.5", "gpt-5.5", "high")!!
        assertEquals("@GPT 5.5 · high", high.displayText)
        assertEquals("[GPT 5.5 · high](comma:model/gpt-5.5?effort=high)", high.wireText)
        // Brackets cannot close the link early; whitespace is one space, as on the desktop.
        assertEquals("[GPT (5.5) mini](comma:model/gpt-5.5-mini)", ModelMention.of(" GPT [5.5]\n  mini ", "gpt-5.5-mini")!!.wireText)
        assertNull(ModelMention.of("Bad", "bad id"))
        assertNull(ModelMention.of("GPT 5.5", "gpt-5.5", "High!"))

        val text = "Draft ${plain.wireText} then ${high.wireText} go"
        assertEquals(listOf(ModelMention("GPT 5.5", "gpt-5.5"), ModelMention("GPT 5.5 · high", "gpt-5.5", "high")), ModelMention.parse(text))
        assertEquals("Draft @GPT 5.5 then @GPT 5.5 · high go", ModelMentionLinks.asWords(text))
        assertEquals("no [link](https://example.com)", ModelMentionLinks.asWords("no [link](https://example.com)"))
        assertEquals(emptyList<ModelMention>(), ModelMention.parse("[Fix](comma:task/cnv1_a)"))
    }

    @Test fun `picked mentions become links on send, the longer label first`() {
        val plain = ModelMention.of("GPT 5.5", "gpt-5.5")!!
        val high = ModelMention.of("GPT 5.5", "gpt-5.5", "high")!!
        val task = TaskMention.of("Fix login", "cnv1_a")!!
        assertEquals(
            "[GPT 5.5 · high](comma:model/gpt-5.5?effort=high) review [Fix login](comma:task/cnv1_a), then [GPT 5.5](comma:model/gpt-5.5)",
            ComposerMention.serialize("@GPT 5.5 · high review @Fix login, then @GPT 5.5", listOf(plain, task, high)),
        )
        // Typed by hand, without a pick, it stays text.
        assertEquals("ask @GPT 5.5", ComposerMention.serialize("ask @GPT 5.5", listOf(task)))
    }

    @Test fun `the models topic lists only the models some profile serves`() {
        assertNull(MentionModel.fromTopic(JSONObject().put("catalog", JSONObject.NULL).put("error", false)))
        assertEquals(emptyList<MentionModel>(), MentionModel.fromTopic(JSONObject().put("catalog", JSONObject.NULL).put("error", true)))
        val value = JSONObject().put("catalog", JSONObject()).put("error", false).put("models", JSONArray()
            .put(model("gpt-5.5", "GPT 5.5", "openai", listOf("low", "high"), serving = listOf("prof1")))
            .put(model("unserved", "Unserved", "openai", emptyList(), serving = emptyList()))
            .put(model("claude-opus", "Claude Opus", "anthropic", emptyList(), serving = listOf("prof2"))))
        assertEquals(listOf(MentionModel("gpt-5.5", "GPT 5.5", "openai", listOf("low", "high")),
            MentionModel("claude-opus", "Claude Opus", "anthropic", emptyList())), MentionModel.fromTopic(value))
    }

    @Test fun `the router chat's @ menu lists its models first and filters them by name and id`() = withMenu { menu, field ->
        type(field, "@")
        assertTrue(menu.view.visibility == View.VISIBLE)
        val shown = texts(menu.view)
        assertEquals(listOf(field.context.getString(R.string.composer_models), "GPT 5.5", "Claude Opus",
            field.context.getString(R.string.composer_tasks), "Fix login"), shown)

        type(field, "cla")
        assertEquals(listOf(field.context.getString(R.string.composer_models), "Claude Opus"), texts(menu.view))
        field.setText("")
        type(field, "@gpt-5")
        assertEquals(listOf(field.context.getString(R.string.composer_models), "GPT 5.5"), texts(menu.view))
    }

    @Test fun `a model row takes its default effort and the chevron opens the others`() = withMenu { menu, field ->
        type(field, "Draft the notes @gp")
        click(menu.view, "GPT 5.5")
        assertEquals("Draft the notes @GPT 5.5 ", field.text.toString())
        assertEquals(listOf("@GPT 5.5"), spans(field))
        assertEquals("Draft the notes [GPT 5.5](comma:model/gpt-5.5)", menu.serialize(field.text.toString().trim()))

        field.setText("")
        type(field, "Review it @gpt")
        find(menu.view) { it.contentDescription == field.context.getString(R.string.composer_efforts_open, "GPT 5.5") }!!.performClick()
        assertEquals(listOf("GPT 5.5", field.context.getString(R.string.composer_effort),
            field.context.getString(R.string.composer_effort_default), "low", "medium", "high"), texts(menu.view))
        click(menu.view, "high")
        assertFalse(menu.view.visibility == View.VISIBLE)
        assertEquals("Review it @GPT 5.5 · high ", field.text.toString())
        assertEquals("Review it [GPT 5.5 · high](comma:model/gpt-5.5?effort=high)", menu.serialize(field.text.toString().trim()))
    }

    @Test fun `back from the efforts returns to the menu`() = withMenu { menu, field ->
        type(field, "@")
        find(menu.view) { it.contentDescription == field.context.getString(R.string.composer_efforts_open, "GPT 5.5") }!!.performClick()
        find(menu.view) { it.contentDescription == field.context.getString(R.string.composer_efforts_back) }!!.performClick()
        assertEquals("GPT 5.5", texts(menu.view)[1])
    }

    @Test fun `a deletion into a picked mention takes all of it`() = withMenu { menu, field ->
        type(field, "@cla")
        click(menu.view, "Claude Opus")
        type(field, "hi")
        assertEquals("@Claude Opus hi", field.text.toString())
        field.setSelection("@Claude Opus ".length)
        // Backspace: the space after it, then into it.
        repeat(2) { field.text.delete(field.selectionStart - 1, field.selectionStart) }
        assertEquals("hi", field.text.toString())
        assertEquals(emptyList<String>(), spans(field))
        assertEquals("hi", menu.serialize("hi"))
    }

    @Test fun `models wait for their first read and stay out of a Task's chat`() {
        var models: List<MentionModel>? = null
        withMenu(models = { models }) { menu, field ->
            type(field, "@")
            assertEquals(listOf(field.context.getString(R.string.composer_models), field.context.getString(R.string.composer_searching),
                field.context.getString(R.string.composer_tasks), "Fix login"), texts(menu.view))
            models = listOf(claude)
            menu.refresh()
            assertEquals("Claude Opus", texts(menu.view)[1])
        }
        withMenu(router = false) { menu, field ->
            type(field, "@")
            assertEquals(listOf(field.context.getString(R.string.composer_tasks), "Fix login"), texts(menu.view))
        }
    }

    private fun withMenu(
        router: Boolean = true,
        models: () -> List<MentionModel>? = { listOf(gpt, claude) },
        block: (TriggerMenu, EditText) -> Unit,
    ) = Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
        val activity = controller.get()
        activity.setTheme(R.style.Theme_Chat)
        controller.setup()
        val root = FrameLayout(activity)
        val field = EditText(activity)
        root.addView(field)
        val task = TaskSummary("cnv1_a", "Fix login", TaskStatusBucket.IN_PROGRESS)
        val menu = TriggerMenu(activity, field, router, tasks = { listOf(task) }, skills = { null }, excludedTaskId = { null },
            onNeedSkills = {}, models = models, onNeedModels = {})
        root.addView(menu.view)
        activity.setContentView(root)
        field.requestFocus()
        block(menu, field)
    }

    private fun type(field: EditText, text: String) {
        field.text.replace(field.selectionStart, field.selectionEnd, text)
    }

    private fun spans(field: EditText) = field.text.getSpans(0, field.text.length, MentionSpan::class.java).map { it.mention.displayText }

    private fun texts(view: View): List<String> = when (view) {
        is TextView -> listOf(view.text.toString())
        is ViewGroup -> (0 until view.childCount).flatMap { texts(view.getChildAt(it)) }
        else -> emptyList()
    }

    private fun find(view: View, test: (View) -> Boolean): View? {
        if (test(view)) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index), test)?.let { return it }
        return null
    }

    private fun click(menu: View, label: String) = find(menu) { it.contentDescription == label }!!.performClick()

    private fun model(id: String, name: String, vendor: String, efforts: List<String>, serving: List<String>) = JSONObject()
        .put("id", id).put("name", name).put("vendor", vendor).put("efforts", JSONArray(efforts)).put("serving", JSONArray(serving))
}
