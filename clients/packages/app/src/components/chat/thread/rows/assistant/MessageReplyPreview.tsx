import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui";
import { memo, useContext, useState } from "react";
import { parseBrowserElementInspectionMessage } from "../../../../chat-sidebar/browserElementInspection";
import { messagePartsPlainText } from "../../inline/MessageInlineElements";
import type { ChatMessage } from "../../../model/conversationChannel";
import { parseAttachmentsBlock, parseQuotedTextBlock } from "../../../model/protocol";
import {
  ThreadDefaultActorRoleContext,
  ThreadReplyActionsContext,
} from "../../threadContexts";
import { MessageAvatar } from "../MessageAvatar";

// Memoized: inside a streaming row it would otherwise render for every
// revision of text it does not show.
export const MessageReplyPreview = memo(function MessageReplyPreview({
  sourceId,
  target,
  targetId,
}: {
  sourceId: string;
  /** Absent when the target is not loaded in this transcript. */
  target: ChatMessage | undefined;
  targetId: string;
}) {
  const context = useContext(ThreadReplyActionsContext);
  const defaultRole = useContext(ThreadDefaultActorRoleContext);
  const messagesApi = useCommaMessages();
  const [loading, setLoading] = useState(false);
  let targetText = target
    ? messagePartsPlainText(target.parts ?? [{ kind: "markdown", text: target.text }], {
        task: messagesApi.chat_ref_task(),
        unavailableTask: messagesApi.chat_ref_task_unavailable(),
      })
    : "";
  if (target?.role === "user") {
    const parsed = parseQuotedTextBlock(
      parseAttachmentsBlock(parseBrowserElementInspectionMessage(targetText).body).body
    );
    targetText = parsed.body || parsed.quotes.join(" ");
  }
  const text = target
    ? targetText.replace(/\s+/g, " ").trim().slice(0, 180) ||
      target.attachments[0]?.fileName ||
      target.attachments[0]?.title ||
      messagesApi.chat_reply_attachment()
    : context?.canLoad
      ? messagesApi.chat_reply_load_earlier()
      : messagesApi.chat_reply_unavailable();
  return (
    <button
      className="comma-chat-reply-preview"
      type="button"
      data-reply-preview-target={targetId}
      data-preview-avatar-hidden={defaultRole === "router" || undefined}
      aria-label={messagesApi.chat_reply_view({ message: text })}
      disabled={loading || (!target && !context?.canLoad)}
      aria-busy={loading || undefined}
      onPointerEnter={(event) => {
        if (
          event.pointerType !== "touch" &&
          window.matchMedia("(hover: hover) and (pointer: fine)").matches
        )
          context?.hover(sourceId);
      }}
      onPointerLeave={() => context?.leave(sourceId)}
      onFocus={(event) => {
        if (event.currentTarget.matches(":focus-visible")) context?.hover(sourceId);
      }}
      onBlur={() => context?.leave(sourceId)}
      onClick={async () => {
        setLoading(true);
        try {
          await context?.reveal(targetId, sourceId);
        } catch (error) {
          if (!(error instanceof DOMException && error.name === "AbortError")) {
            toast.error(messagesApi.chat_reply_load_failed());
          }
        } finally {
          setLoading(false);
        }
      }}
    >
      {defaultRole !== "router" ? (
        <MessageAvatar
          actorId={target?.actorId}
          createdBy={target?.createdBy}
          actorRole={
            target && target.role !== "user"
              ? (target.actorRole ?? defaultRole)
              : undefined
          }
          user={target?.role === "user"}
          unavailable={!target}
          preview
        />
      ) : null}
      <span className="comma-chat-reply-preview-bubble">{text}</span>
    </button>
  );
});
