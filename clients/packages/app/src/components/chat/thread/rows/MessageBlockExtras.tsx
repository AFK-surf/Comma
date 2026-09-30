import type {
  ChatConversationRef,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "../../model/conversationChannel";
import { MessageAttachments } from "../attachments/MessageAttachments";
import { ConversationRefCard } from "./ConversationRefCard";

export function MessageBlockExtras({
  groupId,
  message,
  onOpenConversationRef,
  onPreviewLocalFile,
  placement = "trailing",
  referenceMode,
  section = "all",
  workspaceId,
}: {
  groupId: string;
  message: ChatMessage;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  onPreviewLocalFile?:
    | ((previewRef: ChatImagePreviewRef) => Promise<LocalFilePreview | undefined>)
    | undefined;
  /** Leading extras precede the bubble and carry their gap below instead of above. */
  placement?: "leading" | "trailing" | undefined;
  referenceMode: "link" | "static";
  /**
   * User turns split the extras around the quote blocks: the image group
   * leads the turn while file pills and conversation refs sit just above
   * the bubble. Attachments keep their wire positions in both sections.
   */
  section?: "all" | "files" | "images" | undefined;
  workspaceId: string;
}) {
  const showRefs = section !== "images" && message.refs.length > 0;
  const showAttachments =
    section === "images"
      ? message.attachments.some((attachment) => attachment.blockType === "image")
      : section === "files"
        ? message.attachments.some((attachment) => attachment.blockType !== "image")
        : message.attachments.length > 0;
  if (!showRefs && !showAttachments) {
    return null;
  }

  return (
    <div
      className="comma-chat-block-extras"
      data-placement={placement === "leading" ? "leading" : undefined}
    >
      {showRefs
        ? message.refs.map((conversationRef, index) => (
            <ConversationRefCard
              conversationRef={conversationRef}
              groupId={groupId}
              key={`${message.messageId}:ref:${conversationRef.conversationId}:${index}`}
              mode={referenceMode}
              onOpen={onOpenConversationRef}
              workspaceId={workspaceId}
            />
          ))
        : null}
      {showAttachments ? (
        <MessageAttachments
          attachments={message.attachments}
          messageId={message.messageId}
          onPreviewLocalFile={onPreviewLocalFile}
          section={section}
        />
      ) : null}
    </div>
  );
}
