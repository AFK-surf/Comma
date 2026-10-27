import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useCall, type CallFn } from "@comma/core-client";
import type { CommaConversationKind } from "@comma/core/api-schemas";
import type { ChatMessage } from "@comma/core/chat";
import type { ReplyChainReveal } from "./useReplyChainHighlight";

export type PendingHistoryReveal = {
  scope: string;
  messageId: string;
  lifecycle?: ReplyChainReveal | undefined;
};

export function useReplyHistory({
  live,
  conversationId,
  conversationKind,
  currentMessages,
  groupId,
  historyScope,
}: {
  /** The transcript reads the core's live data; a static one loads no earlier messages. */
  live: boolean;
  conversationId: string | undefined;
  conversationKind: CommaConversationKind;
  currentMessages: ChatMessage[];
  groupId: string;
  historyScope: string;
}) {
  const call = useCall();
  const [replyHistory, setReplyHistory] = useState<{
    call: CallFn;
    scope: string;
    messages: ChatMessage[];
  }>();
  const historyRequest = useRef<AbortController | null>(null);
  const historyReveal = useRef<PendingHistoryReveal | null>(null);
  const cancelHistoryRequest = useCallback(() => {
    historyRequest.current?.abort();
    historyRequest.current = null;
  }, []);
  useEffect(() => cancelHistoryRequest, [call, historyScope, cancelHistoryRequest]);
  const historyPrefix = useMemo(() => {
    if (replyHistory?.scope !== historyScope || replyHistory.call !== call) return [];
    const currentIds = new Set(currentMessages.map((message) => message.messageId));
    return replyHistory.messages.filter(
      (message) => !currentIds.has(message.messageId)
    );
  }, [call, currentMessages, historyScope, replyHistory]);
  const messages = useMemo(
    () =>
      historyPrefix.length ? [...historyPrefix, ...currentMessages] : currentMessages,
    [currentMessages, historyPrefix]
  );
  const historyBoundaryMessageId = historyPrefix.length
    ? currentMessages[0]?.messageId
    : undefined;
  const loadReplyTarget = useCallback(
    async (messageId: string, lifecycle?: ReplyChainReveal) => {
      if (!live || !conversationId) {
        lifecycle?.cancel();
        return;
      }
      historyRequest.current?.abort();
      const controller = new AbortController();
      historyRequest.current = controller;
      let history;
      try {
        history = await call(
          "chat.messageContext",
          { groupId, conversationId, messageId, conversationKind },
          controller.signal
        );
      } catch (error) {
        if (controller.signal.aborted) {
          lifecycle?.cancel();
          return;
        }
        throw error;
      }
      if (controller.signal.aborted) {
        lifecycle?.cancel();
        return;
      }
      if (!history.some((message) => message.messageId === messageId))
        throw new Error("Message unavailable");
      historyReveal.current = { scope: historyScope, messageId, lifecycle };
      setReplyHistory({ call, scope: historyScope, messages: history });
    },
    [call, conversationId, conversationKind, groupId, historyScope, live]
  );
  return {
    cancelHistoryRequest,
    historyBoundaryMessageId,
    historyReveal,
    loadReplyTarget,
    messages,
  };
}
