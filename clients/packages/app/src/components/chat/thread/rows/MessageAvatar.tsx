import { useCommaMessages } from "@comma/i18n/react";
import { SparklesIcon } from "@comma/ui/components/icons";
import { cx } from "@comma/ui/components/utils";
import { useContext } from "react";
import { CommaProductMark } from "../../../CommaProductMark";
import { UserAvatar } from "../../../UserAvatar";
import type { ChatMessage } from "@comma/core/chat";
import { WorkerModelMark } from "../activity/WorkerModelMark";
import { ThreadUserAvatarContext, ThreadWorkerVendorContext } from "../threadContexts";

export function MessageAvatar({
  actorRole,
  createdBy,
  system = false,
  user = false,
  preview = false,
  unavailable = false,
}: {
  actorRole?: ChatMessage["actorRole"];
  createdBy?: string | undefined;
  /** Comma's own runtime wrote it, so it wears the Router's Comma mark. */
  system?: boolean;
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
  const workerVendor = useContext(ThreadWorkerVendorContext);
  const commaMark = actorRole === "router" || system;
  const className = cx(
    "comma-chat-assistant-source-avatar",
    commaMark && "comma-chat-assistant-router-mark",
    user && "comma-chat-user-source-avatar",
    preview && "comma-chat-reply-preview-avatar"
  );
  // A runtime message is Comma's even when it carries a Worker role.
  if (actorRole === "worker" && !system && !unavailable)
    return <WorkerModelMark className={className} vendor={workerVendor} />;
  return (
    <span aria-hidden className={className} data-unavailable={unavailable || undefined}>
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
      ) : commaMark ? (
        <CommaProductMark viewBox="2 2 16 16" />
      ) : (
        <SparklesIcon />
      )}
    </span>
  );
}
