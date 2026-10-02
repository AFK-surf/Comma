import { useCommaMessages } from "@comma/i18n/react";
import { cx, plainTextWithLinks } from "@comma/ui";
import { memo, useContext, useMemo, type Ref } from "react";
import type { CommaApiClient } from "../../../../api";
import { parseBrowserElementInspectionMessage } from "../../../chat-sidebar/browserElementInspection";
import { controlCommandDisplayText } from "./controlCommandPresentation";
import type {
  ChatConversationRef,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "../../model/conversationChannel";
import { userMessageContentWithMentions } from "../inline/MessageInlineElements";
import { parseAttachmentsBlock, parseQuotedTextBlock } from "../../model/protocol";
import type { OutgoingPresentation } from "../outgoing/outgoingPresentation";
import type {
  ReplyChainState,
  RowRelationshipProps,
} from "../replies/messageRelationships";
import { ThreadDefaultActorRoleContext } from "../threadContexts";
import { AssistantResponseRow } from "./assistant/AssistantResponseRow";
import { MessageBlockExtras } from "./MessageBlockExtras";
import { MessageCopyAction } from "./MessageCopyAction";
import { BrowserElementInspectionContextCard } from "./user/BrowserElementInspectionContextCard";
import { FailedDeliveryNotice } from "./user/FailedDeliveryNotice";
import { MessageQuoteBlocks } from "./user/MessageQuoteBlocks";
import {
  mergeMessageAttachments,
  textAttachmentsToPills,
} from "./user/messageTextAttachments";
import { UserMessageBubble } from "./user/UserMessageBubble";
import { MessagePlatformBadge } from "../../MessagePlatformBadge";

// Rows are memoized so per-emit thread renders (every keystroke and stream
// chunk) reconcile only rows whose message/draft actually changed. All
// callback props must stay identity-stable for these boundaries to hold.
export const MessageRow = memo(function MessageRow({
  api,
  animateAssistantEntry = false,
  articleRef,
  groupId,
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
  variant = "default",
  workspaceId,
  // This row's place in the thread; an assistant message hands it on as is.
  ...relationship
}: RowRelationshipProps & {
  api?: CommaApiClient | undefined;
  animateAssistantEntry?: boolean;
  articleRef?: Ref<HTMLElement> | undefined;
  chainState: ReplyChainState;
  groupId: string;
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
  variant?: "default" | "side-chat";
  workspaceId: string;
}) {
  const messagesApi = useCommaMessages();
  const inspectionMessage: ReturnType<typeof parseBrowserElementInspectionMessage> =
    message.platformSource
      ? { body: message.text }
      : parseBrowserElementInspectionMessage(message.text);
  const attachmentsBlock = message.platformSource
    ? { body: inspectionMessage.body, attachments: [] }
    : parseAttachmentsBlock(inspectionMessage.body);
  const defaultActorRole = useContext(ThreadDefaultActorRoleContext);
  // Quotes lead the wire text and attachments trail it, so peeling the
  // attachments block first leaves the quote block at the front of the body.
  const parsed = message.platformSource
    ? { body: attachmentsBlock.body, quotes: [] }
    : parseQuotedTextBlock(attachmentsBlock.body);
  const displayBody = message.platformSource
    ? parsed.body
    : controlCommandDisplayText(parsed.body);
  const userContent = useMemo(
    () =>
      message.role === "assistant"
        ? undefined
        : message.platformSource
          ? plainTextWithLinks(displayBody)
          : userMessageContentWithMentions(displayBody, {
              api,
              groupId,
              workspaceId,
            }),
    [api, displayBody, groupId, message.role, message.platformSource, workspaceId]
  );
  const parsedAttachments = textAttachmentsToPills(attachmentsBlock.attachments);
  const mergedAttachments = mergeMessageAttachments(
    message.attachments,
    parsedAttachments
  );
  const messageForExtras =
    mergedAttachments !== message.attachments
      ? { ...message, attachments: mergedAttachments }
      : message;

  if (message.role === "assistant") {
    return (
      <AssistantResponseRow
        {...relationship}
        api={api}
        animateEntry={animateAssistantEntry}
        articleRef={articleRef}
        groupId={groupId}
        message={message}
        onOpenConversationRef={onOpenConversationRef}
        onPreviewLocalFile={onPreviewLocalFile}
        referenceMode={referenceMode}
        showActions={showActions}
        streamId={message.messageId}
        variant={variant}
        workspaceId={workspaceId}
      />
    );
  }

  return (
    <article
      ref={articleRef}
      className={cx(
        "comma-chat-message-user",
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
      {inspectionMessage.context ? (
        <BrowserElementInspectionContextCard context={inspectionMessage.context} />
      ) : null}
      {parsed.body.trim() ? (
        <div className="comma-chat-user-bubble-row">
          <UserMessageBubble
            content={userContent}
            onAnchorOutgoingTurn={onAnchorOutgoingTurn}
            onOutgoingAnimationComplete={onOutgoingAnimationComplete}
            outgoingPresentation={outgoingPresentation}
            platform={message.platformSource}
            text={displayBody}
          />
          {showActions ? (
            <MessageCopyAction
              ariaLabel={messagesApi.chat_copy_message()}
              copyText={parsed.body}
              messageId={message.messageId}
              platform={message.platformSource}
            />
          ) : message.platformSource ? (
            // Read-only surfaces (side chat, previews, shares) drop Copy but
            // still name where the message came from.
            <div className="comma-chat-message-actions">
              <MessagePlatformBadge platform={message.platformSource} />
            </div>
          ) : null}
        </div>
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
