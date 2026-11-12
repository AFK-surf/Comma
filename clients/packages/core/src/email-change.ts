// Settings › Account › Change email: the signed-in person moves their account to another email. The account stays the
// same (its id, Workspaces, Tasks and files); only the email they sign in with changes. A code goes to the account's
// email (`emailChange.requestCode`); with it, a code goes to the new email (`emailChange.requestNewCode`); with that
// one, the email changes (`emailChange.confirm`). The session stays signed in; the core then checks it with the server
// again, so every surface shows the new email.
//
// Bounds: each call is one request; `confirm` adds one session check.
import { lazySchema } from "@comma/chat-contract";
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Ctx } from "./ctx.ts";

const codeSchema = lazySchema(() =>
  z.object({ challenge_id: z.string().min(1).max(256) })
);
const changedSchema = lazySchema(() =>
  z.object({
    user: z.object({ email: z.string().min(1).max(320) }),
  })
);

function challenge(p: unknown): { challengeId: string; code: string } {
  const { challengeId, code } = (p ?? {}) as { challengeId?: unknown; code?: unknown };
  if (typeof challengeId !== "string" || challengeId === "" || challengeId.length > 256)
    throw CoreError.invalid("challengeId is required");
  if (typeof code !== "string" || !/^\d{6}$/.test(code))
    throw CoreError.invalid("code must be six digits");
  return { challengeId, code };
}

export function registerEmailChange(
  ctx: Ctx,
  recheckSession: () => Effect.Effect<unknown>
): void {
  ctx.kernel.calls({
    "emailChange.requestCode": {
      doing: true,
      run: () =>
        ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "POST",
              "/v1/comma/me/email-change/code",
              codeSchema,
              {}
            )
          ),
          Effect.map((answer) => ({ challengeId: answer.challenge_id }))
        ),
    },
    "emailChange.requestNewCode": {
      doing: true,
      run: (p) => {
        const { challengeId, code } = challenge(p);
        const email = (p as { email?: unknown }).email;
        if (typeof email !== "string" || email.trim() === "" || email.length > 320)
          throw CoreError.invalid("email is required");
        return ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "POST",
              "/v1/comma/me/email-change/new-email-code",
              codeSchema,
              { email: email.trim(), challenge_id: challengeId, code }
            )
          ),
          Effect.map((answer) => ({ challengeId: answer.challenge_id }))
        );
      },
    },
    "emailChange.confirm": {
      doing: true,
      run: (p) => {
        const { challengeId, code } = challenge(p);
        return ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "POST",
              "/v1/comma/me/email-change",
              changedSchema,
              {
                challenge_id: challengeId,
                code,
              }
            )
          ),
          Effect.tap(() => Effect.ignore(recheckSession())),
          Effect.map((answer) => ({ email: answer.user.email }))
        );
      },
    },
  });
}
