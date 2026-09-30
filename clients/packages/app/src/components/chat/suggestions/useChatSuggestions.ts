import { useCallback, useEffect, useRef, useState } from "react";
import type { CommaApiClient, CommaChatSuggestion } from "../../../api";
import type { ConversationViewState } from "../composer/conversationDraft";

const noSuggestions: readonly CommaChatSuggestion[] = [];

export type ChatSuggestionsState = {
  clear: () => void;
  items: readonly CommaChatSuggestion[];
};

/**
 * Generate once per settled canonical reply and locale. Draft edits and snapshot
 * echoes reuse that request. Suggestions remain local to this conversation.
 */
export function useChatSuggestions({
  api,
  conversationId,
  enabled,
  groupId,
  locale,
  state,
}: {
  api: CommaApiClient | undefined;
  conversationId: string | undefined;
  enabled: boolean;
  groupId: string | undefined;
  locale: string;
  state: ConversationViewState;
}): ChatSuggestionsState {
  const [items, setItems] = useState<readonly CommaChatSuggestion[]>(noSuggestions);
  const requestedKeyRef = useRef<string | undefined>(undefined);
  const abortRef = useRef<AbortController | undefined>(undefined);

  // A round in flight, in any of the forms the channel reports it. Suggestions
  // describe a finished turn, so any of these hides the ones on screen and
  // holds the next request.
  const busy =
    state.assistantDraft !== undefined ||
    state.awaitingReply ||
    state.activity !== undefined ||
    state.pending.length > 0 ||
    state.participantStatus?.state === "active";

  const settledMessageId = busy
    ? undefined
    : state.messages.findLast((message) => message.role === "assistant")?.messageId;

  // The suggestions are model-written in the requested language, so a locale carries
  // its own generation: the same turn under a new language is a new request.
  const requestKey = settledMessageId && `${locale}:${settledMessageId}`;

  const clear = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = undefined;
    setItems(noSuggestions);
  }, []);

  // A different conversation is a different transcript: drop the suggestions and
  // the dedupe key so the new conversation's next settle generates its own.
  useEffect(() => {
    requestedKeyRef.current = undefined;
    abortRef.current?.abort();
    abortRef.current = undefined;
    setItems(noSuggestions);
  }, [conversationId]);

  useEffect(() => () => abortRef.current?.abort(), []);

  useEffect(() => {
    if (
      !enabled ||
      !api ||
      typeof api.generateChatSuggestions !== "function" ||
      !groupId ||
      !conversationId
    )
      return;
    if (busy) {
      abortRef.current?.abort();
      abortRef.current = undefined;
      setItems(noSuggestions);
      return;
    }
    if (!requestKey || requestKey === requestedKeyRef.current) return;

    // Superseded requests must not replace or clear the current suggestion.
    abortRef.current?.abort();
    requestedKeyRef.current = requestKey;
    const controller = new AbortController();
    abortRef.current = controller;
    setItems(noSuggestions);

    api
      .generateChatSuggestions(groupId, conversationId, {
        locale,
        signal: controller.signal,
      })
      .then((generated) => {
        if (controller.signal.aborted) return;
        setItems(generated.length > 0 ? generated : noSuggestions);
      })
      .catch(() => {
        // Failed generation leaves the input usable with its default placeholder.
        if (controller.signal.aborted) return;
        setItems(noSuggestions);
      });
  }, [api, busy, conversationId, enabled, groupId, locale, requestKey]);

  return { clear, items: enabled && !busy ? items : noSuggestions };
}
