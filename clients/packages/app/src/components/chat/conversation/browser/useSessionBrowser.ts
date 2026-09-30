import { useEffect, useState } from "react";
import type { CommaApiClient } from "../../../../api";
import type { BrowserBinding } from "../../../../api/browser";

/**
 * The ready browser, if any, that this conversation's participant runs.
 * Rechecked every 10 seconds while the page is visible.
 */
export function useSessionBrowser(
  api: CommaApiClient | undefined,
  workspaceId: string | undefined,
  conversationId: string | undefined,
  participantId: string | undefined
) {
  const scope = JSON.stringify([workspaceId, conversationId, participantId]);
  const [result, setResult] = useState<{ scope: string; browser?: BrowserBinding }>();
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    if (!api || !workspaceId || !conversationId || !participantId) return;
    const abort = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      if (!document.hidden) {
        try {
          const { browsers } = await api.listBrowsers(
            workspaceId,
            { conversationId, participantId },
            AbortSignal.any([abort.signal, AbortSignal.timeout(10_000)])
          );
          if (!abort.signal.aborted) {
            const browser = browsers.find((item) => item.status === "ready");
            setResult({ scope, ...(browser ? { browser } : {}) });
          }
        } catch {
          if (!abort.signal.aborted) setResult({ scope });
        }
      }
      if (!abort.signal.aborted) timer = setTimeout(() => void refresh(), 10_000);
    };
    void refresh();
    return () => {
      abort.abort();
      clearTimeout(timer);
    };
  }, [api, workspaceId, conversationId, participantId, scope, revision]);
  return {
    browser: api && result?.scope === scope ? result.browser : undefined,
    refresh: () => setRevision((value) => value + 1),
  };
}
