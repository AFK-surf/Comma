import { sessionProductLease } from "@comma/session-contract";

import type { ElectronMainSessionService } from "./index";

// The server counts the owner as present for ten minutes after a report, so a
// report each minute of use keeps them present without a request per input.
export const ACTIVITY_REPORT_INTERVAL_MS = 60_000;
// Input in the last five minutes means the person is at the computer.
export const ACTIVITY_IDLE_LIMIT_SECONDS = 5 * 60;
const ACTIVITY_REPORT_TIMEOUT_MS = 10_000;

/**
 * Tells the server that the person is at this computer and Comma can show them
 * a Router reply in Home, so proactive reminders stay in the App instead of
 * also reaching Telegram or WeChat. It reports nothing while the computer is
 * idle, Comma cannot show Home replies, or the App is signed out.
 */
export function startActivityReporter({
  canShowHomeReplies,
  fetcher = fetch,
  intervalMs = ACTIVITY_REPORT_INTERVAL_MS,
  session,
  systemIdleSeconds,
}: {
  canShowHomeReplies: () => boolean;
  fetcher?: typeof fetch;
  intervalMs?: number;
  session: ElectronMainSessionService;
  systemIdleSeconds: () => number;
}): { close(): void } {
  let inFlight = false;

  const report = async () => {
    if (inFlight || systemIdleSeconds() >= ACTIVITY_IDLE_LIMIT_SECONDS) return;
    if (!canShowHomeReplies()) return;
    const lease = sessionProductLease(session.state());
    if (!lease) return;
    const credential = session.acquireProductCredential({
      authorityInstanceId: lease.authorityInstanceId,
      expectedAudience: lease.audience,
      expectedSessionId: lease.sessionId,
      generation: lease.generation,
    });
    if (!credential) return;
    inFlight = true;
    try {
      const response = await fetcher(
        new URL("/v1/comma/auth/session/activity", lease.audience),
        {
          headers: {
            accept: "application/json",
            authorization: `Bearer ${credential.token}`,
            "x-comma-session-transport": "bearer",
          },
          method: "POST",
          redirect: "manual",
          signal: AbortSignal.any([
            credential.signal,
            AbortSignal.timeout(ACTIVITY_REPORT_TIMEOUT_MS),
          ]),
        }
      );
      if (response.status === 401) await session.reportUnauthorized(credential);
    } catch {
      // A missed report only lets one reminder also reach the owner's chats.
    } finally {
      inFlight = false;
    }
  };

  const timer = setInterval(() => void report(), intervalMs);
  void report();
  return { close: () => clearInterval(timer) };
}
