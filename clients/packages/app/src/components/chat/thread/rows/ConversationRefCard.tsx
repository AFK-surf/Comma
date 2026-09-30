import { useCommaMessages } from "@comma/i18n/react";
import { ChevronRightSmallIcon, FileIcon, ListChecksIcon } from "@comma/ui";
import { Link } from "@tanstack/react-router";
import type { ChatConversationRef } from "../../model/conversationChannel";

export function ConversationRefCard({
  conversationRef,
  groupId,
  mode,
  onOpen,
  workspaceId,
}: {
  conversationRef: ChatConversationRef;
  groupId: string;
  mode: "link" | "static";
  onOpen?: ((conversationRef: ChatConversationRef) => void) | undefined;
  workspaceId: string;
}) {
  const messagesApi = useCommaMessages();
  const taskLike = conversationRef.kind === "agent_task";
  const Icon = taskLike ? ListChecksIcon : FileIcon;
  const label = taskLike
    ? messagesApi.chat_ref_task()
    : messagesApi.chat_ref_conversation();
  const title = conversationRef.title ?? messagesApi.chat_ref_fallback();
  const ariaLabel = messagesApi.chat_ref_aria({ title, type: label });

  const content = (
    <>
      <span className="comma-chat-ref-card-icon" aria-hidden>
        <Icon className="size-4" />
      </span>
      <span className="comma-chat-ref-card-copy">
        <span className="comma-chat-ref-card-label">{label}</span>
        <span className="comma-chat-ref-card-title">{title}</span>
      </span>
      <ChevronRightSmallIcon className="comma-chat-ref-card-chevron size-4" />
    </>
  );

  if (mode === "static") {
    if (taskLike && onOpen) {
      return (
        <button
          aria-label={`${label}: ${title}`}
          className="comma-chat-ref-card"
          data-testid={`chat-ref-card-${conversationRef.conversationId}`}
          onClick={() => onOpen(conversationRef)}
          type="button"
        >
          {content}
        </button>
      );
    }
    return (
      <div
        aria-label={ariaLabel}
        className="comma-chat-ref-card"
        data-testid={`chat-ref-card-${conversationRef.conversationId}`}
      >
        {content}
      </div>
    );
  }

  if (taskLike && onOpen) {
    return (
      <button
        aria-label={`${label}: ${title}`}
        className="comma-chat-ref-card"
        data-testid={`chat-ref-card-${conversationRef.conversationId}`}
        onClick={() => onOpen(conversationRef)}
        type="button"
      >
        {content}
      </button>
    );
  }

  return (
    <Link
      aria-label={ariaLabel}
      className="comma-chat-ref-card"
      data-testid={`chat-ref-card-${conversationRef.conversationId}`}
      params={{
        conversationId: conversationRef.conversationId,
        groupId,
        workspaceId,
      }}
      to="/inbox/$workspaceId/$groupId/$conversationId"
    >
      {content}
    </Link>
  );
}
