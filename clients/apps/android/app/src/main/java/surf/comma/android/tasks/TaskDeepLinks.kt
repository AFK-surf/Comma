package surf.comma.android.tasks

import android.net.Uri

/**
 * A Task deep link (`<scheme>://task?workspace=<ws>&group=<group>&task=<task>`) opens
 * that Task in Comma. Navigation hint only: the workspace must belong to the signed-in
 * account, and the server authorizes access.
 */
data class TaskDeepLink(
    val workspaceId: String,
    val groupId: String,
    val taskId: String,
)

object TaskDeepLinks {
    private const val MAX_ID_LENGTH = 256

    fun parse(url: Uri, expectedScheme: String): TaskDeepLink? {
        if (url.scheme != expectedScheme || url.host != "task") return null
        if (url.port != -1 || url.userInfo != null || url.fragment != null) return null
        val path = url.path
        if (!path.isNullOrEmpty() && path != "/") return null
        val workspace = validId(url.getQueryParameter("workspace")) ?: return null
        val group = validId(url.getQueryParameter("group")) ?: return null
        val task = validId(url.getQueryParameter("task")) ?: return null
        return TaskDeepLink(workspaceId = workspace, groupId = group, taskId = task)
    }

    private fun validId(value: String?): String? {
        if (value.isNullOrEmpty() || value.length > MAX_ID_LENGTH || value == "." || value == "..") return null
        return value.takeIf { it.all(::isSafeIdChar) }
    }

    private fun isSafeIdChar(c: Char): Boolean =
        c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '_' || c == '.' || c == ':' || c == '-'
}
