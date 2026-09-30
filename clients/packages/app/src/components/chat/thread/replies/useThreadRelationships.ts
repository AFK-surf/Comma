import { useCallback, useMemo } from "react";
import type { CommaApiClient, CommaConversationKind } from "../../../../api";
import type { ChatAssistantDraft, ChatMessage } from "../../model/conversationChannel";
import { visibleReplyIdentityKey } from "../../model/visibleReplyPresentation";
import type { ConversationLayout } from "../layout/conversationLayout";
import type { ThreadTurnWindow } from "../navigation/useThreadTurnWindow";
import type { RevealTurn } from "../navigation/useTurnReveal";
import type { useStickToBottom } from "../scroll/useStickToBottom";
import {
  messageRelationships,
  messageThreadRoots,
  type ReplyChainState,
  type RowRelationshipProps,
} from "./messageRelationships";
import { useReplyActions } from "./useReplyActions";
import type { useReplyChainHighlight } from "./useReplyChainHighlight";
import type { useReplyHistory } from "./useReplyHistory";
import { useReplyPreviewAvatar } from "./useReplyPreviewAvatar";

export function useThreadRelationships({
  api,
  assistantDraft,
  canonicalLayout,
  conversationId,
  conversationKind,
  defaultAssistantActorRole,
  follow,
  history,
  replyChain,
  revealTurn,
  turnWindow: { visibleCanonicalTurns },
}: {
  api: CommaApiClient | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  canonicalLayout: ConversationLayout;
  conversationId: string | undefined;
  conversationKind: CommaConversationKind;
  defaultAssistantActorRole: ChatMessage["actorRole"];
  follow: Pick<ReturnType<typeof useStickToBottom>, "stopFollowing">;
  history: Pick<
    ReturnType<typeof useReplyHistory>,
    "historyBoundaryMessageId" | "loadReplyTarget" | "messages"
  >;
  replyChain: ReturnType<typeof useReplyChainHighlight>;
  revealTurn: RevealTurn;
  turnWindow: Pick<ThreadTurnWindow, "visibleCanonicalTurns">;
}) {
  const { historyBoundaryMessageId, messages } = history;
  const highlightedMessageId = replyChain.messageId;
  const replyChains = useMemo(() => messageThreadRoots(messages), [messages]);
  const highlightedChain = highlightedMessageId
    ? replyChains.get(highlightedMessageId)
    : undefined;
  const replyChainState = useCallback(
    (messageId?: string): ReplyChainState =>
      highlightedChain === undefined
        ? undefined
        : messageId && replyChains.get(messageId) === highlightedChain
          ? ("active" as const)
          : ("muted" as const),
    [highlightedChain, replyChains]
  );
  // Reply geometry depends on the draft's presence and parent, not its growing
  // body. Keep that projection stable while text arrives so completed rows and
  // their geometry observers do not restart for every chunk.
  const draftId = assistantDraft?.draftId;
  const draftParentId = assistantDraft?.sourceMessageIds.at(-1);
  const draftHasText = Boolean(assistantDraft?.text);
  const draftBindingKey = assistantDraft
    ? visibleReplyIdentityKey(
        assistantDraft.responseKey,
        assistantDraft.sourceMessageIds
      )
    : undefined;
  const draftRelationship = useMemo<ChatMessage | undefined>(() => {
    if (!draftId || !draftParentId || !draftHasText || !draftBindingKey)
      return undefined;
    const parent = messages.find((item) => item.messageId === draftParentId);
    return {
      messageId: draftId,
      role: "assistant",
      text: "",
      parts: [],
      attachments: [],
      refs: [],
      createdAt: 0,
      delivery: "sent",
      source: "server",
      status: "streaming",
      replyToMessageId: draftParentId,
      threadRootMessageId: parent?.threadRootMessageId ?? draftParentId,
    };
  }, [draftId, draftParentId, draftHasText, draftBindingKey, messages]);
  const relationships = useMemo(() => {
    const visibleMessages = visibleCanonicalTurns.flatMap((turn) =>
      turn.entries.flatMap((entry) => (entry.message ? [entry.message] : []))
    );
    if (draftRelationship) visibleMessages.push(draftRelationship);
    const layout = messageRelationships(
      visibleMessages,
      new Set([
        ...visibleCanonicalTurns.flatMap((turn) =>
          turn.timestamp ? [turn.timestamp.messageId] : []
        ),
        ...(historyBoundaryMessageId ? [historyBoundaryMessageId] : []),
      ])
    );
    const tailMessageIds = new Set(
      visibleMessages
        .filter((message, index) => {
          const next = visibleMessages[index + 1];
          return (
            !next ||
            message.role !== next.role ||
            (message.role === "user" && message.createdBy !== next.createdBy)
          );
        })
        .map((message) => message.messageId)
    );
    return { ...layout, tailMessageIds };
  }, [draftRelationship, historyBoundaryMessageId, visibleCanonicalTurns]);
  // Stays the same object while only the draft changes.
  const messageById = useMemo(
    () => new Map(messages.map((message) => [message.messageId, message])),
    [messages]
  );
  const rowRelationshipProps = useCallback(
    (relationshipId: string | undefined): RowRelationshipProps => {
      if (!relationshipId) return { bubbleTail: false };
      const position = relationships.positions.get(relationshipId);
      const reply = relationships.replies.get(relationshipId);
      const replyPreviewTargetId =
        reply?.presentation === "preview" ? reply.targetId : undefined;
      return {
        bubbleTail: relationships.tailMessageIds.has(relationshipId),
        groupFirst: position?.first,
        groupLast: position?.last,
        replyPreviewTarget: replyPreviewTargetId
          ? messageById.get(replyPreviewTargetId)
          : undefined,
        replyPreviewTargetId,
      };
    },
    [messageById, relationships]
  );
  const replyActions = useReplyActions({
    api,
    canonicalLayout,
    conversationId,
    follow,
    history,
    replyChain,
    revealTurn,
  });
  const userAvatar = useReplyPreviewAvatar({
    conversationKind,
    defaultAssistantActorRole,
    messageById,
    replies: relationships.replies,
  });
  return {
    highlightedChain,
    relationships,
    replyActions,
    replyChainState,
    rowRelationshipProps,
    userAvatar,
  };
}
