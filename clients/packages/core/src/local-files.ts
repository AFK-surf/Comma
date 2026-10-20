// A local file's route (`localFiles.register`): Main keeps the file's bytes (its snapshot store, under an opaque
// `lfi1_` ref) and knows which Connector run reads them; the core tells the server the ref is this device's, for that
// run (`/v1/comma/workspaces/{ws}/local-file-refs`). Nothing else goes: no host path, no bytes, no connection
// generation. The server derives the owner from the session and checks the run is the Registry's current one.
//
// The outcome says what Main may do with the bytes: `rejected` when no request could have created the route (Main
// releases the draft), `ambiguous` once a request went out whose answer was lost or unclear (the server may hold the
// route: Main keeps the bytes for its bounded reconciliation). A lost or unclear answer is asked once more with the
// same idempotent request. A picker's or AirDrop's registration names its chat intake: before each request, the intake
// must still be its draft's.
//
// Bounds: two requests per registration at most, each given up after 15 s.
import { CoreError, fromUtf8, utf8, type ClientId } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type { Account } from "./account.ts";
import type { Chat } from "./chat/index.ts";
import type { LocalFileRegistrationFailure } from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const REGISTRATION_TIMEOUT_MS = 15_000;

const registeredSchema = z
  .object({
    local_file_ref: z.string().regex(/^lfi1_[A-Za-z0-9_-]{43}$/),
    state: z.literal("registered"),
  })
  .strict();

const ownerUpgradeSchema = z
  .object({
    action: z.literal("reissue_connector_token"),
    connector_token_endpoint: z.string().min(1),
    error: z.literal("connector_reconfiguration_required"),
    reason: z.literal("connector_owner_missing"),
  })
  .strict();

function unavailable(
  outcome: "ambiguous" | "rejected",
  message = "The selected file could not be registered.",
  remediation?: "reissue_connector_token",
  retryable = outcome === "ambiguous"
): CoreError {
  const detail: LocalFileRegistrationFailure = {
    outcome,
    retryable,
    ...(remediation ? { remediation } : {}),
  };
  return new CoreError("local_file_unavailable", message, undefined, detail);
}

/** An answer that leaves open whether the route was made: asked once more. */
const UNCLEAR = "unclear";
const unclear = () =>
  new CoreError(UNCLEAR, "The registration's answer was lost or unclear.");

const param = (raw: unknown, name: string, pattern: RegExp) => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || !pattern.test(v)) throw unavailable("rejected");
  return v;
};

export class LocalFiles {
  readonly #ctx: Ctx;
  readonly #chat: Chat;

  constructor(ctx: Ctx, chat: Chat) {
    this.#ctx = ctx;
    this.#chat = chat;
    ctx.kernel.calls({
      "localFiles.register": {
        run: (p, call) => {
          const ref = param(p, "localFileRef", /^lfi1_[A-Za-z0-9_-]{43}$/);
          const workspace = param(p, "workspace", /^\S.{0,159}$/s).trim();
          const intakeId = (p as { intakeId?: unknown } | null)?.intakeId;
          if (intakeId !== undefined && typeof intakeId !== "string")
            throw CoreError.invalid("intakeId is a string");
          return this.#register(call.client, {
            workspace,
            ref,
            run: param(p, "connectorRunId", /^\S.{0,159}$/s).trim(),
            device: param(p, "deviceId", /^\S.{0,255}$/s).trim(),
            intakeId,
          });
        },
      },
    });
  }

  #register(
    client: ClientId,
    input: {
      workspace: string;
      ref: string;
      run: string;
      device: string;
      intakeId: string | undefined;
    }
  ): Effect.Effect<null, CoreError> {
    const ctx = this.#ctx;
    const path = route`/v1/comma/workspaces/${input.workspace}/local-file-refs`;
    const body = utf8(
      JSON.stringify({
        connector_run_id: input.run,
        local_file_index_version: 2,
        local_file_ref: input.ref,
        stable_device_id: input.device,
      })
    );
    return ctx.session.account().pipe(
      Effect.mapError(() => unavailable("rejected")),
      Effect.flatMap((account) => {
        const attempt = (first: boolean) =>
          this.#attempt(client, account, path, body, input, first);
        // An unclear answer (none, a server failure, an unexpected body) is asked once more with the same request;
        // after it nothing can rule the route out, so every outcome of the second is ambiguous at worst.
        return attempt(true).pipe(
          Effect.catchIf(
            (e) => e.code === UNCLEAR,
            () => attempt(false)
          ),
          Effect.mapError((e) => (e.code === UNCLEAR ? unavailable("ambiguous") : e))
        );
      })
    );
  }

  /**
   * One request. `first`: none went before it, so a definite refusal is `rejected`; after an unclear one it is
   * `ambiguous`. Fails `UNCLEAR` when its answer leaves open whether the route was made.
   */
  #attempt(
    client: ClientId,
    account: Account,
    path: string,
    body: Uint8Array,
    input: { workspace: string; ref: string; intakeId: string | undefined },
    first: boolean
  ): Effect.Effect<null, CoreError> {
    const outcome = first ? "rejected" : "ambiguous";
    return Effect.suspend(() => {
      // Before the first request a closed intake is a definite rejection (the draft may be released); after an
      // unclear one the bytes are kept, though no request goes again.
      if (
        input.intakeId !== undefined &&
        !this.#chat.intakeCurrent(client, input.intakeId)
      )
        return Effect.fail(unavailable(outcome));
      return this.#ctx.api
        .raw(account, "POST", path, {
          headers: [
            ["accept", "application/json"],
            ["content-type", "application/json"],
          ],
          body,
          timeoutMs: REGISTRATION_TIMEOUT_MS,
        })
        .pipe(
          Effect.matchEffect({
            onSuccess: (response) => {
              let answer: unknown = null;
              try {
                answer = JSON.parse(fromUtf8(response.body));
              } catch {
                answer = null;
              }
              const registered = registeredSchema.safeParse(answer);
              return registered.success && registered.data.local_file_ref === input.ref
                ? Effect.succeed(null)
                : Effect.fail(unclear());
            },
            onFailure: (error) => {
              const status = error.status;
              // No answer, or the server failed: it may have committed it.
              if (status === undefined || status >= 500)
                return Effect.fail(
                  first
                    ? unclear()
                    : unavailable("ambiguous", undefined, undefined, true)
                );
              const upgrade =
                status === 409 ? ownerUpgradeSchema.safeParse(error.detail) : null;
              if (
                upgrade?.success &&
                upgrade.data.connector_token_endpoint ===
                  `${route`/v1/comma/workspaces/${input.workspace}`}/connector-token`
              )
                return Effect.fail(
                  unavailable(
                    outcome,
                    "Reconnect this workspace's Comma Connector with a newly issued token, then select the file again.",
                    "reissue_connector_token",
                    true
                  )
                );
              return Effect.fail(
                unavailable(
                  outcome,
                  undefined,
                  undefined,
                  status === 408 || status === 429
                )
              );
            },
          })
        );
    });
  }
}
