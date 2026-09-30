import { useCommaMessages } from "@comma/i18n/react";
import { SparklesIcon, cx } from "@comma/ui";
import { useContext } from "react";
import { CommaProductMark } from "../../../CommaProductMark";
import { UserAvatar } from "../../../UserAvatar";
import type { ChatMessage } from "../../model/conversationChannel";
import { useMessageWorkerAvatar } from "../activity/useMessageWorkerAvatar";
import { ThreadUserAvatarContext } from "../threadContexts";

export function MessageAvatar({
  actorRole,
  actorId,
  createdBy,
  user = false,
  preview = false,
  unavailable = false,
}: {
  actorRole?: ChatMessage["actorRole"];
  actorId?: string | undefined;
  createdBy?: string | undefined;
  user?: boolean;
  preview?: boolean;
  unavailable?: boolean;
}) {
  const messagesApi = useCommaMessages();
  const profile = useContext(ThreadUserAvatarContext);
  // The Router's user_chat log calls its user "current"; Tasks store the ID.
  const userProfile =
    profile &&
    (!createdBy ||
      createdBy === profile.userId ||
      (createdBy === "current" && profile.currentUserAlias))
      ? profile
      : undefined;
  const style = useMessageWorkerAvatar(actorRole === "worker" ? actorId : undefined);
  return (
    <span
      aria-hidden
      className={cx(
        "comma-chat-assistant-source-avatar",
        actorRole === "router" && "comma-chat-assistant-router-mark",
        user && "comma-chat-user-source-avatar",
        preview && "comma-chat-reply-preview-avatar"
      )}
      style={style}
      data-unavailable={unavailable || undefined}
    >
      {unavailable ? null : user ? (
        <UserAvatar
          key={userProfile?.avatarUrl}
          {...(userProfile?.avatarUrl ? { avatarUrl: userProfile.avatarUrl } : {})}
          displayName={
            userProfile ? userProfile.displayName : messagesApi.chat_reply_user()
          }
          email={userProfile?.email ?? ""}
          size="xs"
        />
      ) : actorRole === "router" ? (
        <CommaProductMark viewBox="2 2 16 16" />
      ) : style ? null : (
        <SparklesIcon />
      )}
    </span>
  );
}
