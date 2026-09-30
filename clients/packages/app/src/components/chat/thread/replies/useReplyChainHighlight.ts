import { useCallback, useEffect, useRef, useState } from "react";

export type ReplyChainReveal = {
  arrived: () => void;
  cancel: () => void;
};

type Highlight = { messageId: string; scope: string; kind: "hover" | "reveal" };
const REPLY_CHAIN_ARRIVAL_HOLD_MS = 200;

export function useReplyChainHighlight(scope: string) {
  const [highlight, setHighlight] = useState<Highlight | null>(null);
  const current = useRef<Highlight | null>(null);
  // At most one arrival timer per transcript. Hover never fetches history.
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const clearTimer = useCallback(() => {
    clearTimeout(timer.current);
    timer.current = undefined;
  }, []);
  const clear = useCallback(() => {
    clearTimer();
    current.current = null;
    setHighlight(null);
  }, [clearTimer]);
  useEffect(() => {
    clear();
    return () => {
      clearTimer();
      current.current = null;
    };
  }, [clear, clearTimer, scope]);

  const hover = useCallback(
    (messageId: string) => {
      // Scrolling can move other previews under a stationary pointer. Keep the
      // clicked chain until arrival; another explicit click can replace it.
      if (current.current?.kind === "reveal") return;
      const next: Highlight = { messageId, scope, kind: "hover" };
      current.current = next;
      setHighlight(next);
    },
    [scope]
  );
  const leave = useCallback(
    (messageId: string) => {
      if (current.current?.kind === "hover" && current.current.messageId === messageId)
        clear();
    },
    [clear]
  );
  const beginReveal = useCallback(
    (messageId: string): ReplyChainReveal => {
      clearTimer();
      const next: Highlight = { messageId, scope, kind: "reveal" };
      current.current = next;
      setHighlight(next);
      const cancel = () => {
        if (current.current === next) clear();
      };
      return {
        arrived: () => {
          if (current.current !== next) return;
          clearTimer();
          timer.current = setTimeout(cancel, REPLY_CHAIN_ARRIVAL_HOLD_MS);
        },
        cancel,
      };
    },
    [clear, clearTimer, scope]
  );

  return {
    messageId: highlight?.scope === scope ? highlight.messageId : undefined,
    hover,
    leave,
    beginReveal,
  };
}
