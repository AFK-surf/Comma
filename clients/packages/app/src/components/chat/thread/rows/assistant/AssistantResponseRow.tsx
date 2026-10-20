import { useCommaMessages } from "@comma/i18n/react";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { cx } from "@comma/ui/components/utils";
import { memo, useContext, useMemo, type Ref } from "react";
import { fromMarkdownTree, type MarkdownTree } from "@comma/core/markdown";
import { nativePlatformClipboard } from "../../../../../nativePlatformActions";
import { useCommaUiThemeName } from "../../../../commaUiTheme";
import { useRouterDisplayName } from "../../../../router-identity/RouterIdentityProvider";
import type {
  ChatAssistantDraft,
  ChatConversationRef,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "@comma/core/chat";
import { WidgetPresence, useWidgetPresence } from "../../../dynamic-ui/widgetPresence";
import { messagePartsPlainText } from "../../inline/MessageInlineElements";
import { normalizeMessageTimestamp } from "../../layout/messageTimestamp";
import type {
  ReplyChainState,
  RowRelationshipProps,
} from "../../replies/messageRelationships";
import { MessageTaskCards } from "../../../tasks/MessageTaskCards";
import { MessageQuestionCards } from "../../../question/QuestionCard";
import { ThreadDefaultActorRoleContext } from "../../threadContexts";
import { MessageAvatar } from "../MessageAvatar";
import { MessageBlockExtras } from "../MessageBlockExtras";
import { MessageCopyAction } from "../MessageCopyAction";
import { MessageReplyPreview } from "./MessageReplyPreview";
import { useCompiledMessageMarkdown } from "./useCompiledMessageMarkdown";
import { useFrameCoalescedContent } from "./useFrameCoalescedContent";

const ChatMarkdownStream = memo(MarkdownStream);

export const AssistantResponseRow = memo(function AssistantResponseRow({
  articleRef,
  bubbleTail,
  chainState,
  draft,
  groupFirst,
  groupId,
  groupLast,
  live = false,
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
  articleRef?: Ref<HTMLElement> | undefined;
  chainState: ReplyChainState;
  draft?: ChatAssistantDraft | undefined;
  groupId: string;
  live?: boolean;
  message?: ChatMessage | undefined;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  onPreviewLocalFile?:
    | ((previewRef: ChatImagePreviewRef) => Promise<LocalFilePreview | undefined>)
    | undefined;
  referenceMode: "link" | "static";
  showActions: boolean;
  streamId: string;
  workspaceId: string;
}) {
  const messagesApi = useCommaMessages();
  const isDark = useCommaUiThemeName() === "Dark mode";
  const routerName = useRouterDisplayName();
  const relationshipId = message?.messageId ?? draft?.draftId;
  const streaming = Boolean(draft && !message);
  const activelyStreaming = streaming && draft?.status === "streaming";
  const renderedContent = useFrameCoalescedContent(
    message?.text ?? draft?.text ?? "",
    activelyStreaming
  );
  // A reply streaming in, as the core parsed it so far.
  const draftTree = streaming ? draft?.markdown : undefined;
  const draftNodes = useMemo(
    () => (draftTree ? fromMarkdownTree(draftTree as MarkdownTree) : undefined),
    [draftTree]
  );
  const compiledMessage = useCompiledMessageMarkdown(
    message,
    live,
    groupId,
    workspaceId
  );
  const defaultActorRole = useContext(ThreadDefaultActorRoleContext);
  const actorRole = message?.actorRole ?? defaultActorRole;
  const hideRouterIdentity = defaultActorRole === "router" && actorRole === "router";
  const actorSourceLabel =
    actorRole === "router" ? routerName : messagesApi.chat_actor_worker();
  // The row marks what it holds (source label, reply preview, widget) so the stylesheet
  // needs no `:has()` anchor, which Chromium re-checked for every streamed node.
  const [holdsWidget, reportWidget] = useWidgetPresence();
  const sourceLabel =
    !hideRouterIdentity && actorRole && groupFirst !== false ? (
      <div className="comma-chat-assistant-source-label">{actorSourceLabel}</div>
    ) : null;
  const replyPreview =
    replyPreviewTargetId && relationshipId ? (
      <MessageReplyPreview
        sourceId={relationshipId}
        target={replyPreviewTarget}
        targetId={replyPreviewTargetId}
      />
    ) : null;
  const markdown = (
    <ChatMarkdownStream
      animation="reveal"
      blockPresentation="bubbles"
      className="text-sm leading-5"
      clipboard={nativePlatformClipboard}
      content={compiledMessage?.content ?? renderedContent}
      final={!activelyStreaming}
      parsed={compiledMessage ? undefined : draftNodes}
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
    <>
      <MessageBlockExtras
        groupId={groupId}
        message={message}
        onOpenConversationRef={onOpenConversationRef}
        onPreviewLocalFile={onPreviewLocalFile}
        referenceMode={referenceMode}
        workspaceId={workspaceId}
      />
      <MessageTaskCards groupId={groupId} message={message} workspaceId={workspaceId} />
      <MessageQuestionCards message={message} />
    </>
  ) : null;
  return (
    <article
      ref={articleRef}
      className={cx(
        "comma-chat-message-assistant",
        streaming && "comma-chat-message-assistant--draft"
      )}
      data-message-id={relationshipId}
      data-reply-animation-key={streamId}
      data-message-created-at={
        message ? normalizeMessageTimestamp(message.createdAt) : undefined
      }
      data-reply-streaming={streaming ? "true" : undefined}
      data-reply-chain-state={chainState}
      data-reply-to-message-id={message?.replyToMessageId}
      data-message-group-first={groupFirst?.toString()}
      data-message-group-last={groupLast?.toString()}
      data-actor-role={actorRole}
      data-router-identity-hidden={hideRouterIdentity || undefined}
      data-bubble-tail={hideRouterIdentity && bubbleTail ? "left" : undefined}
      data-reply-preview={replyPreview ? true : undefined}
      data-widget={holdsWidget || undefined}
      data-slot="chat-assistant-output"
      data-testid={streaming ? "chat-assistant-draft" : undefined}
    >
      {!hideRouterIdentity && actorRole && groupLast !== false ? (
        <MessageAvatar actorRole={actorRole} />
      ) : null}
      {replyPreview}
      <div
        className="comma-chat-assistant-response-body"
        data-source-label={sourceLabel ? true : undefined}
        data-widget={holdsWidget || undefined}
      >
        {sourceLabel}
        <WidgetPresence value={reportWidget}>{markdown}</WidgetPresence>
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
