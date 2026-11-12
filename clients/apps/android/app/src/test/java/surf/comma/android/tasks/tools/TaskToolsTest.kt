package surf.comma.android.tasks.tools

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.conversation.ChatViewReader
import surf.comma.android.conversation.scope
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.remote.RemoteBrowser
import surf.comma.android.tasks.coding.CodingRepo
import surf.comma.android.tasks.coding.CodingReview
import surf.comma.android.tasks.coding.NewTaskForm
import surf.comma.android.tasks.coding.RepositoryOwner
import surf.comma.android.tasks.coding.RepositoryPicker
import surf.comma.android.tasks.files.TaskFilesModel
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceCalls

/**
 * The Task tools' contracts with the client core: which calls they make with which arguments, what a page keeps of an
 * answer, and that an answer for an account or Workspace no longer shown changes nothing.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TaskToolsTest {
    private class Core : CoreApi {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        var answer: suspend (String, JSONObject) -> Any? = { _, _ -> null }
        /** The values of each topic, by its name; none by default. */
        var topics: (String) -> Flow<TopicValue<Any?>> = { emptyFlow() }

        override suspend fun call(name: String, params: JSONObject): Any? {
            calls += name to JSONObject(params.toString())
            return answer(name, params)
        }

        @Suppress("UNCHECKED_CAST")
        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> =
            topics(topic.getString("topic")) as Flow<TopicValue<T>>

        fun named(name: String) = calls.filter { it.first == name }.map { it.second }
    }

    private var current = true
    private fun calls(core: Core) = WorkspaceCalls(CommaApi(core), "wsp_1", "grp_1") { current }

    private fun file(conversation: String, message: String, index: Int, name: String) = JSONObject()
        .put("conversation_id", conversation).put("message_id", message).put("index", index).put("file_name", name)
        .put("size", 12).put("mime_type", "image/png")

    // MARK: Task files

    @Test
    fun taskFilesKeepOnlyThisTasksFilesAndAppendTheNextPageWithoutRepeats() = runBlocking {
        val core = Core()
        var page = 0
        core.answer = { name, _ ->
            assertEquals("taskFiles.list", name)
            page++
            if (page == 1) JSONObject().put("status", "ready").put("nextCursor", "c2")
                .put("files", JSONArray().put(file("task", "m1", 0, "a.png")).put(file("other", "m9", 0, "x.png")))
            else JSONObject().put("status", "ready").put("nextCursor", JSONObject.NULL)
                .put("files", JSONArray().put(file("task", "m1", 0, "a.png")).put(file("task", "m2", 1, "b.txt")))
        }
        val model = TaskFilesModel(calls(core), "task") {}
        model.load()
        assertEquals(listOf("task/m1/0"), model.state.value.files.map { it.id })
        assertEquals("c2", model.state.value.cursor)
        model.load(more = true)
        assertEquals(listOf("task/m1/0", "task/m2/1"), model.state.value.files.map { it.id })
        assertNull(model.state.value.cursor)
        val params = core.named("taskFiles.list")
        assertEquals("grp_1", params[0].getString("group"))
        assertEquals("task", params[0].getString("conversation"))
        assertFalse(params[0].has("cursor"))
        assertEquals("c2", params[1].getString("cursor"))
        // Without a cursor there is no further page to ask for.
        model.load(more = true)
        assertEquals(2, core.named("taskFiles.list").size)
    }

    @Test
    fun taskFilesSayWhenOlderFilesAreStillIndexedAndWhenTheIndexFailed() = runBlocking {
        val core = Core()
        core.answer = { _, _ -> JSONObject().put("status", "indexing").put("files", JSONArray()) }
        val model = TaskFilesModel(calls(core), "task") {}
        model.load()
        assertTrue(model.state.value.indexing)
        assertNull(model.state.value.failed)
        core.answer = { _, _ -> JSONObject().put("status", "error").put("files", JSONArray()) }
        model.load()
        assertFalse(model.state.value.indexing)
        assertEquals(TaskFilesModel.Failure.Unavailable, model.state.value.failed)
    }

    @Test
    fun addingAFileToContextStagesItsReferenceAndAnAnswerAfterTheScopeEndedIsDropped() = runBlocking {
        val core = Core()
        core.answer = { _, _ -> JSONObject().put("status", "ready").put("files", JSONArray().put(file("task", "m1", 2, "a.png"))) }
        val staged = mutableListOf<JSONArray>()
        val model = TaskFilesModel(calls(core), "task") { staged += it }
        model.load()
        assertTrue(model.attach(model.state.value.files.single()))
        val reference = staged.single().getJSONObject(0)
        assertEquals("task", reference.getString("conversationId"))
        assertEquals("m1", reference.getString("messageId"))
        assertEquals(2, reference.getInt("index"))
        assertEquals("a.png", reference.getString("name"))
        assertEquals(12L, reference.getLong("size"))
        // Another account or Workspace: the next page's answer does not reach this page.
        core.answer = { _, _ -> current = false; JSONObject().put("status", "ready").put("files", JSONArray()) }
        try { model.load() } catch (_: kotlinx.coroutines.CancellationException) {}
        assertEquals(1, model.state.value.files.size)
        assertFalse(model.attach(model.state.value.files.single()))
        assertEquals(1, staged.size)
    }

    @Test
    fun theNameFilterSearchesOnlyTheLoadedNames() {
        val files = listOf("Report.PDF", "notes.txt").mapIndexed { index, name ->
            surf.comma.android.tasks.files.TaskFile("t", "m", index, name, 1, null, 0.0)
        }
        assertEquals(listOf("Report.PDF"), TaskFilesModel.filter(files, " report ").map { it.name })
        assertEquals(2, TaskFilesModel.filter(files, "").size)
    }

    // MARK: Code review

    @Test
    fun aCommitsChangesKeepTheBranchsPullRequestAndMergeNamesTheReviewedHead() = runBlocking {
        val core = Core()
        core.answer = { name, params ->
            when (name) {
                "coding.session" -> JSONObject().put("state", "ready")
                "coding.changes" -> if (params.has("commit")) JSONObject().put("files", JSONArray())
                else JSONObject().put("files", JSONArray().put(JSONObject().put("path", "a.kt")))
                    .put("commits", JSONArray().put(JSONObject().put("sha", "a".repeat(40)).put("title", "Fix")))
                    .put("pullRequest", JSONObject().put("number", 7).put("headSha", "b".repeat(40)).put("state", "open").put("title", "PR"))
                else -> JSONObject()
            }
        }
        val review = CodingReview(calls(core), "task")
        review.load()
        assertEquals("PR", review.prTitle)
        review.select("a".repeat(40))
        assertEquals("a".repeat(40), core.named("coding.changes").last().getString("commit"))
        assertEquals(7, review.pullRequest?.getInt("number"))
        assertTrue(review.files.isEmpty())
        review.merge(7, "b".repeat(40))
        val merge = core.named("coding.mergePullRequest").single()
        assertEquals(7, merge.getInt("number"))
        assertEquals("b".repeat(40), merge.getString("headSha"))
        assertEquals("wsp_1", merge.getString("workspaceId"))
        // After the merge the page reads the whole branch again.
        assertFalse(core.named("coding.changes").last().has("commit"))
    }

    @Test
    fun aNewPullRequestSaysWhetherItIsADraftAnEditedOneDoesNot() = runBlocking {
        val core = Core()
        core.answer = { name, _ -> if (name == "coding.changes") JSONObject().put("files", JSONArray()) else JSONObject() }
        val review = CodingReview(calls(core), "task")
        review.loadChanges()
        review.prTitle = "Title"
        review.prDraft = false
        assertTrue(review.savePullRequest())
        assertEquals(false, core.named("coding.pullRequest").single().getBoolean("draft"))
        core.answer = { name, _ ->
            if (name == "coding.changes") JSONObject().put("files", JSONArray()).put("pullRequest", JSONObject().put("state", "open"))
            else JSONObject()
        }
        review.loadChanges()
        review.prTitle = "Edited"
        assertTrue(review.savePullRequest())
        val update = core.named("coding.updatePullRequest").single()
        assertEquals("Edited", update.getString("title"))
        assertFalse(update.has("draft"))
    }

    @Test
    fun aLateAnswerForAnEarlierCommitDoesNotShowUnderTheCurrentOne() = runBlocking {
        val core = Core()
        val answers = mutableMapOf<String, CompletableDeferred<Unit>>()
        core.answer = { name, params ->
            if (name != "coding.changes") JSONObject()
            else {
                val commit = params.optString("commit")
                answers.getOrPut(commit) { CompletableDeferred() }.await()
                JSONObject().put("files", JSONArray().put(JSONObject().put("path", "$commit.kt")))
            }
        }
        val review = CodingReview(calls(core), "task")
        answers[""] = CompletableDeferred(Unit)
        review.load()
        // The member picks commit a, then commit b before a's changes came back; b answers first.
        val first = launch(Dispatchers.Unconfined) { review.select("a") }
        val second = launch(Dispatchers.Unconfined) { review.select("b") }
        answers.getValue("b").complete(Unit)
        answers.getValue("a").complete(Unit)
        first.join()
        second.join()
        assertEquals("b", review.selection)
        assertEquals(listOf("b.kt"), review.files.map { it.getString("path") })
    }

    @Test
    fun onlyAnHttpsTerminalLinkOpens() {
        assertEquals("https://term.example/s", CodingReview.terminalLink(JSONObject().put("url", "https://term.example/s")))
        assertNull(CodingReview.terminalLink(JSONObject().put("url", "http://term.example/s")))
        assertNull(CodingReview.terminalLink(JSONObject().put("url", "javascript:alert(1)")))
    }

    // MARK: New task

    private fun form(core: Core) = NewTaskForm(calls(core), NewTaskForm.Labels("Comma cloud", "Write code", "Sandbox", "Default", "Unavailable"))

    private fun models(vararg profiles: JSONObject) = TopicValue.Value<JSONObject?>(JSONObject().put("workspace", "wsp_1").put("catalog", JSONObject())
        .put("models", JSONArray().put(JSONObject().put("id", "gpt").put("name", "GPT").put("serving", JSONArray().put("p1"))))
        .put("profiles", JSONArray().apply { profiles.forEach { put(it) } }))

    @Test
    fun theFirstOnlineComputerIsChosenAndOfflineOnesCannotStart() {
        val form = form(Core())
        form.modelsChanged(models())
        form.stationsChanged(TopicValue.Value(JSONObject().put("workspace", "wsp_1").put("stations", JSONArray()
            .put(JSONObject().put("id", "st_off").put("name", "Old").put("link", JSONObject().put("state", "offline")))
            .put(JSONObject().put("id", "st_on").put("name", "Mac").put("link", JSONObject().put("state", "online"))))))
        assertEquals("st_on", form.environmentId)
        assertFalse(form.environments.first { it.id == "st_off" }.online)
        form.chooseEnvironment("st_off")
        form.text = "Do it"
        assertFalse(form.canStart)
        // A later presence update keeps the member's choice.
        form.stationsChanged(TopicValue.Value(JSONObject().put("workspace", "wsp_1").put("stations", JSONArray())))
        assertEquals("st_off", form.environmentId)
    }

    @Test
    fun aCodingTaskNamesItsRepositoryBranchAndAccountAndARetryKeepsItsKey() = runBlocking {
        val core = Core()
        val form = form(core)
        form.modelsChanged(models(JSONObject().put("id", "p1").put("source", "codex").put("subscription", true).put("usable", true).put("name", "Me")))
        form.stationsChanged(TopicValue.Value(JSONObject().put("workspace", "wsp_1").put("stations", JSONArray())))
        form.chooseEnvironment("sandbox")
        form.selectRepository(CodingRepo("acme", "app", "main"))
        form.branch = "dev"
        form.text = "  Fix the bug  "
        form.runId = form.runs.first { it.model == "gpt" }.id
        assertTrue(form.canStart)
        core.answer = { _, _ -> throw CoreError("unavailable", "Network") }
        assertNull(form.start())
        val first = core.named("coding.start").single()
        assertEquals("Fix the bug", first.getString("text"))
        assertEquals("acme", first.getJSONObject("repo").getString("owner"))
        assertEquals("dev", first.getJSONObject("repo").getString("baseRef"))
        assertEquals("p1", first.getString("accountId"))
        assertEquals("codex", first.getJSONObject("model").getString("provider"))
        assertEquals("gpt", first.getJSONObject("model").getString("model"))
        // An ambiguous failure may have made the Task: the retry names the same key.
        core.answer = { _, _ -> JSONObject().put("taskId", "task_9") }
        assertEquals("task_9", form.start())
        assertEquals(first.getString("key"), core.named("coding.start")[1].getString("key"))
        // Made once, it is not made again.
        assertEquals("task_9", form.start())
        assertEquals(2, core.named("coding.start").size)
    }

    @Test
    fun aRefusedStartTakesANewKey() = runBlocking {
        val core = Core()
        val form = form(core)
        form.modelsChanged(models())
        form.stationsChanged(TopicValue.Value(JSONObject().put("workspace", "wsp_1").put("stations", JSONArray())))
        form.text = "Hello"
        assertEquals("salix", form.environmentId)
        val before = form.creationKey
        core.answer = { _, _ -> throw CoreError("refused", "No") }
        assertNull(form.start())
        assertEquals("chat.startTask", core.calls.single().first)
        assertEquals("gpt", core.calls.single().second.getJSONObject("model").getString("id"))
        assertNotEquals(before, form.creationKey)
    }

    @Test
    fun repositorySearchStaysWithinTheChosenOwner() = runBlocking {
        val core = Core()
        core.answer = { name, _ ->
            when (name) {
                "coding.repoOwners" -> JSONObject().put("owners", JSONArray()
                    .put(JSONObject().put("login", "me").put("kind", "user").put("avatarUrl", "http://insecure/a.png"))
                    .put(JSONObject().put("login", "Acme").put("kind", "organization").put("avatarUrl", "https://avatars.example/a.png")))
                "coding.repoSearch" -> JSONObject().put("repos", JSONArray().put(JSONObject().put("owner", "Acme").put("name", "app")))
                    .put("hasMore", false).put("limited", true)
                else -> null
            }
        }
        val picker = RepositoryPicker(calls(core), null)
        picker.loadOwners()
        assertEquals(listOf("me", "Acme"), picker.owners.map(RepositoryOwner::login))
        // Only an https avatar is read.
        assertNull(picker.owners[0].avatarUrl)
        picker.type("ac")
        assertEquals(listOf("Acme"), picker.visibleOwners.map(RepositoryOwner::login))
        picker.choose(picker.owners[1])
        assertEquals("", picker.query)
        picker.type("ap")
        picker.search(debounce = false)
        val search = core.named("coding.repoSearch").single()
        assertEquals("Acme", search.getString("owner"))
        assertEquals("organization", search.getString("kind"))
        assertEquals("ap", search.getString("query"))
        assertEquals(listOf("Acme/app"), picker.repos.map(CodingRepo::id))
        assertTrue(picker.limited)
    }

    // MARK: Remote browser

    @Test
    fun aTapClicksInsideTheFrameAndNothingIsSentWithoutControl() = runBlocking {
        val events = RemoteBrowser.tapEvents(1.4, 0.5, 1280.0, 800.0)!!
        assertEquals(listOf("mousePressed", "mouseReleased"), events.map { it.getString("type") })
        assertEquals(1280.0, events[0].getDouble("x"), 0.0)
        assertEquals(400.0, events[0].getDouble("y"), 0.0)
        assertNull(RemoteBrowser.tapEvents(0.5, 0.5, 0.0, 800.0))
        val core = Core()
        val browser = RemoteBrowser(calls(core), "conv", "prt")
        browser.type("hello")
        browser.key(RemoteBrowser.NavigationKey.ENTER)
        assertTrue(core.named("browserView.input").isEmpty())
    }

    @Test
    fun typedTextIsSentOnlyOnceNoOtherInputIsSending() = runBlocking {
        val core = Core()
        core.topics = { topic ->
            when (topic) {
                "sessionBrowser" -> flowOf(TopicValue.Value<Any?>(JSONObject().put("browser",
                    JSONObject().put("agent_id", "agt").put("session_id", "ses"))))
                "browserView" -> flowOf(TopicValue.Value<Any?>(JSONObject().put("controlling", true)
                    .put("frame", JSONObject().put("seq", 1).put("width", 1280).put("height", 800))))
                else -> emptyFlow()
            }
        }
        val tapSent = CompletableDeferred<Unit>()
        core.answer = { name, params ->
            if (name == "browserView.input" && params.getJSONObject("input").getString("type") == "mousePressed") tapSent.await()
            null
        }
        val browser = RemoteBrowser(calls(core), "conv", "prt")
        browser.start(Any(), CoroutineScope(Dispatchers.Unconfined))
        assertTrue(browser.controlling)
        // A tap is still sending: the text is not sent, and the page keeps it.
        val tap = launch(Dispatchers.Unconfined) { browser.tap(0.5, 0.5) }
        assertFalse(browser.type("hello"))
        tapSent.complete(Unit)
        tap.join()
        assertTrue(browser.type("hello"))
        assertEquals(listOf("mousePressed", "mouseReleased", "text"),
            core.named("browserView.input").map { it.getJSONObject("input").getString("type") })
        browser.stop()
    }

    // MARK: Conversation state

    @Test
    fun aTaskOnACodingSandboxWithARepositoryOffersItsCodeReview() {
        val reader = ChatViewReader(scope(1), "task")
        fun read(place: JSONObject) = reader.read(JSONObject().put("revision", 1)
            .put("state", JSONObject().put("taskRun", JSONObject().put("place", place)))).codingSandbox
        assertTrue(read(JSONObject().put("kind", "sandbox").put("repo", JSONObject().put("owner", "a").put("name", "b"))))
        assertFalse(read(JSONObject().put("kind", "sandbox")))
        assertFalse(read(JSONObject().put("kind", "station").put("repo", JSONObject())))
    }
}
