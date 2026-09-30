import { useCallback, useEffect, useLayoutEffect, useRef, type RefObject } from "react";
import type { CommaApiClient } from "../../../../api";
import type { ReplyChainReveal } from "../replies/useReplyChainHighlight";
import type { useStickToBottom } from "../scroll/useStickToBottom";
import type { ConversationLayout } from "../layout/conversationLayout";
import type { PendingHistoryReveal } from "../replies/useReplyHistory";
import type { ThreadTurnWindow } from "./useThreadTurnWindow";

type Follow = ReturnType<typeof useStickToBottom>;

export type RevealTurnHandle = {
  current: ((turnKey: string, highlightMessageId?: string) => void) | null;
};

export type RevealTurn = ReturnType<typeof useTurnReveal>;

export function useTurnReveal({
  api,
  canonicalLayout,
  follow: { anchorTurn, revealElement, scrollRootRef, stopFollowing },
  historyReveal,
  historyScope,
  revealTurnHandle,
  turnWindow: { getWindowViewport, hasOlder, revealWindowTurn, windowKeyByMessage },
}: {
  api: CommaApiClient | undefined;
  canonicalLayout: ConversationLayout;
  follow: Pick<
    Follow,
    "anchorTurn" | "revealElement" | "scrollRootRef" | "stopFollowing"
  >;
  historyReveal: RefObject<PendingHistoryReveal | null>;
  historyScope: string;
  revealTurnHandle: RevealTurnHandle | undefined;
  turnWindow: Pick<
    ThreadTurnWindow,
    "getWindowViewport" | "hasOlder" | "revealWindowTurn" | "windowKeyByMessage"
  >;
}) {
  const pendingRevealTurnKeyRef = useRef<string | null>(null);
  const pendingRevealMessageRef = useRef<{
    messageId: string;
    focusMessage: boolean;
    lifecycle?: ReplyChainReveal | undefined;
  } | null>(null);
  const revealMountedMessage = useCallback(
    (messageId: string, allowEarlierContext = true, lifecycle?: ReplyChainReveal) => {
      const message = getWindowViewport()?.querySelector<HTMLElement>(
        `[data-message-id="${CSS.escape(messageId)}"]`
      );
      if (!message) return false;
      const body =
        message.querySelector<HTMLElement>(".comma-chat-assistant-response-body") ??
        message.querySelector<HTMLElement>(".comma-chat-user-bubble") ??
        message;
      return revealElement(
        message,
        body,
        (scrolled) => {
          if (lifecycle) {
            lifecycle.arrived();
            return;
          }
          if (!scrolled) return;
          body.removeAttribute("data-reveal-highlight");
          void body.offsetWidth;
          body.setAttribute("data-reveal-highlight", "true");
        },
        {
          hasEarlierMessages: allowEarlierContext && hasOlder,
          onCancel: lifecycle?.cancel,
        }
      );
    },
    [getWindowViewport, hasOlder, revealElement]
  );
  const revealTurn = useCallback(
    (
      turnKey: string,
      highlightMessageId?: string,
      {
        focusMessage = false,
        lifecycle,
      }: { focusMessage?: boolean; lifecycle?: ReplyChainReveal | undefined } = {}
    ) => {
      if (
        focusMessage &&
        highlightMessageId &&
        revealMountedMessage(highlightMessageId, true, lifecycle)
      ) {
        return;
      }
      stopFollowing();
      pendingRevealTurnKeyRef.current = turnKey;
      pendingRevealMessageRef.current = highlightMessageId
        ? { messageId: highlightMessageId, focusMessage, lifecycle }
        : null;
      const windowKey = highlightMessageId
        ? windowKeyByMessage.get(highlightMessageId)
        : undefined;
      if (!revealWindowTurn(windowKey ?? turnKey)) {
        pendingRevealTurnKeyRef.current = null;
        pendingRevealMessageRef.current = null;
        lifecycle?.cancel();
      }
    },
    [revealMountedMessage, revealWindowTurn, stopFollowing, windowKeyByMessage]
  );
  useEffect(() => {
    if (!revealTurnHandle) return undefined;
    revealTurnHandle.current = revealTurn;
    return () => {
      revealTurnHandle.current = null;
    };
  }, [revealTurn, revealTurnHandle]);
  // Anchor after the render that mounted the requested turn. The window hook
  // keeps the key required for this commit, then hands it to startKey and
  // releases the temporary requirement so future tail slides stay bounded.
  useLayoutEffect(() => {
    const turnKey = pendingRevealTurnKeyRef.current;
    if (turnKey === null) return;
    pendingRevealTurnKeyRef.current = null;
    const pending = pendingRevealMessageRef.current;
    pendingRevealMessageRef.current = null;
    if (pending?.focusMessage) {
      if (!revealMountedMessage(pending.messageId, false, pending.lifecycle))
        pending.lifecycle?.cancel();
      return;
    }
    // The reader left the tail on purpose. Park away from it so a run that is
    // still working announces its next message in the unseen pill instead of
    // pulling them back down to it.
    anchorTurn(turnKey, { follow: false });
    // Highlight the target message after revealing its turn. Reapplying the
    // attribute restarts the highlight when the reader reveals it again.
    if (pending === null) return;
    const announcing = scrollRootRef.current?.querySelector<HTMLElement>(
      `[data-message-id="${CSS.escape(pending.messageId)}"]`
    );
    // Keep any reply preview above the target outside its highlight.
    const revealed =
      announcing?.querySelector<HTMLElement>(".comma-chat-assistant-response-body") ??
      announcing;
    if (!revealed) return;
    revealed.removeAttribute("data-reveal-highlight");
    void revealed.offsetWidth;
    revealed.setAttribute("data-reveal-highlight", "true");
  });
  useLayoutEffect(() => {
    const pending = historyReveal.current;
    if (!pending || pending.scope !== historyScope || pending.api !== api) return;
    historyReveal.current = null;
    const turn = canonicalLayout.turns.find((candidate) =>
      candidate.entries.some((entry) => entry.message?.messageId === pending.messageId)
    );
    if (turn)
      revealTurn(turn.key, pending.messageId, {
        focusMessage: true,
        lifecycle: pending.lifecycle,
      });
    else pending.lifecycle?.cancel();
  }, [api, canonicalLayout, historyReveal, historyScope, revealTurn]);
  return revealTurn;
}
