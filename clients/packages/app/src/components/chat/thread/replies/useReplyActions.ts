import { useCallback, useLayoutEffect, useMemo, useRef } from "react";
import type { ConversationLayout } from "../layout/conversationLayout";
import type { RevealTurn } from "../navigation/useTurnReveal";
import type { useStickToBottom } from "../scroll/useStickToBottom";
import type { ThreadReplyActions } from "../threadContexts";
import type { useReplyChainHighlight } from "./useReplyChainHighlight";
import type { useReplyHistory } from "./useReplyHistory";

/** What a reply preview can do. Its identity holds while a reply streams. */
export function useReplyActions({
  canonicalLayout,
  conversationId,
  follow: { stopFollowing },
  history: { loadReplyTarget },
  replyChain: { hover, leave, beginReveal },
  live,
  revealTurn,
}: {
  /** The transcript reads the core's live data, so a reply can load the message it quotes. */
  live: boolean;
  canonicalLayout: ConversationLayout;
  conversationId: string | undefined;
  follow: Pick<ReturnType<typeof useStickToBottom>, "stopFollowing">;
  history: Pick<ReturnType<typeof useReplyHistory>, "loadReplyTarget">;
  replyChain: Pick<
    ReturnType<typeof useReplyChainHighlight>,
    "beginReveal" | "hover" | "leave"
  >;
  revealTurn: RevealTurn;
}): ThreadReplyActions {
  // Stays the same object while only the draft changes.
  const turnKeyByMessage = useMemo(
    () =>
      new Map(
        canonicalLayout.turns.flatMap((turn) =>
          turn.entries.flatMap((entry) =>
            entry.message ? [[entry.message.messageId, turn.key] as const] : []
          )
        )
      ),
    [canonicalLayout]
  );
  const revealReplyTarget = useCallback(
    async (messageId: string, sourceId: string) => {
      stopFollowing();
      const lifecycle = beginReveal(sourceId);
      const turn = turnKeyByMessage.get(messageId);
      try {
        if (turn) revealTurn(turn, messageId, { focusMessage: true, lifecycle });
        else await loadReplyTarget(messageId, lifecycle);
      } catch (error) {
        lifecycle.cancel();
        throw error;
      }
    },
    [beginReveal, loadReplyTarget, revealTurn, stopFollowing, turnKeyByMessage]
  );
  // The window hook re-creates revealTurn when a draft starts or ends. Reply
  // previews call the latest one through this ref instead of re-rendering.
  const revealReplyTargetRef = useRef(revealReplyTarget);
  useLayoutEffect(() => {
    revealReplyTargetRef.current = revealReplyTarget;
  }, [revealReplyTarget]);
  const reveal = useCallback(
    (messageId: string, sourceId: string) =>
      revealReplyTargetRef.current(messageId, sourceId),
    []
  );
  const canLoad = live && Boolean(conversationId);
  return useMemo(
    () => ({ canLoad, hover, leave, reveal }),
    [canLoad, hover, leave, reveal]
  );
}
