// A compute node's install operation and its recovery, as desktop Main asks for them: authorize an install (its
// one-time descriptor), read, retry, enable, disable, revoke, initialize the workload once the node is ready, and the
// recovery reads and transfers. Main keeps the machine's side (the install, its intent file, the Host). Every call but
// `initializeWorkload` names the session lease Main acts for; the core refuses it (`session_changed`) when its own
// session is another, so one account's registration is never touched for another. Only Main's own channel may make
// these calls (`hostOnlyCalls` in core.ts): their answers carry one-time install secrets.
//
// Bounds: one request per call, each given up after 10 s on the Clock; `initializeWorkload` reads once a second, at
// most 31 times over 30 s, then initializes once.
import { CoreError } from "@comma/core-kernel";
import { Duration, Effect } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route, type Method } from "./api.ts";
import {
  computeInstallAuthorizationSchema,
  computeLocalMappingsSchema,
  computeLocalWorkloadTargetSchema,
  computeLocalWorkloadsSchema,
  computeRecoveredBindingSchema,
  computeRecoveryChallengeSchema,
} from "./comma/api-schemas.ts";
import type {
  ComputeNodeAuthorizationValue,
  ComputeNodeOperationValue,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { accountForLease, hostLeaseSchema } from "./host-lease.ts";
import type { SessionLease } from "./host.ts";

export const INITIALIZATION_WAIT_MS = 30_000;
const INITIALIZATION_READ_EVERY_MS = 1_000;
export const COMPUTE_NODE_TIMEOUT_MS = 10_000;

/** The calls only the host's own client (desktop Main) may make: they carry one-time install secrets. */
export const COMPUTE_NODE_HOST_CALLS = [
  "computeNode.authorize",
  "computeNode.retry",
  "computeNode.inspect",
  "computeNode.configure",
  "computeNode.revoke",
  "computeNode.recoveredBinding",
  "computeNode.unexchangedRequest",
  "computeNode.abandon",
  "computeNode.localMappings",
  "computeNode.localWorkloads",
  "computeNode.recoveryCandidates",
  "computeNode.recoverBinding",
] as const;

const operationSchema = z
  .object({
    operation: z
      .object({
        authorization_status: z.enum([
          "requested",
          "exchange_committed",
          "handed_off",
          "action_required",
          "revoked",
        ]),
        status: z.enum([
          "processing",
          "ready",
          "stopped",
          "action_required",
          "removed",
        ]),
        work_activity: z.enum(["idle", "active", "unknown"]).default("unknown"),
        error_code: z.string().min(1).max(128).nullable().optional(),
        shell_phase: z
          .enum([
            "not_initialized",
            "preparing",
            "ready",
            "failed",
            "deleting",
            "deleted",
          ])
          .optional(),
      })
      .passthrough(),
  })
  .strip();

const id = z.string().min(1).max(160);
const operationInput = z.object({
  workspaceId: id,
  operationId: id,
  lease: hostLeaseSchema,
});

const parse = <S extends z.ZodType>(schema: S, raw: unknown): z.output<S> => {
  const out = schema.safeParse(raw);
  if (!out.success)
    throw CoreError.invalid(out.error.issues[0]?.message ?? "invalid params");
  return out.data;
};

type Action = "enable" | "disable" | "revoke" | "initialize-workload";

export class ComputeNodeOperations {
  readonly #ctx: Ctx;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const op = (raw: unknown) => parse(operationInput, raw);
    ctx.kernel.calls({
      "computeNode.initializeWorkload": {
        run: (p) => Effect.suspend(() => this.#initialize(target(p), waitMs(p))),
      },
      "computeNode.authorize": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({ workspaceId: id, requestId: id, lease: hostLeaseSchema }),
              p
            );
            return this.#authorization(
              input.lease,
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/install-operations`,
              [["idempotency-key", input.requestId]]
            );
          }),
      },
      "computeNode.retry": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#authorization(
              input.lease,
              `${operationPath(input)}/retry`
            ).pipe(
              Effect.filterOrFail(
                (answer) => answer.operationId === input.operationId,
                () => identityChanged()
              )
            );
          }),
      },
      "computeNode.inspect": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#operation(this.#accountFor(input.lease), input, "GET");
          }),
      },
      "computeNode.configure": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(operationInput.extend({ enabled: z.boolean() }), p);
            return this.#operation(
              this.#accountFor(input.lease),
              input,
              "POST",
              input.enabled ? "enable" : "disable"
            );
          }),
      },
      "computeNode.revoke": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#operation(
              this.#accountFor(input.lease),
              input,
              "POST",
              "revoke"
            );
          }),
      },
      "computeNode.recoveredBinding": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#json(
              input.lease,
              "GET",
              operationPath(input),
              z.object({ operation: computeRecoveredBindingSchema }).strip()
            ).pipe(Effect.map((answer) => answer.operation));
          }),
      },
      "computeNode.unexchangedRequest": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({ workspaceId: id, requestId: id, lease: hostLeaseSchema }),
              p
            );
            return this.#json(
              input.lease,
              "GET",
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/install-operations/requests/${input.requestId}`,
              z.strictObject({
                operation: z.strictObject({
                  id,
                  registration_id: id,
                  scope_key: z.literal(input.workspaceId),
                  authorization_status: z.enum([
                    "requested",
                    "action_required",
                    "revoked",
                  ]),
                }),
              })
            ).pipe(
              Effect.map(({ operation }) => ({
                operationId: operation.id,
                registrationId: operation.registration_id,
              }))
            );
          }),
      },
      "computeNode.abandon": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#json(
              input.lease,
              "POST",
              `${operationPath(input)}/recovery/abandon`,
              z
                .object({
                  operation: z
                    .object({
                      id: z.string(),
                      authorization_status: z.literal("revoked"),
                    })
                    .passthrough(),
                })
                .strip(),
              { confirmed: true }
            ).pipe(
              Effect.flatMap((answer) =>
                answer.operation.id === input.operationId
                  ? Effect.succeed(null)
                  : Effect.fail(identityChanged())
              )
            );
          }),
      },
      "computeNode.localMappings": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({
                workspaceId: id,
                targets: z.array(computeLocalWorkloadTargetSchema).max(32),
                lease: hostLeaseSchema,
              }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              agentVmmPath(input.workspaceId, "local-mappings"),
              computeLocalMappingsSchema,
              { targets: input.targets }
            ).pipe(Effect.map((answer) => answer.mappings));
          }),
      },
      "computeNode.localWorkloads": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({
                workspaceId: id,
                target: computeLocalWorkloadTargetSchema,
                afterId: z.string().max(200).optional(),
                lease: hostLeaseSchema,
              }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              agentVmmPath(input.workspaceId, "local-workloads"),
              computeLocalWorkloadsSchema,
              { target: input.target, after_id: input.afterId ?? "" }
            );
          }),
      },
      "computeNode.recoveryCandidates": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({
                workspaceId: id,
                registrationIds: z.array(z.string().min(1).max(200)).max(32),
                lease: hostLeaseSchema,
              }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              agentVmmPath(input.workspaceId, "recovery/candidates"),
              z.object({ candidates: z.array(computeRecoveryChallengeSchema).max(32) }),
              { registration_ids: input.registrationIds }
            ).pipe(Effect.map((answer) => answer.candidates));
          }),
      },
      "computeNode.recoverBinding": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              operationInput.extend({ proof: z.unknown(), consume: z.boolean() }),
              p
            );
            const path = `${operationPath(input)}/recovery/${input.consume ? "consume" : "preview"}`;
            const schema = z.object({ operation: computeRecoveredBindingSchema });
            return this.#json(input.lease, "POST", path, schema, {
              proof: input.proof,
            }).pipe(
              Effect.flatMap(({ operation }) =>
                operation.id === input.operationId &&
                operation.scope_key === input.workspaceId
                  ? Effect.succeed(operation)
                  : Effect.fail(
                      new CoreError("bad_response", "Recovery binding changed.")
                    )
              )
            );
          }),
      },
    });
  }

  #accountFor(lease: SessionLease): Effect.Effect<Account, CoreError> {
    return accountForLease(this.#ctx, lease);
  }

  #json<S extends z.ZodType>(
    lease: SessionLease,
    method: Method,
    path: string,
    schema: S,
    body?: unknown,
    headers: [string, string][] = []
  ): Effect.Effect<z.output<S>, CoreError> {
    const ctx = this.#ctx;
    return this.#accountFor(lease).pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          method,
          path,
          schema,
          body,
          COMPUTE_NODE_TIMEOUT_MS,
          headers
        )
      )
    );
  }

  /** An install authorization (a new one, or a retry): its descriptor, sent back to Main as written. */
  #authorization(
    lease: SessionLease,
    path: string,
    headers: [string, string][] = []
  ): Effect.Effect<ComputeNodeAuthorizationValue, CoreError> {
    return this.#json(
      lease,
      "POST",
      path,
      computeInstallAuthorizationSchema,
      {},
      headers
    ).pipe(
      Effect.flatMap((answer) =>
        answer.operation.id === answer.descriptor.operation_id
          ? Effect.succeed({
              descriptor: JSON.stringify(answer.descriptor),
              operationId: answer.operation.id,
              registrationId: answer.operation.registration_id,
            })
          : Effect.fail(identityChanged())
      )
    );
  }

  /** Reads until the node is ready, then initializes its workload once; gives up on action required, removal or the wait. */
  #initialize(
    operation: Target,
    waitMs: number
  ): Effect.Effect<ComputeNodeOperationValue, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const reads = Math.floor(waitMs / INITIALIZATION_READ_EVERY_MS) + 1;
      const account = this.#ctx.session.account();
      for (let read = 1; ; read++) {
        const observed = yield* this.#operation(account, operation, "GET");
        if (observed.status === "ready") {
          return yield* this.#operation(
            account,
            operation,
            "POST",
            "initialize-workload"
          );
        }
        if (
          observed.status === "action_required" ||
          observed.status === "removed" ||
          read >= reads
        ) {
          return yield* Effect.fail(
            new CoreError(
              "initialization_incomplete",
              "Compute node workload initialization could not complete. Check the node connection, then select Continue / Retry."
            )
          );
        }
        yield* Effect.sleep(Duration.millis(INITIALIZATION_READ_EVERY_MS));
      }
    });
  }

  #operation(
    account: Effect.Effect<Account, CoreError>,
    operation: Target,
    method: "GET" | "POST",
    action?: Action
  ): Effect.Effect<ComputeNodeOperationValue, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen(function* () {
      const answer = yield* ctx.api.request(
        yield* account,
        method,
        `${operationPath(operation)}${action ? `/${action}` : ""}`,
        operationSchema,
        method === "POST" ? {} : undefined,
        COMPUTE_NODE_TIMEOUT_MS
      );
      const o = answer.operation;
      return {
        authorizationStatus: o.authorization_status,
        status: o.status,
        workActivity: o.work_activity,
        ...(o.shell_phase ? { shellPhase: o.shell_phase } : {}),
        ...(o.error_code ? { errorCode: o.error_code } : {}),
      };
    });
  }
}

type Target = { workspaceId: string; operationId: string };

const operationPath = (operation: Target) =>
  route`/v1/comma/workspaces/${operation.workspaceId}/compute-nodes/agent-vmm/install-operations/${operation.operationId}`;

const agentVmmPath = (workspaceId: string, rest: string) =>
  `${route`/v1/comma/workspaces/${workspaceId}/compute-nodes/agent-vmm`}/${rest}`;

const identityChanged = () =>
  new CoreError("bad_response", "Compute node authorization identity mismatch.");

const target = (p: unknown): Target => {
  const out = parse(z.object({ workspaceId: id, operationId: id }), p);
  return { workspaceId: out.workspaceId, operationId: out.operationId };
};

const waitMs = (p: unknown): number => {
  const v = (p as { waitMs?: unknown } | null)?.waitMs;
  if (v === undefined) return INITIALIZATION_WAIT_MS;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 120_000)
    throw CoreError.invalid(
      "waitMs must be a whole number of milliseconds up to 120000"
    );
  return v;
};
