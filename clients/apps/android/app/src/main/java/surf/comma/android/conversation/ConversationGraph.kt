package surf.comma.android.conversation

import android.content.Context
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository

/** Builds the main chat's [ChatView]. The caller owns its lifetime and calls [ChatView.start]. */
object ConversationGraph {
    fun create(context: Context, auth: AuthRepository): ChatView =
        ChatView(AuthConversationSessions(auth), AuthGraph.core(context))

}
