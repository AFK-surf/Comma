package surf.comma.android.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Applies the ops a topic's delta carries to [value], as the core's own UI client does: `set`, `append`, `extend` (a
 * string's added end) and `remove` at a path of object keys and array indexes, and the keyed ones that change one item of a list found by
 * its key (`put`, `patch`, `drop`, `move`). An op whose path does not fit the value is skipped.
 *
 * Nothing of [value] is changed: the result shares every object and array the ops did not reach, and has new ones
 * along each path they did. A reader can so tell what changed by identity, and keep what it read of the rest.
 */
internal fun applyDelta(value: Any?, ops: JSONArray): Any? {
    var root = value
    for (index in 0 until ops.length()) {
        val op = ops.optJSONObject(index) ?: continue
        val path = op.optJSONArray("path") ?: continue
        root = applyPath(root, path, 0, op)
    }
    return root
}

/** [holder] with [op] applied at the rest of [path] from [at]; [holder] itself when the op does not fit. */
private fun applyPath(holder: Any?, path: JSONArray, at: Int, op: JSONObject): Any? {
    if (at == path.length()) return applyAt(holder, op)
    val key = path.get(at)
    val last = at == path.length() - 1
    return when {
        holder is JSONObject && key is String -> when {
            last && op.has("remove") -> if (holder.has(key)) copy(holder).apply { remove(key) } else holder
            // A missing last key is made by a `set`; anything else needs what is there.
            !holder.has(key) && !(last && op.has("set")) -> holder
            else -> {
                val old = holder.opt(key)
                val next = applyPath(old, path, at + 1, op)
                if (next === old) holder else copy(holder).put(key, next ?: JSONObject.NULL)
            }
        }
        holder is JSONArray && key is Int && key < holder.length() && !(last && op.has("remove")) -> {
            val old = holder.opt(key)
            val next = applyPath(old, path, at + 1, op)
            if (next === old) holder else copy(holder).put(key, next ?: JSONObject.NULL)
        }
        else -> holder
    }
}

/** [target] after an op that changes the value at its path itself. */
private fun applyAt(target: Any?, op: JSONObject): Any? = when {
    op.has("set") -> op.get("set")
    op.has("append") -> (target as? JSONArray)?.let { list ->
        val items = op.optJSONArray("append") ?: return target
        copy(list).apply { for (index in 0 until items.length()) put(items.get(index)) }
    } ?: target
    op.has("extend") -> (target as? String)?.let { it + op.optString("extend") } ?: target
    op.has("key") -> (target as? JSONArray)?.let { keyed(it, op) } ?: target
    else -> target
}

private fun copy(from: JSONObject): JSONObject = JSONObject().apply { for (key in from.keys()) put(key, from.get(key)) }
private fun copy(from: JSONArray): JSONArray = JSONArray().apply { for (index in 0 until from.length()) put(from.get(index)) }

/** An item's key as text, to compare: the one field's value, or the fields' values in order. */
private fun keyText(item: Any?, fields: JSONArray): String {
    fun field(name: String): Any = (item as? JSONObject)?.opt(name) ?: JSONObject.NULL
    return if (fields.length() == 1) text(field(fields.getString(0)))
    else text(JSONArray().apply { for (index in 0 until fields.length()) put(field(fields.getString(index))) })
}

private fun text(key: Any?): String = when (key) {
    null, JSONObject.NULL -> "null"
    is String -> JSONObject.quote(key)
    // 3 and 3.0 are the same key however the JSON reader typed them.
    is Number -> key.toDouble().let { if (it == Math.rint(it)) it.toLong().toString() else it.toString() }
    is JSONArray -> (0 until key.length()).joinToString(",", "[", "]") { text(key.get(it)) }
    else -> key.toString()
}

/** One keyed op on [list]: the list after it (a new one), or [list] itself when the op does not fit. */
private fun keyed(list: JSONArray, op: JSONObject): JSONArray {
    val fields = op.getJSONArray("key")
    val items = ArrayList<Any?>(list.length() + 1)
    for (index in 0 until list.length()) items.add(list.get(index))
    fun find(key: Any?): Int {
        val want = text(key)
        return items.indexOfFirst { keyText(it, fields) == want }
    }
    fun place(item: Any?, before: Any?) {
        val at = if (before == null || before === JSONObject.NULL) -1 else find(before)
        if (at < 0) items.add(item) else items.add(at, item)
    }
    when {
        op.has("drop") -> {
            val at = find(op.get("drop"))
            if (at < 0) return list
            items.removeAt(at)
        }
        op.has("patch") -> {
            val at = find(op.get("patch"))
            if (at < 0) return list
            items[at] = applyDelta(items[at], op.optJSONArray("ops") ?: JSONArray())
        }
        op.has("move") -> {
            val at = find(op.get("move"))
            if (at < 0) return list
            place(items.removeAt(at), op.opt("before"))
        }
        op.has("put") -> {
            val item = op.get("put")
            val want = keyText(item, fields)
            val at = items.indexOfFirst { keyText(it, fields) == want }
            if (at >= 0 && !op.has("before")) items[at] = item
            else {
                if (at >= 0) items.removeAt(at)
                place(item, op.opt("before"))
            }
        }
        else -> return list
    }
    return JSONArray().apply { for (item in items) put(item ?: JSONObject.NULL) }
}
