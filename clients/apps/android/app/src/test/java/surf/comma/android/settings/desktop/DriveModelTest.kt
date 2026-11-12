package surf.comma.android.settings.desktop

import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Drive navigation over the core's catalog: one space, folders first, bounded pages, and no reads while browsing. */
// All identifiers and names below are invented test data.
class DriveModelTest {
    private val h = DesktopHarness()
    private val model = DriveModel(h.scope).also { it.follow() }

    @After fun tearDown() = h.owner.cancel()

    private fun file(id: String, name: String, folder: String, space: String = "projects", system: JSONObject? = null) =
        json("id" to id, "spaceId" to space, "name" to name, "folderPath" to folder, "sizeBytes" to 128, "system" to system)

    private val memory = file("system:memory/scoped/project.md", "project.md", "memory/scoped", "comma-system-files",
        json("kind" to "vfs", "group" to "grp_test_1", "path" to "/memory/scoped/project.md")).put("writable", true)

    private fun catalog(files: List<JSONObject>, spaces: List<Pair<String, String>> = listOf(
        "comma-system-files" to "", "projects" to "Projects", "empty" to "Empty space")) =
        json("node" to json("status" to "off"), "spaces" to JSONArray(spaces.map { json("id" to it.first, "name" to it.second) }),
            "files" to JSONArray(files))

    private val hierarchy = catalog(listOf(memory,
        file("foreign", "private.md", "memory/scoped", "comma-system-files", json("kind" to "vfs", "group" to "grp_other", "path" to "/memory/scoped/private.md")),
        file("root", "readme.md", ""), file("roadmap", "roadmap.md", "Design/2026"), file("brief", "brief.md", "Design"),
        file("sibling", "old.md", "Design-archive"), file("system-root", "Instructions.md", "", "comma-system-files")))

    private fun names() = model.entries.map { it.name }

    @Test
    fun navigatesSpacesFoldersAndBreadcrumbsWithoutReadingFiles() {
        h.core.publish("drive", hierarchy)
        assertEquals("projects", model.selectedSpaceId)
        assertEquals(listOf("Design", "Design-archive", "readme.md"), names())
        model.openFolder("Design")
        assertEquals(listOf("2026", "brief.md"), names())
        model.openFolder("2026")
        assertEquals(listOf("roadmap.md"), names())
        model.navigate(1)
        assertEquals(listOf("Design"), model.folderPath)
        model.navigate(0)
        assertTrue(model.folderPath.isEmpty())

        model.query = "roadmap"
        assertEquals("search keeps the matching file under its folders", listOf("Design"), names())
        model.openFolder("Design"); model.openFolder("2026")
        assertEquals(listOf("roadmap.md"), names())

        model.selectSpace("comma-system-files")
        assertEquals("", model.query)
        assertTrue(model.folderPath.isEmpty())
        assertNull("an unnamed System Files space takes the app's name", model.selectedSpace?.name)
        assertEquals(listOf("memory", "Instructions.md"), names())
        model.openFolder("memory"); model.openFolder("scoped")
        assertEquals("another Group's files never enter the index", listOf("project.md"), names())

        assertEquals(1, h.core.subscribed.count { it.getString("topic") == "drive" })
        assertTrue(h.core.calls.none { it.first in setOf("drive.read", "systemFiles.read") })

        h.switch()
        model.navigate(0)
        assertEquals("a retired page cannot navigate", listOf("memory", "scoped"), model.folderPath)
    }

    @Test
    fun boundsPagesAndReturnsToTheNearestSurvivingFolder() {
        h.core.publish("drive", catalog((0 until 205).map { file("f$it", "File $it.md", "Design/2026") }))
        model.openFolder("Design"); model.openFolder("2026")
        assertEquals(100, model.entries.size)
        assertEquals(3, model.pageCount)
        assertEquals("File 0.md", names().first())
        assertEquals("numbers sort by value", "File 2.md", names()[2])
        model.movePage(2)
        assertEquals(5, model.entries.size)
        assertEquals("File 200.md", names().first())
        model.navigate(0)
        assertEquals(0, model.page)

        model.openFolder("Design"); model.openFolder("2026")
        h.core.publish("drive", catalog(listOf(file("kept", "kept.md", "Design"))))
        assertEquals(listOf("Design"), model.folderPath)
        assertEquals(listOf("kept.md"), names())

        model.selectSpace("empty")
        assertTrue(model.entries.isEmpty())
        assertEquals(1, model.pageCount)
        h.core.publish("drive", catalog(listOf(memory), listOf("comma-system-files" to "")))
        assertEquals("a removed space falls back to one that exists", "comma-system-files", model.selectedSpaceId)
        assertEquals(listOf("memory"), names())
    }

    @Test
    fun memorySaveNamesTheVersionReadAndKeepsTheTextOnConflict() {
        h.core.publish("drive", hierarchy)
        h.core.on("systemFiles.read") { json("content" to "# Notes", "hash" to "read-v2") }
        val document = DriveDocument(h.scope, DriveFile.parse(memory)!!)
        kotlinx.coroutines.runBlocking { document.load() }
        assertTrue(document.editable)
        document.text = "# Notes\nmore"
        h.core.on("systemFiles.write") { throw surf.comma.android.core.CoreError("conflict", "changed", 409) }
        assertEquals(false, kotlinx.coroutines.runBlocking { document.save() })
        assertEquals("read-v2", h.core.called("systemFiles.write").single().getString("expectedHash"))
        assertEquals("/memory/scoped/project.md", h.core.called("systemFiles.write").single().getString("path"))
        assertEquals("# Notes\nmore", document.text)
        assertEquals("# Notes", document.saved)
    }
}
