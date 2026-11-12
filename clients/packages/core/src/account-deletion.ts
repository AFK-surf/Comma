// Settings › Account › Delete account: the signed-in person deletes their own account. A code goes to the account's
// email (`accountDeletion.requestCode`), and the deletion is sent with it (`accountDeletion.delete`). The server
// refuses both with `subscription_active` while a subscription still renews; the UI then offers the billing portal.
// Confirming revokes all the account's sessions, this one too: once the server answered, this session ends here as
// one the server refused, so every surface goes to sign-in. The server deletes the account seven days later unless the
// person signs in again before then.
//
// Bounds: each call is one request.
import { lazySchema } from "@comma/chat-contract";
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Ctx } from "./ctx.ts";

const codeSchema = lazySchema(() =>
  z.object({ challenge_id: z.string().min(1).max(256) })
);
const deletedSchema = lazySchema(() => z.object({ deleted: z.literal(true) }));

export function registerAccountDeletion(ctx: Ctx): void {
  ctx.kernel.calls({
    "accountDeletion.requestCode": {
      doing: true,
      run: () =>
        ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "POST",
              "/v1/comma/me/account-deletion/code",
              codeSchema,
              {}
            )
          ),
          Effect.map((answer) => ({ challengeId: answer.challenge_id }))
        ),
    },
    "accountDeletion.delete": {
      doing: true,
      run: (p) => {
        const { challengeId, code } = (p ?? {}) as {
          challengeId?: unknown;
          code?: unknown;
        };
        if (
          typeof challengeId !== "string" ||
          challengeId === "" ||
          challengeId.length > 256
        )
          throw CoreError.invalid("challengeId is required");
        if (typeof code !== "string" || !/^\d{6}$/.test(code))
          throw CoreError.invalid("code must be six digits");
        return ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api
              .request(
                account,
                "POST",
                "/v1/comma/me/account-deletion",
                deletedSchema,
                {
                  challenge_id: challengeId,
                  code,
                }
              )
              .pipe(
                Effect.tap(() =>
                  Effect.sync(() => ctx.session.rejected(account.lease, 401))
                )
              )
          ),
          Effect.as(null)
        );
      },
    },
  });
}
