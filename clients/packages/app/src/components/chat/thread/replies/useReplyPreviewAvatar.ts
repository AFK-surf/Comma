import { useContext, useMemo } from "react";
import type { CommaConversationKind } from "../../../../api";
import { CommaAuthContext } from "../../../auth-context";
import { useProfileAvatarUrl } from "../../../useProfileAvatarUrl";
import type { ChatMessage } from "../../model/conversationChannel";
import type { MessageReply } from "./messageRelationships";

export function useReplyPreviewAvatar({
  conversationKind,
  defaultAssistantActorRole,
  messageById,
  replies,
}: {
  conversationKind: CommaConversationKind;
  defaultAssistantActorRole: ChatMessage["actorRole"];
  messageById: ReadonlyMap<string, ChatMessage>;
  replies: ReadonlyMap<string, MessageReply>;
}) {
  const auth = useContext(CommaAuthContext);
  // One profile image request per transcript, shared by all its user previews.
  const hasUserReplyPreview =
    defaultAssistantActorRole !== "router" &&
    [...replies.values()].some(
      (reply) =>
        reply.presentation === "preview" &&
        messageById.get(reply.targetId)?.role === "user"
    );
  const userAvatarUrl = useProfileAvatarUrl(
    hasUserReplyPreview ? auth?.avatarRevision : undefined
  );
  return useMemo(
    () =>
      auth
        ? {
            ...(userAvatarUrl ? { avatarUrl: userAvatarUrl } : {}),
            displayName: auth.userDisplayName,
            email: auth.userEmail,
            currentUserAlias: conversationKind === "user_chat",
            userId: auth.userId,
          }
        : undefined,
    [auth, conversationKind, userAvatarUrl]
  );
}
