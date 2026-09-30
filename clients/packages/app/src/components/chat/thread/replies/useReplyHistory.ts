import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CommaApiClient, CommaConversationKind } from "../../../../api";
import {
  normalizeServerMessages,
  type ChatMessage,
} from "../../model/conversationChannel";
import type { ReplyChainReveal } from "./useReplyChainHighlight";

export type PendingHistoryReveal = {
  api: CommaApiClient;
  scope: string;
  messageId: string;
  lifecycle?: ReplyChainReveal | undefined;
};

export function useReplyHistory({
  api,
  conversationId,
  conversationKind,
  currentMessages,
  groupId,
  historyScope,
}: {
  api: CommaApiClient | undefined;
  conversationId: string | undefined;
  conversationKind: CommaConversationKind;
  currentMessages: ChatMessage[];
  groupId: string;
  historyScope: string;
}) {
  const [replyHistory, setReplyHistory] = useState<{
    api: CommaApiClient;
    scope: string;
    messages: ChatMessage[];
  }>();
  const historyRequest = useRef<AbortController | null>(null);
  const historyReveal = useRef<PendingHistoryReveal | null>(null);
  useEffect(() => () => historyRequest.current?.abort(), [api, historyScope]);
  const historyPrefix = useMemo(() => {
    if (replyHistory?.scope !== historyScope || replyHistory.api !== api) return [];
    const currentIds = new Set(currentMessages.map((message) => message.messageId));
    return replyHistory.messages.filter(
      (message) => !currentIds.has(message.messageId)
    );
  }, [api, currentMessages, historyScope, replyHistory]);
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
      if (!api || !conversationId) {
        lifecycle?.cancel();
        return;
      }
      historyRequest.current?.abort();
      const controller = new AbortController();
      historyRequest.current = controller;
      let history;
      try {
        history = await api.getMessageContext(groupId, conversationId, messageId, {
          signal: controller.signal,
        });
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
      const normalized = normalizeServerMessages(history, [], conversationKind);
      if (!normalized.some((message) => message.messageId === messageId))
        throw new Error("Message unavailable");
      historyReveal.current = { api, scope: historyScope, messageId, lifecycle };
      setReplyHistory({ api, scope: historyScope, messages: normalized });
    },
    [api, conversationId, conversationKind, groupId, historyScope]
  );
  return { historyBoundaryMessageId, historyReveal, loadReplyTarget, messages };
}
