import { useCommaMessages } from "@comma/i18n/react";
import { cx } from "@comma/ui/components/utils";
import { plainTextWithLinks } from "@comma/ui/components/markdown-stream/plainTextLinks";
import { memo, useCallback, useContext, type Ref } from "react";
import {
  QUICK_CHAT_MESSAGE_TYPE,
  type ChatConversationRef,
  type ChatImagePreviewRef,
  type ChatMessage,
  type LocalFilePreview,
} from "@comma/core/chat";
import { userMessageContentWithMentions } from "../inline/MessageInlineElements";
import type { OutgoingPresentation } from "../outgoing/outgoingPresentation";
import type {
  ReplyChainState,
  RowRelationshipProps,
} from "../replies/messageRelationships";
import { ThreadDefaultActorRoleContext } from "../threadContexts";
import { CommaAuthContext } from "../../../auth-context";
import { UserAvatar } from "../../../UserAvatar";
import { usePeopleAvatars, usePersonName } from "../../../people/usePersonName";
import { useAvatarUrl } from "../../../useProfileAvatarUrl";
import { AssistantResponseRow } from "./assistant/AssistantResponseRow";
import { MessageBlockExtras } from "./MessageBlockExtras";
import { MessageCopyAction } from "./MessageCopyAction";
import { FailedDeliveryNotice } from "./user/FailedDeliveryNotice";
import { MessageAttachedTexts } from "./user/MessageAttachedTexts";
import { MessageQuoteBlocks } from "./user/MessageQuoteBlocks";
import {
  mergeMessageAttachments,
  textAttachmentsToPills,
} from "./user/messageTextAttachments";
import { UserMessageBubble } from "./user/UserMessageBubble";
import {
  MessagePlatformBadge,
  messageBubblePlatform,
  otherClientSource,
} from "../../MessagePlatformBadge";
import { MessageTaskCards } from "../../tasks/MessageTaskCards";
import { TaskRunBlockedCard } from "../../tasks/TaskRunBlockedCard";
import { TASK_RUN_BLOCKED } from "../../tasks/taskRunSwitch";

/** The row a message renders as: every role but "assistant" draws the user row. */
export function messageRowRole(message: Pick<ChatMessage, "role">) {
  return message.role === "assistant" ? "assistant" : "user";
}

// Rows are memoized so per-emit thread renders (every keystroke and stream
// chunk) reconcile only rows whose message/draft actually changed. All
// callback props must stay identity-stable for these boundaries to hold.
export const MessageRow = memo(function MessageRow({
  articleRef,
  groupId,
  live = false,
  message,
  onAnchorOutgoingTurn,
  onDiscard,
  onOutgoingAnimationComplete,
  onOpenConversationRef,
  onPreviewLocalFile,
  onRetry,
  outgoingPresentation,
  referenceMode,
  showActions = true,
  workspaceId,
  // This row's place in the thread; an assistant message hands it on as is.
  ...relationship
}: RowRelationshipProps & {
  articleRef?: Ref<HTMLElement> | undefined;
  chainState: ReplyChainState;
  groupId: string;
  /** The row shows the core's live data (inline Tasks, widgets); a static row does not. */
  live?: boolean;
  message: ChatMessage;
  onAnchorOutgoingTurn?: ((turnKey: string) => void) | undefined;
  onDiscard: (clientRequestId: string) => void;
  onOutgoingAnimationComplete?: ((launchId: number) => void) | undefined;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  onPreviewLocalFile?:
    | ((previewRef: ChatImagePreviewRef) => Promise<LocalFilePreview | undefined>)
    | undefined;
  onRetry: (clientRequestId: string) => void;
  outgoingPresentation?: OutgoingPresentation | undefined;
  referenceMode: "link" | "static";
  showActions?: boolean;
  workspaceId: string;
}) {
  const messagesApi = useCommaMessages();
  // The core reads a person's message out of its wire text; one from another platform is shown as it came.
  const parsed = message.display ?? { body: message.text, quotes: [], files: [] };
  const displayBody = parsed.command ? `/${parsed.command}` : parsed.body;
  const defaultActorRole = useContext(ThreadDefaultActorRoleContext);
  // A chat platform, or another Comma app the person sent it from.
  const sourceBadge = message.platformSource ?? otherClientSource(message.clientSource);
  const renderUserContent = useCallback(
    (body: string) =>
      message.platformSource
        ? plainTextWithLinks(body)
        : userMessageContentWithMentions(body, {
            live,
            groupId,
            workspaceId,
          }),
    [groupId, live, message.platformSource, workspaceId]
  );
  const parsedAttachments = textAttachmentsToPills(parsed.files);
  const mergedAttachments = mergeMessageAttachments(
    message.attachments,
    parsedAttachments
  );
  const messageForExtras =
    mergedAttachments !== message.attachments
      ? { ...message, attachments: mergedAttachments }
      : message;
  const quickChat = message.messageType === QUICK_CHAT_MESSAGE_TYPE;
  // In a Task together, another person's message: on the left, under their face and name, not in the account's own
  // bubble. The Router's chat calls its one user "current"; a Task stores each writer's user id.
  const auth = useContext(CommaAuthContext);
  // A page with no account (a guest's) has no writer of its own: each one it names is someone else.
  const otherWriter =
    message.role === "user" &&
    message.createdBy &&
    message.createdBy !== "current" &&
    message.createdBy !== auth?.userId
      ? message.createdBy
      : undefined;
  // A guest who joined by an email link has no account: the name they gave comes with the message, as every
  // writer's does on a guest's own page, where there is no People to look them up in.
  const guest = otherWriter?.startsWith("guest:") ?? false;
  const named = guest || Boolean(message.authorName);
  const otherName =
    usePersonName(named ? undefined : otherWriter) ?? message.authorName;
  const otherAvatar = usePeopleAvatars(Boolean(otherWriter) && !named)(
    named ? undefined : otherWriter
  );
  const otherAvatarUrl = useAvatarUrl(otherAvatar ?? undefined);
  const changedName = usePersonName(message.memberChange?.userId);

  // A Task together's line for its people: someone left it or was taken out.
  if (message.memberChange)
    return (
      <article
        ref={articleRef}
        className="comma-chat-member-change"
        data-message-id={message.messageId}
        data-source={message.source}
      >
        {(message.memberChange.status === "left"
          ? messagesApi.people_member_left_line
          : messagesApi.people_member_removed_line)({
          name: changedName ?? messagesApi.people_member_unnamed(),
        })}
      </article>
    );

  // A Task's model that could not start: one card with why and, while it stands, the model to switch to.
  if (message.messageType === TASK_RUN_BLOCKED)
    return (
      <article
        ref={articleRef}
        className="comma-task-run-blocked-row"
        data-message-id={message.messageId}
        data-source={message.source}
      >
        <TaskRunBlockedCard message={message} />
      </article>
    );

  if (messageRowRole(message) === "assistant") {
    return (
      <AssistantResponseRow
        {...relationship}
        live={live}
        articleRef={articleRef}
        groupId={groupId}
        message={message}
        onOpenConversationRef={onOpenConversationRef}
        onPreviewLocalFile={onPreviewLocalFile}
        referenceMode={referenceMode}
        showActions={showActions}
        streamId={message.messageId}
        workspaceId={workspaceId}
      />
    );
  }

  return (
    <article
      ref={articleRef}
      className={cx(
        "comma-chat-message-user",
        otherWriter && "comma-chat-message-other",
        message.delivery === "failed" && "comma-chat-message-failed"
      )}
      data-delivery={message.delivery}
      data-message-id={message.messageId}
      data-reply-chain-state={relationship.chainState}
      data-slot="chat-user-output"
      data-bubble-tail={
        defaultActorRole === "router" && relationship.bubbleTail ? "right" : undefined
      }
      data-source={message.source}
    >
      {/* Another person's message sits as an Agent's does: their face in the avatar gutter beside the bubble's foot
          (so a reply to it joins face to face), their name over the bubble's text. A run of their messages wears the
          face once, at its foot, and the name once, over its first. */}
      {otherWriter ? (
        <>
          {relationship.groupLast !== false ? (
            <span
              aria-hidden
              className="comma-chat-assistant-source-avatar comma-chat-user-source-avatar"
            >
              <UserAvatar
                {...(otherAvatarUrl ? { avatarUrl: otherAvatarUrl } : {})}
                displayName={otherName ?? (guest ? "@" : "")}
                email=""
                size="xs"
              />
            </span>
          ) : null}
          {relationship.groupFirst !== false ? (
            <div className="comma-chat-assistant-source-label">
              {otherName ??
                (guest
                  ? messagesApi.collab_guest_member_placeholder_guest()
                  : messagesApi.chat_reply_user())}
              {guest && otherName ? (
                <span className="text-quaternary">
                  {" "}
                  · {messagesApi.people_member_guest_tag()}
                </span>
              ) : null}
            </div>
          ) : null}
        </>
      ) : null}
      {/* iMessage-style stack: images, then quotes, then file pills and
          conversation refs, with the bubble last so it lands nearest the
          composer it flew out of. */}
      <MessageBlockExtras
        groupId={groupId}
        message={messageForExtras}
        onOpenConversationRef={onOpenConversationRef}
        onPreviewLocalFile={onPreviewLocalFile}
        placement="leading"
        referenceMode={referenceMode}
        section="images"
        workspaceId={workspaceId}
      />
      <MessageQuoteBlocks messageId={message.messageId} quotes={parsed.quotes} />
      <MessageAttachedTexts messageId={message.messageId} texts={parsed.texts ?? []} />
      <MessageBlockExtras
        groupId={groupId}
        message={messageForExtras}
        onOpenConversationRef={onOpenConversationRef}
        onPreviewLocalFile={onPreviewLocalFile}
        placement="leading"
        referenceMode={referenceMode}
        section="files"
        workspaceId={workspaceId}
      />
      {parsed.body.trim() ? (
        <div className="comma-chat-user-bubble-row">
          <UserMessageBubble
            onAnchorOutgoingTurn={onAnchorOutgoingTurn}
            onOutgoingAnimationComplete={onOutgoingAnimationComplete}
            outgoingPresentation={outgoingPresentation}
            platform={messageBubblePlatform(message)}
            renderContent={renderUserContent}
            text={displayBody}
          />
          {showActions ? (
            <MessageCopyAction
              ariaLabel={messagesApi.chat_copy_message()}
              copyText={parsed.body}
              messageId={message.messageId}
              platform={sourceBadge}
            />
          ) : sourceBadge ? (
            // Read-only surfaces (previews, shares) drop Copy but
            // still name where the message came from.
            <div className="comma-chat-message-actions">
              <MessagePlatformBadge platform={sourceBadge} />
            </div>
          ) : null}
        </div>
      ) : null}
      {/* Stored Quick Chat messages can still carry references to their Tasks. */}
      {quickChat ? (
        <MessageTaskCards
          groupId={groupId}
          message={message}
          workspaceId={workspaceId}
        />
      ) : null}
      {message.delivery === "failed" && message.clientRequestId ? (
        <FailedDeliveryNotice
          message={message}
          onDiscard={onDiscard}
          onRetry={onRetry}
        />
      ) : null}
    </article>
  );
});
