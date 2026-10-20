package surf.comma.android.core

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.SQLiteException
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Base64

/**
 * The core's databases: SQLite files in [directory], one per name, used from the core's thread alone (it is their
 * only writer). Each statement is prepared once and kept. A blob crosses the bridge as `{"$bytes": base64}`.
 */
internal class HostSql(private val directory: File, private val driver: SQLiteDriver = BundledSQLiteDriver()) {
    private class Database(val connection: SQLiteConnection) {
        val statements = HashMap<String, SQLiteStatement>()
        val changes: SQLiteStatement by lazy { connection.prepare("SELECT changes()") }
    }

    private val open = HashMap<Int, Database>()
    private var next = 1

    private fun path(name: String): File {
        require(NAME.matches(name)) { "not a database name" }
        return File(directory, "$name.sqlite")
    }

    fun open(name: String): Int = failing {
        val connection = if (name == ":memory:") driver.open(":memory:") else {
            check(directory.isDirectory || directory.mkdirs())
            driver.open(path(name).path)
        }
        val database = Database(connection)
        try {
            // One process at a time, a write-ahead log, as the core's other hosts open theirs.
            if (name != ":memory:")
                exec(database, "PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        } catch (e: Exception) {
            connection.close()
            throw e
        }
        val id = next++
        open[id] = database
        id
    }

    fun exec(id: Int, sql: String) = failing { exec(database(id), sql) }

    private fun exec(database: Database, sql: String) {
        for (statement in statements(sql)) database.connection.prepare(statement).use { while (it.step()) Unit }
    }

    /** One statement; how many rows it changed. */
    fun run(id: Int, sql: String, params: JSONArray?): Int = failing {
        val database = database(id)
        val statement = prepared(database, sql, params)
        try { while (statement.step()) Unit } finally { statement.reset() }
        val changes = database.changes
        try {
            changes.step()
            changes.getLong(0).toInt()
        } finally { changes.reset() }
    }

    /** One statement's rows, each its columns in order. */
    fun all(id: Int, sql: String, params: JSONArray?): JSONArray = failing {
        val statement = prepared(database(id), sql, params)
        val rows = JSONArray()
        try {
            val columns = statement.getColumnCount()
            while (statement.step()) {
                val row = JSONArray()
                for (column in 0 until columns) row.put(when (statement.getColumnType(column)) {
                    TYPE_INTEGER -> statement.getLong(column)
                    TYPE_FLOAT -> statement.getDouble(column)
                    TYPE_TEXT -> statement.getText(column)
                    TYPE_BLOB -> JSONObject().put(BYTES, Base64.getEncoder().encodeToString(statement.getBlob(column)))
                    else -> JSONObject.NULL
                })
                rows.put(row)
            }
        } finally { statement.reset() }
        rows
    }

    fun close(id: Int) = failing {
        val database = open.remove(id) ?: return@failing
        for (statement in database.statements.values) statement.close()
        database.connection.close()
    }

    /** A database gone from the device: closed if it is open, its files deleted. */
    fun delete(name: String) = failing {
        val file = path(name)
        for (suffix in listOf("", "-wal", "-shm", "-journal")) File(file.path + suffix).delete()
    }

    fun closeAll() {
        for (id in open.keys.toList()) runCatching { close(id) }
    }

    private fun database(id: Int) = open[id] ?: throw HostFailure("the database is closed")

    private fun prepared(database: Database, sql: String, params: JSONArray?): SQLiteStatement {
        val statement = database.statements.getOrPut(sql) { database.connection.prepare(sql) }
        statement.clearBindings()
        if (params != null) for (index in 0 until params.length()) {
            val at = index + 1
            when (val value = params.get(index)) {
                JSONObject.NULL -> statement.bindNull(at)
                is String -> statement.bindText(at, value)
                is Int -> statement.bindLong(at, value.toLong())
                is Long -> statement.bindLong(at, value)
                is Number -> value.toDouble().let {
                    if (it == Math.rint(it) && Math.abs(it) <= MAX_SAFE_INTEGER) statement.bindLong(at, it.toLong())
                    else statement.bindDouble(at, it)
                }
                is JSONObject -> statement.bindBlob(at, Base64.getDecoder().decode(value.getString(BYTES)))
                else -> throw HostFailure("not a value SQLite takes")
            }
        }
        return statement
    }

    private inline fun <T> failing(block: () -> T): T = try { block() } catch (e: HostFailure) { throw e } catch (e: SQLiteException) {
        val message = e.message ?: "SQLite failed"
        val code = CODE.find(message)?.groupValues?.get(1)?.toIntOrNull()?.and(0xff)
        throw HostFailure(message, when {
            code == 13 || message.contains("disk is full", true) -> "full"
            code == 5 || code == 6 || message.contains("database is locked", true) -> "busy"
            else -> null
        })
    } catch (e: Exception) {
        throw HostFailure(e.message ?: e.javaClass.simpleName)
    }

    companion object {
        private const val BYTES = "\$bytes"
        private const val TYPE_INTEGER = 1
        private const val TYPE_FLOAT = 2
        private const val TYPE_TEXT = 3
        private const val TYPE_BLOB = 4
        private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991.0
        private val NAME = Regex("[A-Za-z0-9._-]{1,128}")
        private val CODE = Regex("""[Ee]rror code: (\d+)""")

        /**
         * The statements of [sql], which holds several one after another. A `;` inside a quoted string, a quoted
         * name or a comment does not end one. The core's SQL has no trigger bodies, which this would split.
         */
        internal fun statements(sql: String): List<String> {
            val out = ArrayList<String>()
            val current = StringBuilder()
            var at = 0
            while (at < sql.length) {
                val c = sql[at]
                when {
                    c == '\'' || c == '"' || c == '`' -> {
                        val end = closing(sql, at, c)
                        current.append(sql, at, end)
                        at = end
                        continue
                    }
                    c == '-' && sql.startsWith("--", at) -> {
                        val end = sql.indexOf('\n', at).let { if (it < 0) sql.length else it }
                        at = end
                        continue
                    }
                    c == '/' && sql.startsWith("/*", at) -> {
                        val end = sql.indexOf("*/", at + 2).let { if (it < 0) sql.length else it + 2 }
                        at = end
                        continue
                    }
                    c == ';' -> {
                        if (current.isNotBlank()) out.add(current.toString().trim())
                        current.setLength(0)
                    }
                    else -> current.append(c)
                }
                at++
            }
            if (current.isNotBlank()) out.add(current.toString().trim())
            return out
        }

        /** The index after the quote that closes the one at [start]; a doubled quote inside is part of the text. */
        private fun closing(sql: String, start: Int, quote: Char): Int {
            var at = start + 1
            while (at < sql.length) {
                if (sql[at] == quote) {
                    if (at + 1 < sql.length && sql[at + 1] == quote) at += 2
                    else return at + 1
                } else at++
            }
            return sql.length
        }
    }
}
