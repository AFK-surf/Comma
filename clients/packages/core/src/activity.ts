// The person's presence at this computer, told to the server (`/v1/comma/auth/session/activity`): while they use the
// computer and Comma can show them a Router reply in Home, proactive reminders stay in the App instead of also
// reaching Telegram or WeChat. The server counts the owner as present for ten minutes after a report, so a report
// each minute of use keeps them present without a request per input. Only the desktop app has a presence (its host's
// `desktop` ports: Main reads the system's idle time, its windows and the notification settings).
//
// Bounds: per device, one report a minute while signed in, one at a time; none while the computer has had no input
// for five minutes or Home replies cannot be shown. A missed report only lets one reminder also reach the chats.
import type { Scoped } from "@comma/core-kernel";
import { Duration, Effect, Stream } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import type { Ctx } from "./ctx.ts";
import type { DesktopPorts } from "./host.ts";

export const ACTIVITY_REPORT_MS = 60_000;
/** Input in the last five minutes means the person is at the computer. */
export const ACTIVITY_IDLE_LIMIT_SECONDS = 5 * 60;
const ACTIVITY_REPORT_TIMEOUT_MS = 10_000;
const PATH = "/v1/comma/auth/session/activity";

/**
 * Reports the person's presence while an account is signed in, when the host has a desktop: one worker fiber per
 * signed-in account, in a scope that closes when the account does. It reports at once and then each minute
 * (`Stream.tick` on the core's Clock), one report at a time by construction.
 */
export function reportActivity(ctx: Ctx): void {
  const desktop = ctx.host.desktop;
  if (!desktop) return;
  let worker: { key: string; scope: Scoped } | null = null;
  ctx.session.onChange(() => {
    const key = ctx.session.accountKey();
    if (worker?.key === key) return;
    if (worker) ctx.runner.close(worker.scope);
    worker = null;
    if (key === null) return;
    const scope = ctx.runner.child();
    worker = { key, scope };
    ctx.runner.fork(
      ctx.session.account().pipe(
        Effect.flatMap((account) =>
          Stream.tick(Duration.millis(ACTIVITY_REPORT_MS)).pipe(
            Stream.runForEach(() => report(ctx, desktop, account))
          )
        ),
        Effect.ignore
      ),
      scope
    );
  });
}

/** One report, when the person is at the computer and a Home reply would reach them. Never fails. */
function report(
  ctx: Ctx,
  desktop: DesktopPorts,
  account: Account
): Effect.Effect<void> {
  return desktop.presence.pipe(
    Effect.flatMap((presence) =>
      presence.idleSeconds >= ACTIVITY_IDLE_LIMIT_SECONDS || !presence.homeRepliesShown
        ? Effect.void
        : // A 401 tells the session (Api); any other failure waits for the next minute.
          ctx.api.request(
            account,
            "POST",
            PATH,
            z.unknown(),
            undefined,
            ACTIVITY_REPORT_TIMEOUT_MS
          )
    ),
    Effect.ignore
  );
}
