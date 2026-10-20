// What desktop Main names when it asks the core to act for an account: the session lease it holds. The core acts only
// when its own session is that one, so a request Main started for one account never runs for another.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import type { Ctx } from "./ctx.ts";
import type { SessionLease } from "./host.ts";

export const hostLeaseSchema = z
  .object({
    audience: z.string().min(1).max(2048),
    authorityInstanceId: z.string().min(1).max(256),
    generation: z.number().int().nonnegative(),
    sessionId: z.string().min(1).max(256),
  })
  .strict();

/** The account open now, when its session is `lease`'s; fails `session_changed` when it is another. */
export function accountForLease(
  ctx: Ctx,
  lease: SessionLease
): Effect.Effect<Account, CoreError> {
  return ctx.session.account().pipe(
    Effect.filterOrFail(
      (account) =>
        account.lease.audience === lease.audience &&
        account.lease.authorityInstanceId === lease.authorityInstanceId &&
        account.lease.generation === lease.generation &&
        account.lease.sessionId === lease.sessionId,
      () => new CoreError("session_changed", "The session changed before the request.")
    )
  );
}
