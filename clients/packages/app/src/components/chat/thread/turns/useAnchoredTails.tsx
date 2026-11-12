import { Fragment, useCallback, useMemo, type ReactNode } from "react";
import {
  emptyThreadTurnKey,
  type ConversationTurn,
} from "../layout/conversationLayout";

/** A node that belongs to one published reply instead of to the newest turn. */
export type AnchoredTail = {
  /**
   * The node asks the reader to decide. Its reply's turn then stays mounted
   * wherever it is, so the question cannot wait unseen above the window.
   */
  awaitsDecision?: boolean | undefined;
  /** Identity for React; stable while the node stays with its reply. */
  key: string;
  /** The reply that owns the node; the newest turn when nothing dates it. */
  messageId?: string | undefined;
  node: ReactNode;
};

export function useAnchoredTails(
  anchoredTails: readonly AnchoredTail[] | undefined,
  conversationTurns: ConversationTurn[],
  lastTurnKey: string | undefined
) {
  // A reply that owns an anchored tail can sit above the mount window. The node
  // then shows when the reader reaches that turn, as the reply does; only one
  // that awaits a decision holds the turn mounted (useThreadTurnWindow).
  const anchoredTailsByTurnKey = useMemo(() => {
    const byTurnKey = new Map<string, AnchoredTail[]>();
    if (!anchoredTails || anchoredTails.length === 0) return byTurnKey;
    for (const tail of anchoredTails) {
      const turnKey =
        tail.messageId === undefined
          ? (lastTurnKey ?? emptyThreadTurnKey)
          : (conversationTurns.find((turn) =>
              turn.entries.some((entry) => entry.message?.messageId === tail.messageId)
            )?.key ??
            lastTurnKey ??
            emptyThreadTurnKey);
      const tails = byTurnKey.get(turnKey);
      if (tails) tails.push(tail);
      else byTurnKey.set(turnKey, [tail]);
    }
    return byTurnKey;
  }, [anchoredTails, conversationTurns, lastTurnKey]);
  return useCallback(
    (turnKey: string) => {
      const tails = anchoredTailsByTurnKey.get(turnKey);
      if (!tails) return null;
      return tails.map((tail) => <Fragment key={tail.key}>{tail.node}</Fragment>);
    },
    [anchoredTailsByTurnKey]
  );
}
