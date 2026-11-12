package surf.comma.android.settings.desktop

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.core.CoreBytes
import java.text.Collator

/** A file of the Drive catalog. [system] names a System File's kind and owner. */
internal data class DriveFile(
    val id: String,
    val name: String,
    val folder: String,
    val space: String,
    val size: Long,
    val system: JSONObject?,
    val writable: Boolean,
) {
    companion object {
        fun parse(json: JSONObject): DriveFile? {
            val id = json.string("id") ?: return null
            val name = json.string("name") ?: return null
            val space = json.string("spaceId") ?: return null
            return DriveFile(id, name, json.string("folderPath").orEmpty(), space, json.int("sizeBytes") ?: 0,
                json.optJSONObject("system"), json.optBoolean("writable"))
        }
    }
}

/** A Drive space; [name] is null for the System Files or Task Files space the server left unnamed. */
internal data class DriveSpace(val id: String, val name: String?) {
    companion object {
        const val SYSTEM_FILES = "comma-system-files"
        const val TASK_FILES = "comma-task-files"

        fun parse(json: JSONObject): DriveSpace? {
            val id = json.string("id") ?: return null
            val name = json.string("name")
            return DriveSpace(id, name ?: if (id == SYSTEM_FILES || id == TASK_FILES) null else id)
        }
    }
}

internal sealed interface DriveEntry {
    val name: String
    data class Folder(override val name: String) : DriveEntry
    data class File(val file: DriveFile) : DriveEntry { override val name get() = file.name }
}

/**
 * Settings > Drive and System Files, as the iOS app's: a local index of the core's `drive` catalog, made once per
 * update. One space at a time shows its immediate folders, then files; a page holds at most [PAGE_SIZE] rows. Search
 * keeps matching files under their folders within the space. Navigation reads nothing more.
 */
internal class DriveModel(scope: WorkspaceScope) {
    val feed = WorkspaceTopic(scope, "drive")
    val scope get() = feed.scope
    var spaces: List<DriveSpace> = emptyList()
        private set
    var selectedSpaceId = ""
        private set
    var folderPath: List<String> = emptyList()
        private set
    var entries: List<DriveEntry> = emptyList()
        private set
    var page = 0
        private set
    var entryCount = 0
        private set
    var query = ""
        set(value) {
            if (value == field) return
            field = value
            rebuildSearch()
            page = 0
            showDirectory()
        }

    private data class Directory(val space: String, val path: String)
    private var filesBySpace: Map<String, List<DriveFile>> = emptyMap()
    private var directories: Map<Directory, List<DriveEntry>> = emptyMap()
    private var searchDirectories: Map<Directory, List<DriveEntry>> = emptyMap()

    val selectedSpace get() = spaces.firstOrNull { it.id == selectedSpaceId }
    val pageCount get() = maxOf(1, (entryCount + PAGE_SIZE - 1) / PAGE_SIZE)
    /** Drive has no node here; the note shows only for an empty, unfiltered directory. */
    val nodeOff get() = feed.value?.optJSONObject("node")?.string("status") == "off"

    fun follow(): Job = feed.follow(::update)

    fun selectSpace(id: String) {
        if (!scope.current || id == selectedSpaceId || spaces.none { it.id == id }) return
        selectedSpaceId = id
        folderPath = emptyList()
        page = 0
        query = ""
        showDirectory()
    }

    fun openFolder(name: String) {
        if (!scope.current || entries.none { it is DriveEntry.Folder && it.name == name }) return
        folderPath = folderPath + name
        page = 0
        showDirectory()
    }

    /** Returns to the parent at [depth]; 0 is the space's root. */
    fun navigate(depth: Int) {
        if (!scope.current || depth < 0 || depth >= folderPath.size) return
        folderPath = folderPath.take(depth)
        page = 0
        showDirectory()
    }

    fun movePage(delta: Int) {
        if (!scope.current) return
        page = (page + delta).coerceIn(0, pageCount - 1)
        showDirectory()
    }

    private fun update(value: JSONObject) {
        spaces = value.objects("spaces").mapNotNull(DriveSpace::parse)
        val files = value.objects("files").mapNotNull(DriveFile::parse).filter { file ->
            val system = file.system ?: return@filter true
            (system.string("group") == null || system.string("group") == scope.groupId) &&
                (system.string("workspace") == null || system.string("workspace") == scope.workspaceId)
        }
        filesBySpace = files.groupBy { it.space }
        directories = index(files)
        if (spaces.none { it.id == selectedSpaceId }) {
            selectedSpaceId = spaces.firstOrNull { it.id != DriveSpace.SYSTEM_FILES && it.id != DriveSpace.TASK_FILES }?.id
                ?: spaces.firstOrNull()?.id.orEmpty()
            folderPath = emptyList()
            page = 0
            query = ""
        }
        // A removed directory returns to its nearest surviving parent. Empty spaces keep their root.
        while (folderPath.isNotEmpty() && directories[Directory(selectedSpaceId, folderPath.joinToString("/"))] == null) {
            folderPath = folderPath.dropLast(1)
            page = 0
        }
        rebuildSearch()
        showDirectory()
    }

    private fun rebuildSearch() {
        if (query.isEmpty()) { searchDirectories = emptyMap(); return }
        val needle = query.lowercase()
        searchDirectories = index(filesBySpace[selectedSpaceId].orEmpty().filter { "${it.folder}/${it.name}".lowercase().contains(needle) })
    }

    private fun showDirectory() {
        val key = Directory(selectedSpaceId, folderPath.joinToString("/"))
        val rows = (if (query.isEmpty()) directories[key] else searchDirectories[key]).orEmpty()
        entryCount = rows.size
        page = page.coerceAtMost(pageCount - 1)
        entries = rows.drop(page * PAGE_SIZE).take(PAGE_SIZE)
        scope.changed()
    }

    private fun index(files: List<DriveFile>): Map<Directory, List<DriveEntry>> {
        val folders = mutableMapOf<Directory, MutableSet<String>>()
        val documents = mutableMapOf<Directory, MutableList<DriveFile>>()
        for (file in files) {
            var parent = ""
            for (name in file.folder.split('/').filter(String::isNotEmpty)) {
                folders.getOrPut(Directory(file.space, parent)) { mutableSetOf() } += name
                parent = if (parent.isEmpty()) name else "$parent/$name"
            }
            documents.getOrPut(Directory(file.space, parent)) { mutableListOf() } += file
        }
        val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
        val order = Comparator<String> { a, b -> naturalCompare(a, b, collator) }
        return (folders.keys + documents.keys).associateWith { key ->
            folders[key].orEmpty().sortedWith(order).map { DriveEntry.Folder(it) } +
                documents[key].orEmpty().sortedWith { a, b -> order.compare(a.name, b.name) }.map { DriveEntry.File(it) }
        }
    }

    suspend fun refresh() { scope.perform("drive.refresh", workspaceParameter = false) }

    companion object {
        const val PAGE_SIZE = 100
        private val CHUNK = Regex("\\d+|\\D+")

        /** Finder order: digit runs compare by value ("File 2" before "File 10"), the rest by the locale. */
        fun naturalCompare(a: String, b: String, collator: Collator): Int {
            val left = CHUNK.findAll(a).map { it.value }.toList()
            val right = CHUNK.findAll(b).map { it.value }.toList()
            for (i in 0 until minOf(left.size, right.size)) {
                val x = left[i]
                val y = right[i]
                val result = if (x[0].isDigit() && y[0].isDigit()) x.toBigInteger().compareTo(y.toBigInteger()) else collator.compare(x, y)
                if (result != 0) return result
            }
            return left.size - right.size
        }
    }
}

/** One Drive file opened for preview or editing, or a new memory file ([file] null). */
internal class DriveDocument(val scope: WorkspaceScope, val file: DriveFile? = null) {
    var path = "/memory/scoped/"
    var text = ""
    var saved: String? = null
        private set
    private var hash: String? = null
    var loaded = false
        private set
    var bytes: ByteArray? = null
        private set
    var mediaType = "text/plain"
        private set
    /** The text content shown read-only, when the file is text. */
    var preview: String? = null
        private set

    private val kind get() = file?.system?.string("kind")
    val editable get() = file == null || (file.writable && kind in setOf("vfs", "instructions"))
    val name get() = file?.name ?: path.substringAfterLast('/')

    suspend fun load() {
        if (file == null) { saved = ""; loaded = true; scope.changed(); return }
        try {
            when (kind) {
                "vfs" -> {
                    path = file.system?.string("path").orEmpty()
                    val answer = scope.call("systemFiles.read", json("group" to scope.groupId, "path" to path), workspaceParameter = false) as? JSONObject
                    text = answer?.optString("content").orEmpty()
                    hash = answer?.string("hash")
                    bytes = text.toByteArray()
                }
                "instructions" -> {
                    val answer = scope.call("systemFiles.instructions", json("group" to scope.groupId), workspaceParameter = false) as? JSONObject
                    text = answer?.optString("content").orEmpty()
                    hash = answer?.string("hash")
                    bytes = text.toByteArray()
                }
                "skill" -> {
                    val skill = file.system?.string("skill") ?: return
                    val answer = scope.call("skills.detail", json("skill" to skill)) as? JSONObject
                    text = answer?.optString("content").orEmpty()
                    bytes = text.toByteArray()
                }
                else -> {
                    val answer = scope.call("drive.read", json("file" to file.id), workspaceParameter = false) as? JSONObject
                    val data = CoreBytes.read(answer?.opt("bytes"))
                    if (data == null || data.size > MAX_BYTES) {
                        scope.error = PageError.Text(R.string.ds_drive_too_large)
                        return
                    }
                    bytes = data
                    mediaType = answer?.string("mediaType") ?: "application/octet-stream"
                    if (mediaType.startsWith("text/")) text = String(data)
                }
            }
            if (!scope.current) return
            saved = text
            preview = text.takeIf { it.isNotEmpty() }
            loaded = true
            scope.error = null
        } catch (_: CancellationException) {
        } catch (e: Exception) {
            if (scope.current) scope.error = WorkspaceScope.describe(e)
        }
    }

    /** Saves over the version last read; a conflict keeps the unsaved text. */
    suspend fun save(): Boolean {
        if (!editable || !loaded) return false
        val instructions = kind == "instructions"
        val params = json("group" to scope.groupId, "content" to text)
        hash?.let { params.put("expectedHash", it) }
        if (!instructions) params.put("path", path)
        val answer = scope.perform(if (instructions) "systemFiles.writeInstructions" else "systemFiles.write", params, workspaceParameter = false)
            ?: return false
        hash = answer.json?.string("hash")
        saved = text
        bytes = text.toByteArray()
        scope.changed()
        return true
    }

    private companion object { const val MAX_BYTES = 10 * 1024 * 1024 }
}
