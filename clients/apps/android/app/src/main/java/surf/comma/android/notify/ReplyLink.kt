package surf.comma.android.notify

import android.content.Context
import android.content.Intent
import surf.comma.android.MainActivity
import surf.comma.android.auth.ConversationScope
import java.security.MessageDigest

/**
 * Where a reply notification leads: a conversation of one account, at one timeline entry. The
 * account travels only as [accountTag], a one-way hash, so the intent carries no identifier.
 */
internal data class ReplyLink(val accountTag: String, val conversationId: String, val entryKey: String) {
    /** The entry to scroll to, or null when the link belongs to another account or conversation. */
    fun targetFor(scope: ConversationScope?): String? =
        entryKey.takeIf { scope != null && accountTag(scope.accountId) == accountTag && scope.conversationId == conversationId }

    fun intent(context: Context): Intent = Intent(context, MainActivity::class.java)
        .setAction(ACTION)
        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        .putExtra(EXTRA_ACCOUNT, accountTag)
        .putExtra(EXTRA_CONVERSATION, conversationId)
        .putExtra(EXTRA_ENTRY, entryKey)

    companion object {
        const val ACTION = "surf.comma.android.action.OPEN_REPLY"
        private const val EXTRA_ACCOUNT = "reply.account"
        private const val EXTRA_CONVERSATION = "reply.conversation"
        private const val EXTRA_ENTRY = "reply.entry"

        fun of(notice: ReplyNotice) = ReplyLink(accountTag(notice.accountId), notice.conversationId, notice.entryKey)

        fun from(intent: Intent?): ReplyLink? {
            if (intent?.action != ACTION) return null
            return ReplyLink(
                intent.getStringExtra(EXTRA_ACCOUNT) ?: return null,
                intent.getStringExtra(EXTRA_CONVERSATION) ?: return null,
                intent.getStringExtra(EXTRA_ENTRY) ?: return null,
            )
        }
    }
}

/** A short one-way tag of an account id, for notification tags and links. */
internal fun accountTag(accountId: String): String =
    MessageDigest.getInstance("SHA-256").digest(accountId.toByteArray(Charsets.UTF_8))
        .take(12).joinToString("") { "%02x".format(it) }

/** One notification per conversation: the same tag replaces the previous reply's notification. */
internal fun replyTag(accountTag: String, conversationId: String) = "$REPLY_TAG_PREFIX$accountTag:$conversationId"

internal fun replyTagAccount(tag: String?): String? =
    tag?.takeIf { it.startsWith(REPLY_TAG_PREFIX) }?.removePrefix(REPLY_TAG_PREFIX)?.substringBefore(':')

private const val REPLY_TAG_PREFIX = "reply:"
