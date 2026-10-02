import { useCommaMessages } from "@comma/i18n/react";
import { MarkdownStream, cx } from "@comma/ui";
import { memo, useContext, useState, type Ref } from "react";
import type { CommaApiClient } from "../../../../../api";
import { nativePlatformClipboard } from "../../../../../runtime-chat/nativePlatformActions";
import { useCommaUiThemeName } from "../../../../commaUiTheme";
import { useRouterDisplayName } from "../../../../router-identity/RouterIdentityProvider";
import type {
  ChatAssistantDraft,
  ChatConversationRef,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "../../../model/conversationChannel";
import { messagePartsPlainText } from "../../inline/MessageInlineElements";
import { normalizeMessageTimestamp } from "../../layout/messageTimestamp";
import type {
  ReplyChainState,
  RowRelationshipProps,
} from "../../replies/messageRelationships";
import { ThreadDefaultActorRoleContext } from "../../threadContexts";
import { MessageAvatar } from "../MessageAvatar";
import { MessageBlockExtras } from "../MessageBlockExtras";
import { MessageCopyAction } from "../MessageCopyAction";
import { MessageReplyPreview } from "./MessageReplyPreview";
import { useCompiledMessageMarkdown } from "./useCompiledMessageMarkdown";
import { useFrameCoalescedContent } from "./useFrameCoalescedContent";

const ChatMarkdownStream = memo(MarkdownStream);

export const AssistantResponseRow = memo(function AssistantResponseRow({
  api,
  animateEntry,
  articleRef,
  bubbleTail,
  chainState,
  draft,
  groupFirst,
  groupId,
  groupLast,
  message,
  onOpenConversationRef,
  onPreviewLocalFile,
  referenceMode,
  replyPreviewTarget,
  replyPreviewTargetId,
  showActions,
  streamId,
  workspaceId,
}: RowRelationshipProps & {
  api?: CommaApiClient | undefined;
  animateEntry: boolean;
  articleRef?: Ref<HTMLElement> | undefined;
  chainState: ReplyChainState;
  draft?: ChatAssistantDraft | undefined;
  groupId: string;
  message?: ChatMessage | undefined;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  onPreviewLocalFile?:
    | ((previewRef: ChatImagePreviewRef) => Promise<LocalFilePreview | undefined>)
    | undefined;
  referenceMode: "link" | "static";
  showActions: boolean;
  streamId: string;
  variant?: "default" | "side-chat";
  workspaceId: string;
}) {
  const messagesApi = useCommaMessages();
  const isDark = useCommaUiThemeName() === "Dark mode";
  const routerName = useRouterDisplayName();
  const relationshipId = message?.messageId ?? draft?.draftId;
  // Only a newly mounted canonical row enters. Committing an existing draft,
  // and later renders of that completed row, cannot restart its entrance.
  const [animateOnMount] = useState(() => animateEntry && !draft);
  const streaming = Boolean(draft && !message);
  const activelyStreaming = streaming && draft?.status === "streaming";
  const renderedContent = useFrameCoalescedContent(
    message?.text ?? draft?.text ?? "",
    activelyStreaming
  );
  const compiledMessage = useCompiledMessageMarkdown(
    message,
    api,
    groupId,
    workspaceId
  );
  const defaultActorRole = useContext(ThreadDefaultActorRoleContext);
  const actorRole = message?.actorRole ?? defaultActorRole;
  const hideRouterIdentity = defaultActorRole === "router" && actorRole === "router";
  const actorSourceLabel =
    actorRole === "router" ? routerName : messagesApi.chat_actor_worker();
  const markdown = (
    <ChatMarkdownStream
      animation="reveal"
      blockPresentation="bubbles"
      className="text-sm leading-5"
      clipboard={nativePlatformClipboard}
      content={compiledMessage?.content ?? renderedContent}
      final={!activelyStreaming}
      isDark={isDark}
      showCursor={false}
      smoothStreaming={false}
      streamId={streamId}
      {...(compiledMessage
        ? {
            inlineElements: compiledMessage.inlineElements,
            nodes: compiledMessage.nodes,
          }
        : {})}
    />
  );
  const extras = message ? (
    <MessageBlockExtras
      groupId={groupId}
      message={message}
      onOpenConversationRef={onOpenConversationRef}
      onPreviewLocalFile={onPreviewLocalFile}
      referenceMode={referenceMode}
      workspaceId={workspaceId}
    />
  ) : null;
  return (
    <article
      ref={articleRef}
      className={cx(
        "comma-chat-message-assistant",
        streaming && "comma-chat-message-assistant--draft",
        animateOnMount && "comma-side-chat-assistant-entry"
      )}
      data-message-id={relationshipId}
      data-reply-animation-key={streamId}
      data-message-created-at={
        message ? normalizeMessageTimestamp(message.createdAt) : undefined
      }
      data-reply-streaming={streaming ? "true" : undefined}
      data-reply-chain-state={chainState}
      data-reply-to-message-id={message?.replyToMessageId}
      data-message-group-first={
        groupFirst === undefined ? undefined : String(groupFirst)
      }
      data-message-group-last={groupLast === undefined ? undefined : String(groupLast)}
      data-actor-role={actorRole}
      data-router-identity-hidden={hideRouterIdentity || undefined}
      data-bubble-tail={hideRouterIdentity && bubbleTail ? "left" : undefined}
      data-slot="chat-assistant-output"
      data-testid={streaming ? "chat-assistant-draft" : undefined}
    >
      {!hideRouterIdentity && actorRole && groupLast !== false ? (
        <MessageAvatar actorId={message?.actorId} actorRole={actorRole} />
      ) : null}
      {replyPreviewTargetId && relationshipId ? (
        <MessageReplyPreview
          sourceId={relationshipId}
          target={replyPreviewTarget}
          targetId={replyPreviewTargetId}
        />
      ) : null}
      <div className="comma-chat-assistant-response-body">
        {!hideRouterIdentity && actorRole && groupFirst !== false ? (
          <div className="comma-chat-assistant-source-label">{actorSourceLabel}</div>
        ) : null}
        {markdown}
        {extras}
        {showActions && message ? (
          <MessageCopyAction
            ariaLabel={messagesApi.chat_copy_reply()}
            copyText={
              message.platformSource
                ? message.text
                : messagePartsPlainText(
                    message.parts ?? [{ kind: "markdown", text: message.text }],
                    {
                      task: messagesApi.chat_ref_task(),
                      unavailableTask: messagesApi.chat_ref_task_unavailable(),
                    }
                  )
            }
            messageId={message.messageId}
          />
        ) : null}
      </div>
    </article>
  );
});
