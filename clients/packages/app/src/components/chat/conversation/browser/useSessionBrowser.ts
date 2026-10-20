import { useCall, useTopic } from "@comma/core-client";
import type { SessionBrowserBinding } from "@comma/core/contract";
import { useEffect, useState } from "react";

/**
 * The ready browser, if any, that this conversation's participant runs, as the
 * core reads it: every 10 seconds while the page is visible. A hidden page lets
 * the core stop; the last answer stays shown until the core reads it again.
 */
export function useSessionBrowser(
  enabled: boolean,
  workspaceId: string | undefined,
  conversationId: string | undefined,
  participantId: string | undefined
) {
  const call = useCall();
  const scope = JSON.stringify([workspaceId, conversationId, participantId]);
  const [hidden, setHidden] = useState(() => document.hidden);
  useEffect(() => {
    const seen = () => setHidden(document.hidden);
    document.addEventListener("visibilitychange", seen);
    return () => document.removeEventListener("visibilitychange", seen);
  }, []);
  const target =
    enabled && workspaceId && conversationId && participantId
      ? {
          workspace: workspaceId,
          conversation: conversationId,
          participant: participantId,
        }
      : null;
  const { value } = useTopic(
    target && !hidden ? { topic: "sessionBrowser", ...target } : null,
    { lingerMs: 0 }
  );
  // The last answer for this conversation and participant.
  const [last, setLast] = useState<{
    scope: string;
    browser: SessionBrowserBinding | null;
  }>();
  if (value && target && (last?.scope !== scope || last.browser !== value.browser))
    setLast({ scope, browser: value.browser });
  return {
    browser: target && last?.scope === scope ? (last.browser ?? undefined) : undefined,
    refresh: () => {
      if (target) void call("sessionBrowser.refresh", target).catch(() => {});
    },
  };
}
